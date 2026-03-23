defmodule Mix.Tasks.Drawbridge.Up do
  @moduledoc "Start the Drawbridge proxy and container orchestrator."
  @shortdoc "Start Drawbridge"

  use Mix.Task
  require Logger

  @impl Mix.Task
  def run(args) do
    {opts, _, _} =
      OptionParser.parse(args,
        switches: [config: :string, no_dns: :boolean],
        aliases: [c: :config]
      )

    config_path = opts[:config] || find_config()

    Logger.info("[Drawbridge] Loading config from #{config_path}")

    case DrawbridgeCore.Config.load(config_path) do
      {:ok, config} ->
        boot(config, opts)

      {:error, reason} ->
        Mix.raise("Failed to load config: #{inspect(reason)}")
    end
  end

  defp boot(config, opts) do
    # Start the applications
    Mix.Task.run("app.start")

    # Ensure TLS certs exist
    data_dir = Application.get_env(:drawbridge_core, :data_dir, "~/.drawbridge")

    {:ok, certs} = DrawbridgeCore.CertManager.ensure_certs(config.domain, data_dir)
    Logger.info("[Drawbridge] TLS certs ready at #{certs.cert}")

    # Configure DNS resolver
    unless opts[:no_dns] do
      DrawbridgeCore.DnsManager.setup(config.domain)
    end

    # Start service orchestrator
    DrawbridgeCore.Orchestrator.start(config)

    # Print status
    print_status(config)

    Logger.info("[Drawbridge] Proxy running. Hit Ctrl+C to stop.")

    # Block until interrupted
    Process.sleep(:infinity)
  end

  defp print_status(config) do
    Mix.shell().info("")
    Mix.shell().info("  Drawbridge is up")
    Mix.shell().info("  Domain: *.#{config.domain}")
    Mix.shell().info("")

    header = String.pad_trailing("Service", 20) <> String.pad_trailing("Hostname", 30) <> String.pad_trailing("Ports", 20) <> "State"
    Mix.shell().info("  #{header}")
    Mix.shell().info("  #{String.duplicate("─", 80)}")

    Enum.each(config.services, fn {name, svc} ->
      ports = Enum.map_join(svc.ports, ", ", fn {h, c} -> "#{h}:#{c}" end)

      row =
        String.pad_trailing(to_string(name), 20) <>
          String.pad_trailing(svc.hostname, 30) <>
          String.pad_trailing(ports, 20) <>
          "sleeping"

      Mix.shell().info("  #{row}")
    end)

    Mix.shell().info("")
  end

  defp find_config do
    cond do
      File.exists?("drawbridge.yml") -> "drawbridge.yml"
      File.exists?("drawbridge.yaml") -> "drawbridge.yaml"
      File.exists?("config/drawbridge.yml") -> "config/drawbridge.yml"
      true -> Mix.raise("No drawbridge.yml found. Run `mix drawbridge.init` to create one.")
    end
  end
end
