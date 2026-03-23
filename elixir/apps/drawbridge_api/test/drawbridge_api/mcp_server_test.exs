defmodule DrawbridgeApi.McpServerTest do
  use ExUnit.Case, async: true

  alias DrawbridgeApi.McpServer

  describe "MCP protocol handling" do
    test "module exists and can be compiled" do
      assert Code.ensure_loaded?(McpServer)
    end

    test "handle_request returns server info for initialize" do
      response = call_mcp(%{"method" => "initialize", "id" => 1})

      assert response["jsonrpc"] == "2.0"
      assert response["id"] == 1
      assert response["result"]["serverInfo"]["name"] == "drawbridge"
      assert response["result"]["capabilities"]["tools"] == %{}
    end

    test "handle_request returns tools list" do
      response = call_mcp(%{"method" => "tools/list", "id" => 2})

      assert response["id"] == 2
      tools = response["result"]["tools"]
      assert length(tools) == 2

      tool_names = Enum.map(tools, & &1["name"])
      assert "schema_sdl" in tool_names
      assert "graphql" in tool_names
    end

    test "handle_request calls schema_sdl tool" do
      response =
        call_mcp(%{
          "method" => "tools/call",
          "id" => 3,
          "params" => %{"name" => "schema_sdl", "arguments" => %{}}
        })

      assert response["id"] == 3
      [content] = response["result"]["content"]
      assert content["type"] == "text"
      assert content["text"] =~ "Service"
    end

    test "handle_request calls graphql tool" do
      response =
        call_mcp(%{
          "method" => "tools/call",
          "id" => 4,
          "params" => %{
            "name" => "graphql",
            "arguments" => %{"query" => "{ schemaSdl }"}
          }
        })

      assert response["id"] == 4
      [content] = response["result"]["content"]
      assert content["type"] == "text"
      result = Jason.decode!(content["text"])
      assert is_binary(result["data"]["schemaSdl"])
    end

    test "handle_request returns error for unknown method" do
      response = call_mcp(%{"method" => "unknown/method", "id" => 5})

      assert response["id"] == 5
      assert response["error"]["code"] == -32601
    end

    test "handle_request returns error for unknown tool" do
      response =
        call_mcp(%{
          "method" => "tools/call",
          "id" => 6,
          "params" => %{"name" => "nope", "arguments" => %{}}
        })

      assert response["id"] == 6
      assert response["result"]["isError"] == true
    end
  end

  # Send a request to a fresh MCP server and capture the JSON response from stdout.
  # We use capture_io with the :erlang group_leader trick so the GenServer's IO
  # goes through the captured device.
  defp call_mcp(request) do
    line = Jason.encode!(request)

    output =
      ExUnit.CaptureIO.capture_io(fn ->
        # Start the server in this process's group leader context
        name = :"mcp_test_#{System.unique_integer([:positive])}"
        {:ok, pid} = GenServer.start_link(McpServer, [test_mode: true], name: name)

        # Set the server's group leader to this process's (captured) group leader
        Process.group_leader(pid, Process.group_leader())

        send(pid, {:mcp_request, line})
        # Wait for the GenServer to process and write
        Process.sleep(100)

        GenServer.stop(pid)
      end)

    case String.trim(output) do
      "" -> nil
      json -> Jason.decode!(json)
    end
  end
end
