defmodule Mix.Tasks.Drawbridge.Down do
  @moduledoc "Stop all Drawbridge containers and clean up."
  @shortdoc "Stop Drawbridge"

  use Mix.Task
  require Logger

  @impl Mix.Task
  def run(args) do
    {opts, _, _} =
      OptionParser.parse(args,
        switches: [config: :string, keep_dns: :boolean],
        aliases: [c: :config]
      )

    Mix.Task.run("app.start")

    config_path = opts[:config] || find_config()

    case DrawbridgeCore.Config.load(config_path) do
      {:ok, config} ->
        Logger.info("[Drawbridge] Stopping all containers...")
        DrawbridgeCore.Orchestrator.stop_all()

        unless opts[:keep_dns] do
          DrawbridgeCore.DnsManager.teardown(config.domain)
        end

        Logger.info("[Drawbridge] All containers stopped. Goodbye.")

      {:error, reason} ->
        Mix.raise("Failed to load config: #{inspect(reason)}")
    end
  end

  defp find_config do
    cond do
      File.exists?("drawbridge.yml") -> "drawbridge.yml"
      File.exists?("drawbridge.yaml") -> "drawbridge.yaml"
      File.exists?("config/drawbridge.yml") -> "config/drawbridge.yml"
      true -> Mix.raise("No drawbridge.yml found.")
    end
  end
end
