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

        subscribe_to_progress()

        Enum.each(services_to_pull, fn svc ->
          image = DrawbridgeCore.Config.Service.resolved_image(svc)
          Mix.shell().info("Pulling #{svc.name} (#{image})...")

          case DrawbridgeCore.SwiftBridge.call_agent({:pull, image}) do
            {:ok, _} ->
              IO.write("\n")
              Mix.shell().info("  #{svc.name}: pulled")

            {:error, reason} ->
              Mix.shell().error("  #{svc.name}: failed - #{inspect(reason)}")
          end
        end)

      {:error, reason} ->
        Mix.raise("Failed to load config: #{inspect(reason)}")
    end
  end

  defp subscribe_to_progress do
    spawn_link(fn ->
      DrawbridgeCore.JsonBridge.subscribe_progress()
      progress_loop()
    end)
  end

  defp progress_loop do
    receive do
      {:pull_progress, data} ->
        percent = data["percent"] || "?"
        downloaded = data["downloaded"] || "?"
        total = data["total"] || "?"
        image = data["image"] || "unknown"

        bar = render_cli_progress_bar(percent)
        IO.write("\r  #{bar} #{percent}% (#{downloaded}/#{total}) #{image}")

        progress_loop()
    after
      60_000 -> :ok
    end
  end

  defp render_cli_progress_bar(percent) when is_binary(percent) do
    case Float.parse(percent) do
      {f, _} -> render_cli_progress_bar(f)
      :error -> render_cli_progress_bar(0)
    end
  end

  defp render_cli_progress_bar(percent) when is_number(percent) do
    width = 20
    filled = round(width * percent / 100)
    empty = width - filled
    String.duplicate("\u2588", filled) <> String.duplicate("\u2591", empty)
  end

  defp render_cli_progress_bar(_), do: String.duplicate("\u2591", 20)

  defp find_config do
    cond do
      File.exists?("drawbridge.yml") -> "drawbridge.yml"
      File.exists?("drawbridge.yaml") -> "drawbridge.yaml"
      true -> Mix.raise("No drawbridge.yml found.")
    end
  end
end
