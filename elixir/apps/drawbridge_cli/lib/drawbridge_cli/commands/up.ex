defmodule Mix.Tasks.Drawbridge.Up do
  @moduledoc "Start the Drawbridge proxy and container orchestrator."

  if Code.ensure_loaded?(Mix.Task) do
    use Mix.Task
  end

  require Logger

  def run(args) do
    {opts, _, _} =
      OptionParser.parse(args,
        switches: [config: :string, no_dns: :boolean, tui: :boolean],
        aliases: [c: :config]
      )

    config_path = opts[:config] || DrawbridgeCli.find_config()

    Logger.info("[Drawbridge] Loading config from #{config_path}")

    case DrawbridgeCore.Config.load(config_path) do
      {:ok, config} ->
        boot(config, opts, config_path)

      {:error, reason} ->
        IO.puts(:stderr, "error: Failed to load config: #{inspect(reason)}")
        System.halt(1)
    end
  end

  defp boot(config, opts, config_path) do
    DrawbridgeCli.ensure_started()

    data_dir = Application.get_env(:drawbridge_core, :data_dir, "~/.drawbridge")

    {:ok, certs} = DrawbridgeCore.CertManager.ensure_certs(config.domain, data_dir)
    Logger.info("[Drawbridge] TLS certs ready at #{certs.cert}")

    unless opts[:no_dns] do
      DrawbridgeCore.DnsManager.setup(config.domain)
    end

    DrawbridgeCore.Orchestrator.start(config, config_path: config_path)

    print_status(config)

    Logger.info("[Drawbridge] Proxy running. Hit Ctrl+C to stop.")

    if opts[:tui] do
      DrawbridgeTui.start(config.domain)
    else
      Process.sleep(:infinity)
    end
  end

  defp print_status(config) do
    IO.puts("")
    IO.puts("  Drawbridge is up")
    IO.puts("  Domain: *.#{config.domain}")
    IO.puts("")

    header =
      String.pad_trailing("Service", 20) <>
        String.pad_trailing("Hostname", 30) <> String.pad_trailing("Ports", 20) <> "State"

    IO.puts("  #{header}")
    IO.puts("  #{String.duplicate("─", 80)}")

    Enum.each(config.services, fn {name, svc} ->
      ports = Enum.map_join(svc.ports, ", ", fn {h, c} -> "#{h}:#{c}" end)

      row =
        String.pad_trailing(to_string(name), 20) <>
          String.pad_trailing(svc.hostname, 30) <>
          String.pad_trailing(ports, 20) <>
          "sleeping"

      IO.puts("  #{row}")
    end)

    IO.puts("")
  end
end
