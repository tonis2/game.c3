module mcp_bridge;

import std::io;
import std::net::tcp;
import std::net;
import std::thread;
import std::core::dstring;
import std::encoding::base64;

import mcp;
import image;
import image::png;

const uint PORT = 9742;
const uint MAX_RETRIES = 3;
const uint RETRY_DELAY_MS = 300;

TcpSocket game_socket;
bool connected = false;

fn void main()
{
	Server s = mcp::new_server({ .name = "game-debug", .version = "1.0.0" });

	ToolDef[7] game_tools = {
		{ .name = "pause", .description = "Pause the game loop",
		  .input_schema = `{"type":"object","properties":{}}`,
		  .handler = &handle_game_command },
		{ .name = "resume", .description = "Resume the game loop",
		  .input_schema = `{"type":"object","properties":{}}`,
		  .handler = &handle_game_command },
		{ .name = "step_physics", .description = "Advance N physics frames then re-pause",
		  .input_schema = `{"type":"object","properties":{"steps":{"type":"integer","description":"Number of physics steps (default 1)","default":1}}}`,
		  .handler = &handle_game_command },
		{ .name = "get_bodies", .description = "List all rigid bodies with position, rotation, velocity, mass, sleeping state",
		  .input_schema = `{"type":"object","properties":{"body_id":{"type":"integer","description":"Filter to a single body ID"}}}`,
		  .handler = &handle_game_command },
		{ .name = "get_collisions", .description = "Get active collision pairs with normals, depths, contact points",
		  .input_schema = `{"type":"object","properties":{}}`,
		  .handler = &handle_game_command },
		{ .name = "get_manifolds", .description = "Get manifold data: penalty values, lambda, contact count per pair",
		  .input_schema = `{"type":"object","properties":{}}`,
		  .handler = &handle_game_command },
		{ .name = "screenshot", .description = "Capture current frame and return as PNG image",
		  .input_schema = `{"type":"object","properties":{}}`,
		  .handler = &handle_screenshot },
	};
	foreach (&tool : game_tools)
	{
		s.add_tool(*tool);
	}

	s.serve();

	if (connected) game_socket.close()!!;
}

// === Tool Handlers ===

fn ToolResult handle_game_command(String tool_name, String args, void* user_data)
{
	return forward_to_game(tool_name, args);
}

fn ToolResult handle_screenshot(String tool_name, String args, void* user_data)
{
	ToolResult game_result = forward_to_game("screenshot", args);
	if (game_result.is_error) return game_result;

	// Extract base64 PNG from game response
	String result_text = game_result.content[0].text;
	if (try pos = result_text.index_of(`"png_base64"`))
	{
		if (try colon = result_text[pos..].index_of_char(':'))
		{
			String b64_str = mcp::extract_string_value(result_text[pos + colon + 1..]);
			if (b64_str.len > 0)
			{
				// Decode base64 -> PNG bytes -> Image -> resize -> PNG bytes -> base64
				if (try png_bytes = base64::decode(mem, (char[])b64_str))
				{
					defer mem::free(png_bytes);
					if (try img = png::load_bytes(png_bytes))
					{
						defer img.free();

						Image small = img.resize(img.width / 2, img.height / 2);
						defer small.free();

						if (try small_png = png::save_bytes(&small))
						{
							defer mem::free(small_png);
							String small_b64 = base64::encode(mem, (String)small_png);
							return mcp::image_result(small_b64, "image/png");
						}
					}
				}
			}
		}
	}

	return mcp::error_result("Failed to process screenshot");
}

fn ToolResult forward_to_game(String method, String args)
{
	if (!connected)
	{
		if (!connect_to_game())
		{
			return mcp::error_result("Failed to connect to game on port 9742");
		}
		io::eprintfn("mcp-bridge: connected to game debug server");
	}

	// Send command
	DString tcp_msg = dstring::new(mem);
	defer tcp_msg.free();
	tcp_msg.appendf(`{"id":0,"method":"%s","params":%s}`, method, args);
	tcp_msg.append_char('\n');

	if (catch err = game_socket.write(tcp_msg.str_view()))
	{
		connected = false;
		return mcp::error_result("Failed to communicate with game");
	}

	// Read response (large buffer for screenshot base64 data)
	char[65536] recv_buf;
	DString recv_line = dstring::new_with_capacity(mem, 8 * 1024 * 1024);
	defer recv_line.free();

	while (true)
	{
		usz n = game_socket.read(recv_buf[..]) ?? 0;
		if (n == 0)
		{
			connected = false;
			return mcp::error_result("Game disconnected");
		}

		recv_line.append_bytes(recv_buf[:n]);

		String view = recv_line.str_view();
		if (try newline_pos = view.index_of_char('\n'))
		{
			String response_line = view[:newline_pos];
			return parse_game_response(response_line);
		}
	}
}

fn ToolResult parse_game_response(String response)
{
	bool has_error = response.contains(`"error"`);

	String content = "{}";
	if (has_error)
	{
		if (try pos = response.index_of(`"error"`))
		{
			if (try colon = response[pos..].index_of_char(':'))
			{
				String after = response[pos + colon + 1..];
				content = mcp::extract_object_value(after);
			}
		}
		return mcp::error_result(content);
	}

	if (try pos = response.index_of(`"result"`))
	{
		if (try colon = response[pos..].index_of_char(':'))
		{
			String after = response[pos + colon + 1..];
			after = mcp::skip_whitespace(after);
			if (after.len > 0)
			{
				if (after[0] == '[')
				{
					content = mcp::extract_array_value(after);
				}
				else
				{
					content = mcp::extract_object_value(after);
				}
			}
		}
	}
	return mcp::text_result(content);
}

fn bool connect_to_game()
{
	for (uint i = 0; i < MAX_RETRIES; i++)
	{
		if (try sock = tcp::connect("127.0.0.1", PORT))
		{
			game_socket = sock;
			connected = true;
			return true;
		}
		io::eprintfn("mcp-bridge: connection attempt %d failed, retrying...", i + 1);
		thread::sleep_ms(RETRY_DELAY_MS)!!;
	}
	return false;
}

