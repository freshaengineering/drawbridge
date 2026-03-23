defmodule DrawbridgeApi.McpServer do
  @moduledoc """
  MCP (Model Context Protocol) server over stdio.

  JSON-RPC 2.0 protocol. Exposes two tools: `schema_sdl` and `graphql`.
  Reads newline-delimited JSON from stdin, writes responses to stdout.
  """
  use GenServer

  def start_link(opts \\ []) do
    name = opts[:name] || __MODULE__
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @impl true
  def init(opts) do
    if opts[:test_mode] do
      {:ok, %{reader: nil}}
    else
      {:ok, reader} = Task.start_link(fn -> read_loop() end)
      {:ok, %{reader: reader}}
    end
  end

  @impl true
  def handle_info({:mcp_request, line}, state) do
    case Jason.decode(line) do
      {:ok, request} ->
        response = handle_request(request)

        if response do
          IO.puts(Jason.encode!(response))
        end

      {:error, _} ->
        error_response = %{
          "jsonrpc" => "2.0",
          "id" => nil,
          "error" => %{"code" => -32700, "message" => "Parse error"}
        }

        IO.puts(Jason.encode!(error_response))
    end

    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  defp read_loop do
    case IO.read(:stdio, :line) do
      :eof ->
        :ok

      {:error, _} ->
        :ok

      line ->
        line = String.trim(line)

        if line != "" do
          send(Process.whereis(__MODULE__), {:mcp_request, line})
        end

        read_loop()
    end
  end

  defp handle_request(%{"method" => "initialize", "id" => id}) do
    %{
      "jsonrpc" => "2.0",
      "id" => id,
      "result" => %{
        "protocolVersion" => "2024-11-05",
        "capabilities" => %{
          "tools" => %{}
        },
        "serverInfo" => %{
          "name" => "drawbridge",
          "version" => "0.1.0"
        }
      }
    }
  end

  defp handle_request(%{"method" => "notifications/initialized"}), do: nil

  defp handle_request(%{"method" => "tools/list", "id" => id}) do
    %{
      "jsonrpc" => "2.0",
      "id" => id,
      "result" => %{
        "tools" => [
          %{
            "name" => "schema_sdl",
            "description" =>
              "Returns the Drawbridge GraphQL schema as SDL. Use this to discover available queries and mutations.",
            "inputSchema" => %{
              "type" => "object",
              "properties" => %{}
            }
          },
          %{
            "name" => "graphql",
            "description" =>
              "Execute a GraphQL query or mutation against the Drawbridge API. Returns JSON result.",
            "inputSchema" => %{
              "type" => "object",
              "properties" => %{
                "query" => %{
                  "type" => "string",
                  "description" => "GraphQL query or mutation string"
                },
                "variables" => %{
                  "type" => "object",
                  "description" => "Optional variables for the query"
                }
              },
              "required" => ["query"]
            }
          }
        ]
      }
    }
  end

  defp handle_request(%{"method" => "tools/call", "id" => id, "params" => params}) do
    result = call_tool(params["name"], params["arguments"] || %{})

    %{
      "jsonrpc" => "2.0",
      "id" => id,
      "result" => result
    }
  end

  defp handle_request(%{"method" => _method, "id" => id}) do
    %{
      "jsonrpc" => "2.0",
      "id" => id,
      "error" => %{"code" => -32601, "message" => "Method not found"}
    }
  end

  defp handle_request(%{"method" => _method}), do: nil

  defp call_tool("schema_sdl", _args) do
    sdl = Absinthe.Schema.to_sdl(DrawbridgeApi.Schema)

    %{
      "content" => [%{"type" => "text", "text" => sdl}]
    }
  end

  defp call_tool("graphql", %{"query" => query} = args) do
    variables = args["variables"] || %{}

    case Absinthe.run(query, DrawbridgeApi.Schema, variables: variables) do
      {:ok, result} ->
        %{
          "content" => [%{"type" => "text", "text" => Jason.encode!(result)}]
        }

      {:error, reason} ->
        %{
          "isError" => true,
          "content" => [%{"type" => "text", "text" => "GraphQL error: #{inspect(reason)}"}]
        }
    end
  end

  defp call_tool(name, _args) do
    %{
      "isError" => true,
      "content" => [%{"type" => "text", "text" => "Unknown tool: #{name}"}]
    }
  end
end
