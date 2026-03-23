defmodule Mix.Tasks.Drawbridge.Lock do
  @moduledoc "Resolve image tags to SHA256 digests and write drawbridge.lock."
  @shortdoc "Lock image digests"

  use Mix.Task
  require Logger

  @impl Mix.Task
  def run(args) do
    {opts, _positional, _} =
      OptionParser.parse(args,
        switches: [config: :string, update: :boolean, partial: :boolean],
        aliases: [c: :config]
      )

    Mix.Task.run("app.start")

    config_path = opts[:config] || find_config()

    case DrawbridgeCore.Config.load(config_path) do
      {:ok, config} ->
        lock_dir = Path.dirname(config_path)
        lock_path = Path.join(lock_dir, "drawbridge.lock")
        now = DateTime.utc_now() |> DateTime.to_iso8601()

        {images, failures} =
          config.services
          |> Enum.reduce({%{}, []}, fn {name, svc}, {acc, fails} ->
            Mix.shell().info("Resolving #{name} (#{svc.image})...")

            result =
              if opts[:update] do
                Mix.shell().info("  Pulling #{svc.image}...")
                DrawbridgeCore.ImageResolver.pull_and_resolve(svc.image)
              else
                DrawbridgeCore.ImageResolver.resolve(svc.image)
              end

            case result do
              {:ok, digest} ->
                Mix.shell().info("  #{digest}")
                {Map.put(acc, name, %{tag: svc.image, digest: digest, locked_at: now}), fails}

              {:error, reason} ->
                Mix.shell().error("  Failed to resolve #{name}: #{reason}")
                {acc, [{name, reason} | fails]}
            end
          end)

        failures = Enum.reverse(failures)

        if failures != [] and not opts[:partial] do
          Enum.each(failures, fn {name, reason} ->
            Mix.shell().error("WARNING: #{name} failed to resolve: #{reason}")
          end)

          Mix.raise(
            "#{length(failures)} image(s) failed to resolve. " <>
              "Lockfile not written. Use --partial to write an incomplete lockfile."
          )
        end

        if failures != [] do
          Enum.each(failures, fn {name, reason} ->
            Mix.shell().error("WARNING: #{name} failed to resolve: #{reason}")
          end)

          Mix.shell().error(
            "WARNING: Writing partial lockfile (#{length(failures)} image(s) unresolved)"
          )
        end

        lock_data = %{locked_at: now, images: images}

        case DrawbridgeCore.Lockfile.write(lock_path, lock_data) do
          :ok ->
            Mix.shell().info("\nWrote #{lock_path} (#{map_size(images)} images locked)")

          {:error, reason} ->
            Mix.raise("Failed to write lockfile: #{inspect(reason)}")
        end

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
