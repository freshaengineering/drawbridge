defmodule Mix.Tasks.Drawbridge.Down do
  @moduledoc "Stop all Drawbridge containers and clean up."

  if Code.ensure_loaded?(Mix.Task) do
    use Mix.Task
  end

  require Logger

  def run(args) do
    {opts, _, _} =
      OptionParser.parse(args,
        switches: [config: :string, keep_dns: :boolean],
        aliases: [c: :config]
      )

    DrawbridgeCli.ensure_started()

    config_path = opts[:config] || DrawbridgeCli.find_config()

    case DrawbridgeCore.Config.load(config_path) do
      {:ok, config} ->
        Logger.info("[Drawbridge] Stopping all containers...")
        DrawbridgeCore.Orchestrator.stop_all()

        unless opts[:keep_dns] do
          DrawbridgeCore.DnsManager.teardown(config.domain)
        end

        Logger.info("[Drawbridge] All containers stopped. Goodbye.")

      {:error, reason} ->
        IO.puts(:stderr, "error: Failed to load config: #{inspect(reason)}")
        System.halt(1)
    end
  end
end
