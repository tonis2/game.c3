module mcp_bridge;

import std::io;
import std::io::file;
import std::net::tcp;
import std::net;
import std::thread;
import std::core::dstring;
import std::encoding::base64;

import mcp;

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
	forward_to_game("screenshot", args);

	String b64 = read_file_base64("/tmp/game_debug.png");
	if (b64.len > 0)
	{
		return mcp::image_result(b64, "image/png");
	}
	return mcp::text_result("Screenshot saved to /tmp/game_debug.png");
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

	// Read response
	char[65536] recv_buf;
	DString recv_line = dstring::new(mem);
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

fn String read_file_base64(String path)
{
	if (try f = file::open(path, "rb"))
	{
		defer f.close()!!;

		DString file_data = dstring::new(mem);
		defer file_data.free();

		char[4096] buf;
		while (true)
		{
			usz n = f.read(buf[..]) ?? 0;
			if (n == 0) break;
			file_data.append_bytes(buf[:n]);
		}

		return base64::encode(mem, file_data.str_view());
	}

	return "";
}
