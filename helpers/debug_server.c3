module debug;

import std::io;
import std::net::tcp;
import std::net;
import std::thread;
import std::core::dstring;
import std::collections::list;
import std::core::mem;

import collision;
import vk;
import image;
import image::png;
import helpers;
import std::encoding::base64;

alias Vec3 @private = float[<3>];


struct DebugCommand {
	DString method;
	DString params_json;
	uint request_id;
}

struct DebugResponse {
	uint request_id;
	DString result_json;
	bool is_error;
}

struct DebugState {
	Mutex mutex;
	List{DebugCommand} pending_commands;
	List{DebugResponse} pending_responses;

	// Control flags
	bool paused;
	bool step_requested;
	int steps_remaining;
	bool screenshot_requested;
	bool screenshot_ready;
	uint screenshot_request_id;

	// Game state pointers (set during init)
	PhysicsWorld* physics_world;
	DeviceContext* vulkan_context;

	bool running;
}

fn void DebugState.init(&self, PhysicsWorld* pw, DeviceContext* ctx)
{
	self.mutex.init()!!;
	self.physics_world = pw;
	self.vulkan_context = ctx;
	self.running = true;
	self.paused = false;
	self.step_requested = false;
	self.steps_remaining = 0;
	self.screenshot_requested = false;
	self.screenshot_ready = false;
}

fn void DebugState.destroy(&self)
{
	self.mutex.destroy()!!;
	self.pending_commands.free();
	self.pending_responses.free();
}

// === TCP Server Thread ===

fn int debug_server_thread(void* arg)
{
	@pool_init(mem, 256 * 1024)
	{
		DebugState* state = (DebugState*)arg;

		TcpServerSocket server;
		// Retry listening in case the port is still in use from a previous run
		for (int attempt = 0; attempt < 10; attempt++)
		{
			if (try s = tcp::listen("127.0.0.1", 9742, 1))
			{
				server = s;
				break;
			}
			else
			{
				if (attempt == 9)
				{
					io::eprintfn("Debug server: failed to bind port 9742, giving up");
					return 0;
				}
				io::eprintfn("Debug server: port 9742 in use, retrying in 1s...");
				thread::sleep_ms(1000)!!;
			}
		}

		io::eprintfn("Debug server listening on :9742");

		while (state.running)
		{
			if (try client = tcp::accept(&server))
			{
				io::eprintfn("Debug server: client connected");
				handle_client(state, &client);
				client.close()!!;
				io::eprintfn("Debug server: client disconnected");
			}
		}

		server.close()!!;
	};
	return 0;
}

fn void handle_client(DebugState* state, TcpSocket* client)
{
	char[8192] buf;
	DString line_buf = dstring::new(mem);
	defer line_buf.free();

	while (state.running)
	{
		usz n = client.read(buf[..]) ?? 0;
		if (n == 0) break;

		line_buf.append_bytes(buf[:n]);

		// Process complete lines
		while (true)
		{
			String view = line_buf.str_view();
			if (try newline_pos = view.index_of_char('\n'))
			{
				String line = view[:newline_pos];
				if (line.len > 0)
				{
					process_tcp_message(state, client, line);
				}

				// Remove processed line from buffer
				String remaining = view[newline_pos + 1..];
				DString new_buf = dstring::new(mem, remaining);
				line_buf.free();
				line_buf = new_buf;
			}
			else
			{
				break;
			}
		}
	}
}

fn void process_tcp_message(DebugState* state, TcpSocket* client, String message)
{
	uint request_id = 0;
	DString method = dstring::new(mem);
	DString params = dstring::new(mem);

	// Extract "id" field
	if (try id_pos = message.index_of(`"id"`))
	{
		if (try colon = message[id_pos..].index_of_char(':'))
		{
			String after = message[id_pos + colon + 1..];
			request_id = parse_json_uint(after);
		}
	}

	// Extract "method" field
	if (try method_pos = message.index_of(`"method"`))
	{
		if (try colon = message[method_pos..].index_of_char(':'))
		{
			String after = message[method_pos + colon + 1..];
			String val = extract_string_value(after);
			method.append_bytes(val);
		}
	}

	// Extract "params" field
	if (try params_pos = message.index_of(`"params"`))
	{
		if (try colon = message[params_pos..].index_of_char(':'))
		{
			String after = message[params_pos + colon + 1..];
			String val = extract_object_value(after);
			params.append_bytes(val);
		}
	}

	// Push command and wait for response
	DebugCommand cmd = {
		.method = method,
		.params_json = params,
		.request_id = request_id,
	};

	state.mutex.lock()!!;
	state.pending_commands.push(cmd);
	state.mutex.unlock()!!;

	// Wait for response (poll)
	while (state.running)
	{
		thread::sleep_ms(1)!!;
		state.mutex.lock()!!;
		bool found_resp = false;
		for (usz i = 0; i < state.pending_responses.len(); i++)
		{
			if (state.pending_responses[i].request_id == request_id)
			{
				DebugResponse resp = state.pending_responses[i];
				state.pending_responses.remove_at(i);
				state.mutex.unlock()!!;

				// Send response
				DString response = dstring::new(mem);
				defer response.free();
				if (resp.is_error)
				{
					response.appendf(`{"id":%d,"error":%s}`, resp.request_id, resp.result_json.str_view());
				}
				else
				{
					response.appendf(`{"id":%d,"result":%s}`, resp.request_id, resp.result_json.str_view());
				}
				response.append_char('\n');
				client.write(response.str_view())!!;
				resp.result_json.free();
				found_resp = true;
				break;
			}
		}
		if (found_resp) break;
		if (!found_resp) state.mutex.unlock()!!;
	}
}

// === Command Processing (called from main thread) ===

fn void process_commands(DebugState* state)
{
	state.mutex.lock()!!;
	List{DebugCommand} cmds;
	for (usz i = 0; i < state.pending_commands.len(); i++)
	{
		cmds.push(state.pending_commands[i]);
	}
	state.pending_commands.clear();
	state.mutex.unlock()!!;

	for (usz i = 0; i < cmds.len(); i++)
	{
		DebugCommand cmd = cmds[i];
		String method_str = cmd.method.str_view();

		DString result = dstring::new(mem);
		bool is_error = false;

		if (method_str == "pause")
		{
			state.paused = true;
			result.appendf(`{"paused":true}`);
		}
		else if (method_str == "resume")
		{
			state.paused = false;
			state.step_requested = false;
			result.appendf(`{"paused":false}`);
		}
		else if (method_str == "step_physics")
		{
			int steps = 1;
			String params_str = cmd.params_json.str_view();
			if (params_str.len > 0)
			{
				if (try pos = params_str.index_of(`"steps"`))
				{
					if (try colon = params_str[pos..].index_of_char(':'))
					{
						String after = params_str[pos + colon + 1..];
						uint val = parse_json_uint(after);
						if (val > 0) steps = (int)val;
					}
				}
			}
			state.step_requested = true;
			state.steps_remaining = steps;
			state.paused = true;
			result.appendf(`{"stepping":true,"steps":%d}`, steps);
		}
		else if (method_str == "get_bodies")
		{
			int filter_id = -1;
			String params_str = cmd.params_json.str_view();
			if (params_str.len > 0)
			{
				if (try pos = params_str.index_of(`"body_id"`))
				{
					if (try colon = params_str[pos..].index_of_char(':'))
					{
						String after = skip_whitespace(params_str[pos + colon + 1..]);
						if (after.len > 0 && after[0] != 'n')
						{
							filter_id = (int)(parse_json_uint(after));
						}
					}
				}
			}
			serialize_bodies(state.physics_world, &result, filter_id);
		}
		else if (method_str == "get_collisions")
		{
			serialize_collisions(state.physics_world, &result);
		}
		else if (method_str == "get_manifolds")
		{
			serialize_manifolds(state.physics_world, &result);
		}
		else if (method_str == "screenshot")
		{
			state.screenshot_requested = true;
			state.screenshot_request_id = cmd.request_id;
			// Response will be pushed by capture_screenshot after render
			cmd.method.free();
			cmd.params_json.free();
			result.free();
			continue;
		}
		else
		{
			is_error = true;
			result.appendf(`{"message":"unknown method"}`, method_str);
		}

		DebugResponse resp = {
			.request_id = cmd.request_id,
			.result_json = result,
			.is_error = is_error,
		};

		state.mutex.lock()!!;
		state.pending_responses.push(resp);
		state.mutex.unlock()!!;

		cmd.method.free();
		cmd.params_json.free();
	}
	cmds.free();
}

// === Screenshot Capture ===

fn void capture_screenshot(DebugState* state, DeviceContext* ctx, uint image_index)
{
	if (!state.screenshot_requested) return;
	state.screenshot_requested = false;

	vk::Device device = ctx.device;
	uint width = ctx.extent.width;
	uint height = ctx.extent.height;
	usz image_size = (usz)width * height * 4;

	// Wait for GPU to finish
	device.waitIdle();

	// Create staging buffer for readback
	Memory stage_buffer = vk::new_buffer(
		allocator: &ctx.allocator,
		usage: vk::BUFFER_USAGE_TRANSFER_DST_BIT,
		properties: vk::MEMORY_PROPERTY_HOST_VISIBLE_BIT
			| vk::MEMORY_PROPERTY_HOST_COHERENT_BIT,
		data: null,
		data_size: image_size
	)!!;
	defer stage_buffer.free();

	vk::Image swapchain_image = ctx.swapchain_images[image_index];

	// Copy swapchain image to staging buffer
	device.@single_time_command(
		queue: ctx.graphics_queue ; CommandBuffer command_buffer
	)
	{
		// Transition from PRESENT_SRC to TRANSFER_SRC
		ImageMemoryBarrier2 to_transfer = {
			.sType = vk::STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER_2,
			.srcStageMask = vk::PIPELINE_STAGE_2_BOTTOM_OF_PIPE_BIT,
			.dstStageMask = vk::PIPELINE_STAGE_2_TRANSFER_BIT_KHR,
			.srcAccessMask = 0,
			.dstAccessMask = vk::ACCESS_2_TRANSFER_READ_BIT,
			.oldLayout = vk::IMAGE_LAYOUT_PRESENT_SRC_KHR,
			.newLayout = vk::IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL,
			.image = swapchain_image,
			.subresourceRange = {
				.aspectMask = vk::IMAGE_ASPECT_COLOR_BIT,
				.baseMipLevel = 0,
				.levelCount = 1,
				.baseArrayLayer = 0,
				.layerCount = 1,
			}
		};
		vk::cmdPipelineBarrier2(
			command_buffer,
			&&vk::dependencyInfo().setImageMemoryBarriers({ to_transfer })
		);

		BufferImageCopy copy_region = {
			.bufferOffset = 0,
			.bufferRowLength = 0,
			.bufferImageHeight = 0,
			.imageSubresource = {
				.aspectMask = vk::IMAGE_ASPECT_COLOR_BIT,
				.mipLevel = 0,
				.baseArrayLayer = 0,
				.layerCount = 1,
			},
			.imageOffset = { 0, 0, 0 },
			.imageExtent = { .width = width, .height = height, .depth = 1 }
		};
		vk::cmdCopyImageToBuffer(
			command_buffer,
			swapchain_image,
			vk::IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL,
			stage_buffer.buffer,
			1,
			&copy_region
		);

		// Transition back to PRESENT_SRC
		ImageMemoryBarrier2 to_present = {
			.sType = vk::STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER_2,
			.srcStageMask = vk::PIPELINE_STAGE_2_TRANSFER_BIT_KHR,
			.dstStageMask = vk::PIPELINE_STAGE_2_BOTTOM_OF_PIPE_BIT,
			.srcAccessMask = vk::ACCESS_2_TRANSFER_READ_BIT,
			.dstAccessMask = 0,
			.oldLayout = vk::IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL,
			.newLayout = vk::IMAGE_LAYOUT_PRESENT_SRC_KHR,
			.image = swapchain_image,
			.subresourceRange = {
				.aspectMask = vk::IMAGE_ASPECT_COLOR_BIT,
				.baseMipLevel = 0,
				.levelCount = 1,
				.baseArrayLayer = 0,
				.layerCount = 1,
			}
		};
		vk::cmdPipelineBarrier2(
			command_buffer,
			&&vk::dependencyInfo().setImageMemoryBarriers({ to_present })
		);
	}!!;

	// Read pixels from mapped staging buffer (HOST_VISIBLE = persistently mapped)
	char* src = stage_buffer.data();
	char[] pixels = mem::new_array(char, image_size);
	defer mem::free(pixels);

	// BGRA -> RGBA swizzle (swapchain is B8G8R8A8_UNORM)
	for (usz i = 0; i < image_size; i += 4)
	{
		pixels[i + 0] = src[i + 2]; // R <- B
		pixels[i + 1] = src[i + 1]; // G
		pixels[i + 2] = src[i + 0]; // B <- R
		pixels[i + 3] = src[i + 3]; // A
	}

	// Encode PNG to bytes and base64
	image::Image img = {
		.width = width,
		.height = height,
		.bit_depth = 8,
		.format = image::PixelFormat.RGBA,
		.pixels = pixels,
	};

	DString result = dstring::new(mem);
	bool is_error = false;

	if (try png_bytes = png::save_bytes(&img))
	{
		String b64 = base64::encode(mem, (String)png_bytes);
		defer mem::free(b64);
		mem::free(png_bytes);
		result.appendf(`{"png_base64":"`);
		result.append_bytes(b64);
		result.appendf(`"}`);
	}
	else
	{
		is_error = true;
		result.appendf(`{"message":"Failed to encode PNG"}`);
	}

	DebugResponse resp = {
		.request_id = state.screenshot_request_id,
		.result_json = result,
		.is_error = is_error,
	};

	state.mutex.lock()!!;
	state.pending_responses.push(resp);
	state.mutex.unlock()!!;

	state.screenshot_ready = true;
}

// === JSON Serialization ===

fn void append_float(DString* out, float v)
{
	if (v != v || v == float.inf || v == -float.inf)
	{
		out.appendf("null");
	}
	else
	{
		out.appendf("%f", v);
	}
}

fn void append_vec3(DString* out, String name, float[<3>] v)
{
	out.appendf(`,"%s":[`, name);
	append_float(out, v[0]);
	out.appendf(",");
	append_float(out, v[1]);
	out.appendf(",");
	append_float(out, v[2]);
	out.appendf("]");
}

fn void serialize_bodies(PhysicsWorld* world, DString* out, int filter_id)
{
	out.appendf("[");
	bool first = true;

	RigidBodyIterator iter = world.bodies.value_iter();
	while (iter.next())
	{
		Rigidbody* body = iter.get()!!;
		if (filter_id >= 0 && (int)body.id != filter_id) continue;

		if (!first) out.appendf(",");
		first = false;

		ShapeType shape_type = body.collider.shape.get_type();
		out.appendf(`{"id":%d`, body.id);
		append_vec3(out, "position", body.collider.translation);
		out.appendf(`,"rotation":[`);
		append_float(out, body.collider.rotation.v.x);
		out.appendf(",");
		append_float(out, body.collider.rotation.v.y);
		out.appendf(",");
		append_float(out, body.collider.rotation.v.z);
		out.appendf(",");
		append_float(out, body.collider.rotation.v.w);
		out.appendf("]");
		append_vec3(out, "linear_velocity", body.linear_velocity);
		append_vec3(out, "angular_velocity", body.angular_velocity);
		out.appendf(`,"mass":`);
		append_float(out, body.mass);
		out.appendf(`,"sleeping":%s,"is_static":%s,"is_kinematic":%s,"shape_type":%d}`,
			body.sleeping ? "true" : "false",
			body.is_static ? "true" : "false",
			body.is_kinematic ? "true" : "false",
			(int)shape_type);
	}

	out.appendf("]");
}

fn void serialize_collisions(PhysicsWorld* world, DString* out)
{
	out.appendf("[");
	for (usz i = 0; i < world.collisions.len(); i++)
	{
		if (i > 0) out.appendf(",");
		Collision c = world.collisions[i];
		out.appendf(`{"a":%d,"b":%d`, c.a, c.b);
		out.appendf(`,"normal":[%f,%f,%f]`, c.normal[0], c.normal[1], c.normal[2]);
		out.appendf(`,"contact_a":[%f,%f,%f]`,
			c.contact[0][0], c.contact[0][1], c.contact[0][2]);
		out.appendf(`,"contact_b":[%f,%f,%f]`,
			c.contact[1][0], c.contact[1][1], c.contact[1][2]);
		out.appendf(`,"depth":%f}`, c.depth);
	}
	out.appendf("]");
}

fn void serialize_manifolds(PhysicsWorld* world, DString* out)
{
	out.appendf("[");
	for (usz i = 0; i < world.manifolds.len(); i++)
	{
		if (i > 0) out.appendf(",");
		ManifoldForce m = world.manifolds[i];
		out.appendf(`{"body_a":%d,"body_b":%d,"num_contacts":%d,"friction":%f,"contacts":[`,
			m.body_a.id, m.body_b.id, m.num_contacts, m.friction);
		for (int j = 0; j < m.num_contacts; j++)
		{
			if (j > 0) out.appendf(",");
			ManifoldContact mc = m.contacts[j];
			out.appendf(`{"penalty":[%f,%f,%f],"lambda":[%f,%f,%f],"stick":%s}`,
				mc.penalty[0], mc.penalty[1], mc.penalty[2],
				mc.lambda[0], mc.lambda[1], mc.lambda[2],
				mc.stick ? "true" : "false");
		}
		out.appendf("]}");
	}
	out.appendf("]");
}

// === Simple JSON Helpers ===

fn String skip_whitespace(String s)
{
	usz i = 0;
	while (i < s.len && (s[i] == ' ' || s[i] == '\t' || s[i] == '\r' || s[i] == '\n')) i++;
	return s[i..];
}

fn uint parse_json_uint(String s)
{
	s = skip_whitespace(s);
	usz end = 0;
	while (end < s.len && s[end] >= '0' && s[end] <= '9') end++;
	if (end == 0) return 0;
	return s[:end].to_uint() ?? 0;
}

fn String extract_string_value(String s)
{
	usz start = 0;
	while (start < s.len && s[start] != '"') start++;
	start++;
	usz end = start;
	while (end < s.len && s[end] != '"') end++;
	if (start >= s.len) return "";
	return s[start..end - 1];
}

fn String extract_object_value(String s)
{
	s = skip_whitespace(s);
	if (s.len == 0 || s[0] != '{') return "{}";

	int depth = 0;
	for (usz i = 0; i < s.len; i++)
	{
		if (s[i] == '{') depth++;
		if (s[i] == '}')
		{
			depth--;
			if (depth == 0) return s[..i];
		}
	}
	return "{}";
}
