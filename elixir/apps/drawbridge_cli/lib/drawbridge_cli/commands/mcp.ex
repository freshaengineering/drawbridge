defmodule Mix.Tasks.Drawbridge.Mcp do
  @moduledoc "Start the Drawbridge MCP server (stdio JSON-RPC)."

  if Code.ensure_loaded?(Mix.Task) do
    use Mix.Task
  end

  require Logger

  def run(args) do
    {opts, _, _} =
      OptionParser.parse(args,
        switches: [config: :string],
        aliases: [c: :config]
      )

    config_path = opts[:config] || DrawbridgeCli.find_config()

    # Redirect logger to stderr so stdout stays clean for JSON-RPC
    Logger.configure(level: :warning)
    Logger.configure_backend(:console, device: :standard_error)

    DrawbridgeCli.ensure_started()

    case DrawbridgeCore.Config.load(config_path) do
      {:ok, config} ->
        DrawbridgeCore.Orchestrator.start(config)
        {:ok, _} = DrawbridgeApi.McpServer.start_link()
        Process.sleep(:infinity)

      {:error, reason} ->
        IO.puts(:stderr, "error: Failed to load config: #{inspect(reason)}")
        System.halt(1)
    end
  end
end
