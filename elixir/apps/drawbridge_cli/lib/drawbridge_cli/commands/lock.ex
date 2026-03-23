defmodule Mix.Tasks.Drawbridge.Lock do
  @moduledoc "Resolve image tags to SHA256 digests and write drawbridge.lock."

  if Code.ensure_loaded?(Mix.Task) do
    use Mix.Task
  end

  require Logger

  def run(args) do
    {opts, _positional, _} =
      OptionParser.parse(args,
        switches: [config: :string, update: :boolean, partial: :boolean],
        aliases: [c: :config]
      )

    DrawbridgeCli.ensure_started()

    config_path = opts[:config] || DrawbridgeCli.find_config()

    case DrawbridgeCore.Config.load(config_path) do
      {:ok, config} ->
        lock_dir = Path.dirname(config_path)
        lock_path = Path.join(lock_dir, "drawbridge.lock")
        now = DateTime.utc_now() |> DateTime.to_iso8601()

        {images, failures} =
          config.services
          |> Enum.reduce({%{}, []}, fn {name, svc}, {acc, fails} ->
            IO.puts("Resolving #{name} (#{svc.image})...")

            result =
              if opts[:update] do
                IO.puts("  Pulling #{svc.image}...")
                DrawbridgeCore.ImageResolver.pull_and_resolve(svc.image)
              else
                DrawbridgeCore.ImageResolver.resolve(svc.image)
              end

            case result do
              {:ok, digest} ->
                IO.puts("  #{digest}")
                {Map.put(acc, name, %{tag: svc.image, digest: digest, locked_at: now}), fails}

              {:error, reason} ->
                IO.puts(:stderr, "  Failed to resolve #{name}: #{reason}")
                {acc, [{name, reason} | fails]}
            end
          end)

        failures = Enum.reverse(failures)

        if failures != [] and not opts[:partial] do
          Enum.each(failures, fn {name, reason} ->
            IO.puts(:stderr, "WARNING: #{name} failed to resolve: #{reason}")
          end)

          IO.puts(
            :stderr,
            "error: #{length(failures)} image(s) failed to resolve. " <>
              "Lockfile not written. Use --partial to write an incomplete lockfile."
          )

          System.halt(1)
        end

        if failures != [] do
          Enum.each(failures, fn {name, reason} ->
            IO.puts(:stderr, "WARNING: #{name} failed to resolve: #{reason}")
          end)

          IO.puts(
            :stderr,
            "WARNING: Writing partial lockfile (#{length(failures)} image(s) unresolved)"
          )
        end

        lock_data = %{locked_at: now, images: images}

        case DrawbridgeCore.Lockfile.write(lock_path, lock_data) do
          :ok ->
            IO.puts("\nWrote #{lock_path} (#{map_size(images)} images locked)")

          {:error, reason} ->
            IO.puts(:stderr, "error: Failed to write lockfile: #{inspect(reason)}")
            System.halt(1)
        end

      {:error, reason} ->
        IO.puts(:stderr, "error: Failed to load config: #{inspect(reason)}")
        System.halt(1)
    end
  end
end
