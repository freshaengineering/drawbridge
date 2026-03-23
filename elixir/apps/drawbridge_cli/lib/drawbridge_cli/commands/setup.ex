defmodule Mix.Tasks.Drawbridge.Setup do
  @moduledoc "One-time system configuration: CA certs, keychain trust, DNS resolver."

  if Code.ensure_loaded?(Mix.Task) do
    use Mix.Task
  end

  require Logger

  def run(args) do
    {opts, _, _} =
      OptionParser.parse(args,
        switches: [domain: :string],
        aliases: [d: :domain]
      )

    DrawbridgeCli.ensure_started()

    domain = opts[:domain] || Application.get_env(:drawbridge_core, :domain, "dev.local")
    data_dir = Application.get_env(:drawbridge_core, :data_dir, "~/.drawbridge") |> Path.expand()

    IO.puts("[setup] Domain: #{domain}")
    IO.puts("[setup] Data dir: #{data_dir}")
    IO.puts("")

    IO.puts("[setup] Checking TLS certificates...")
    {:ok, certs} = DrawbridgeCore.CertManager.ensure_certs(domain, data_dir)
    IO.puts("[setup] TLS certs ready at #{certs.cert}")

    IO.puts("[setup] Checking CA trust...")

    case System.cmd("security", ["verify-cert", "-c", certs.ca_cert], stderr_to_stdout: true) do
      {_, 0} ->
        IO.puts("[setup] CA already trusted in keychain, skipping")

      _ ->
        IO.puts("[setup] Installing CA in macOS keychain (may prompt for sudo)...")
        DrawbridgeCore.CertManager.install_ca_trust(certs.ca_cert)
    end

    IO.puts("[setup] Checking DNS resolver...")

    case DrawbridgeCore.DnsManager.status(domain) do
      {:ok, :configured} ->
        IO.puts("[setup] DNS resolver already configured for *.#{domain}, skipping")

      {:ok, :not_configured} ->
        IO.puts("[setup] Configuring DNS resolver for *.#{domain} (may prompt for sudo)...")
        DrawbridgeCore.DnsManager.setup(domain)
    end

    IO.puts("")
    IO.puts("[setup] Verification:")

    cert_ok = File.exists?(certs.cert) and File.exists?(certs.key)
    ca_ok = File.exists?(certs.ca_cert)
    {:ok, dns_status} = DrawbridgeCore.DnsManager.status(domain)

    IO.puts("  Certs:    #{if cert_ok, do: "ok", else: "MISSING"}")
    IO.puts("  CA:       #{if ca_ok, do: "ok", else: "MISSING"}")
    IO.puts("  DNS:      #{if dns_status == :configured, do: "ok", else: "NOT CONFIGURED"}")
    IO.puts("")

    if cert_ok and ca_ok and dns_status == :configured do
      IO.puts("[setup] System is configured.")
    else
      IO.puts(:stderr, "[setup] Some steps failed. Check output above.")
      System.halt(1)
    end
  end
end
