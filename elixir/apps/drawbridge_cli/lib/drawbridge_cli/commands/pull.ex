defmodule Mix.Tasks.Drawbridge.Pull do
  @moduledoc "Pre-pull container images for configured services."
  @shortdoc "Pull container images"

  use Mix.Task
  require Logger

  @impl Mix.Task
  def run(args) do
    {opts, positional, _} =
      OptionParser.parse(args,
        switches: [config: :string, all: :boolean],
        aliases: [c: :config]
      )

    Mix.Task.run("app.start")

    config_path = opts[:config] || find_config()

    case DrawbridgeCore.Config.load(config_path) do
      {:ok, config} ->
        config = DrawbridgeCore.Lockfile.load_and_overlay(config, config_path)

        services_to_pull =
          if opts[:all] || positional == [] do
            Map.values(config.services)
          else
            positional
            |> Enum.map(fn name ->
              Map.get(config.services, name) ||
                Mix.raise("Unknown service: #{name}")
            end)
          end

        Enum.each(services_to_pull, fn svc ->
          image = DrawbridgeCore.Config.Service.resolved_image(svc)
          Mix.shell().info("Pulling #{image}...")

          case DrawbridgeCore.SwiftBridge.call_agent({:pull, image}) do
            {:ok, _} ->
              Mix.shell().info("  #{svc.name}: pulled")

            {:error, reason} ->
              Mix.shell().error("  #{svc.name}: failed - #{inspect(reason)}")
          end
        end)

      {:error, reason} ->
        Mix.raise("Failed to load config: #{inspect(reason)}")
    end
  end

  defp find_config do
    cond do
      File.exists?("drawbridge.yml") -> "drawbridge.yml"
      File.exists?("drawbridge.yaml") -> "drawbridge.yaml"
      true -> Mix.raise("No drawbridge.yml found.")
    end
  end
end
