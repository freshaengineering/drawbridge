defmodule Mix.Tasks.Drawbridge.Api do
  @moduledoc "Start the Drawbridge GraphQL HTTP server."
  @shortdoc "Start GraphQL API server"

  use Mix.Task
  require Logger

  @impl Mix.Task
  def run(args) do
    {opts, _, _} =
      OptionParser.parse(args,
        switches: [port: :integer, config: :string],
        aliases: [p: :port, c: :config]
      )

    port = opts[:port] || 4001
    config_path = opts[:config] || DrawbridgeCli.find_config()

    Mix.Task.run("app.start")

    case DrawbridgeCore.Config.load(config_path) do
      {:ok, config} ->
        DrawbridgeCore.Orchestrator.start(config)
        start_http(port)

      {:error, reason} ->
        Mix.raise("Failed to load config: #{inspect(reason)}")
    end
  end

  defp start_http(port) do
    Logger.info("[DrawbridgeApi] GraphQL server starting on http://localhost:#{port}")
    Logger.info("[DrawbridgeApi] GraphiQL at http://localhost:#{port}/")
    Logger.info("[DrawbridgeApi] GraphQL endpoint at http://localhost:#{port}/graphql")

    {:ok, _} =
      Plug.Cowboy.http(DrawbridgeApi.Router, [], port: port)

    Process.sleep(:infinity)
  end
end
