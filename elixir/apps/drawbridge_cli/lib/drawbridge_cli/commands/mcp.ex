defmodule Mix.Tasks.Drawbridge.Mcp do
  @moduledoc "Start the Drawbridge MCP server (stdio JSON-RPC)."
  @shortdoc "Start MCP server"

  use Mix.Task
  require Logger

  @impl Mix.Task
  def run(args) do
    {opts, _, _} =
      OptionParser.parse(args,
        switches: [config: :string],
        aliases: [c: :config]
      )

    config_path = opts[:config] || find_config()

    # Redirect logger to stderr so stdout stays clean for JSON-RPC
    Logger.configure(level: :warning)

    Mix.Task.run("app.start")

    case DrawbridgeCore.Config.load(config_path) do
      {:ok, config} ->
        DrawbridgeCore.Orchestrator.start(config)
        {:ok, _} = DrawbridgeApi.McpServer.start_link()
        Process.sleep(:infinity)

      {:error, reason} ->
        Mix.raise("Failed to load config: #{inspect(reason)}")
    end
  end

  defp find_config do
    cond do
      File.exists?("drawbridge.yml") -> "drawbridge.yml"
      File.exists?("drawbridge.yaml") -> "drawbridge.yaml"
      File.exists?("config/drawbridge.yml") -> "config/drawbridge.yml"
      true -> Mix.raise("No drawbridge.yml found. Run `drawbridge init` to create one.")
    end
  end
end
