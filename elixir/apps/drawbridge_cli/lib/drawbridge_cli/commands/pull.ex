defmodule Mix.Tasks.Drawbridge.Pull do
  @moduledoc "Pre-pull container images for configured services."

  if Code.ensure_loaded?(Mix.Task) do
    use Mix.Task
  end

  require Logger

  def run(args) do
    {opts, positional, _} =
      OptionParser.parse(args,
        switches: [config: :string, all: :boolean],
        aliases: [c: :config]
      )

    DrawbridgeCli.ensure_started()

    config_path = opts[:config] || DrawbridgeCli.find_config()

    case DrawbridgeCore.Config.load(config_path) do
      {:ok, config} ->
        config = DrawbridgeCore.Lockfile.load_and_overlay(config, config_path)

        services_to_pull =
          if opts[:all] || positional == [] do
            Map.values(config.services)
          else
            positional
            |> Enum.map(fn name ->
              case Map.get(config.services, name) do
                nil ->
                  IO.puts(:stderr, "error: Unknown service: #{name}")
                  System.halt(1)

                svc ->
                  svc
              end
            end)
          end

        Enum.each(services_to_pull, fn svc ->
          image = DrawbridgeCore.Config.Service.resolved_image(svc)
          IO.puts("Pulling #{image}...")

          case DrawbridgeCore.SwiftBridge.call_agent({:pull, image}) do
            {:ok, _} ->
              IO.puts("  #{svc.name}: pulled")

            {:error, reason} ->
              IO.puts(:stderr, "  #{svc.name}: failed - #{inspect(reason)}")
          end
        end)

      {:error, reason} ->
        IO.puts(:stderr, "error: Failed to load config: #{inspect(reason)}")
        System.halt(1)
    end
  end
end
