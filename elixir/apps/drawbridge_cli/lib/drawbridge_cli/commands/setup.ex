defmodule Mix.Tasks.Drawbridge.Setup do
  @moduledoc "One-time system configuration: CA certs, keychain trust, /etc/hosts DNS."

  if Code.ensure_loaded?(Mix.Task) do
    use Mix.Task
  end

  require Logger

  def run(args) do
    {opts, _, _} =
      OptionParser.parse(args,
        switches: [domain: :string, config: :string],
        aliases: [d: :domain, c: :config]
      )

    DrawbridgeCli.ensure_started()

    domain = opts[:domain] || Application.get_env(:drawbridge_core, :domain, "dev.local")
    data_dir = Application.get_env(:drawbridge_core, :data_dir, "~/.drawbridge") |> Path.expand()

    IO.puts("[setup] Domain: #{domain}")
    IO.puts("[setup] Data dir: #{data_dir}")
    IO.puts("")

    # 1. TLS certs
    IO.puts("[setup] Checking TLS certificates...")
    {:ok, certs} = DrawbridgeCore.CertManager.ensure_certs(domain, data_dir)
    IO.puts("[setup] TLS certs ready at #{certs.cert}")

    # 2. CA trust
    IO.puts("[setup] Checking CA trust...")

    case System.cmd("security", ["verify-cert", "-c", certs.ca_cert], stderr_to_stdout: true) do
      {_, 0} ->
        IO.puts("[setup] CA already trusted in keychain, skipping")

      _ ->
        IO.puts("[setup] Installing CA in macOS keychain (may prompt for sudo)...")
        DrawbridgeCore.CertManager.install_ca_trust(certs.ca_cert)
    end

    # 3. Apple Container kernel
    IO.puts("[setup] Checking Apple Container kernel...")
    setup_container_kernel()

    # 4. DNS via /etc/hosts (and clean up stale /etc/resolver/ if present)
    if File.exists?(Path.join("/etc/resolver", domain)) do
      IO.puts("[setup] Removing stale /etc/resolver/#{domain} (causes DNS timeouts)...")
      DrawbridgeCore.DnsManager.teardown(domain)
    end

    config_path = opts[:config] || DrawbridgeCli.find_config()
    IO.puts("[setup] Configuring /etc/hosts from #{config_path} (may prompt for sudo)...")

    case DrawbridgeCore.Config.load(config_path) do
      {:ok, config} ->
        case DrawbridgeCore.DnsManager.setup_hosts(config) do
          :ok -> IO.puts("[setup] /etc/hosts updated")
          {:error, reason} -> IO.puts(:stderr, "[setup] Failed to update /etc/hosts: #{reason}")
        end

      {:error, reason} ->
        IO.puts(:stderr, "[setup] Cannot load config: #{inspect(reason)}")
        IO.puts(:stderr, "[setup] Skipping /etc/hosts — run with --config <path> to specify")
    end

    # 5. Verify
    IO.puts("")
    IO.puts("[setup] Verification:")

    cert_ok = File.exists?(certs.cert) and File.exists?(certs.key)
    ca_ok = File.exists?(certs.ca_cert)
    {:ok, dns_status} = DrawbridgeCore.DnsManager.status(domain)
    kernel_ok = container_kernel_configured?()

    IO.puts("  Certs:    #{if cert_ok, do: "ok", else: "MISSING"}")
    IO.puts("  CA:       #{if ca_ok, do: "ok", else: "MISSING"}")
    IO.puts("  DNS:      #{if dns_status == :configured, do: "ok", else: "NOT CONFIGURED"}")
    IO.puts("  Kernel:   #{if kernel_ok, do: "ok", else: "NOT CONFIGURED"}")
    IO.puts("")

    if cert_ok and ca_ok and dns_status == :configured and kernel_ok do
      IO.puts("[setup] System is configured.")
    else
      IO.puts(:stderr, "[setup] Some steps failed. Check output above.")
      System.halt(1)
    end
  end

  defp setup_container_kernel do
    if container_kernel_configured?() do
      IO.puts("[setup] Container kernel already configured, skipping")
    else
      IO.puts("[setup] Downloading recommended container kernel...")

      case System.cmd("container", ["system", "kernel", "set", "--recommended"],
             stderr_to_stdout: true
           ) do
        {output, 0} ->
          IO.puts("[setup] #{String.trim(output)}")

        {output, code} ->
          IO.puts(:stderr, "[setup] Kernel setup failed (exit #{code}): #{String.trim(output)}")
      end
    end
  end

  defp container_kernel_configured? do
    case System.cmd("container", ["system", "info", "--format", "json"], stderr_to_stdout: true) do
      {json, 0} ->
        case Jason.decode(json) do
          {:ok, %{"defaultKernel" => kernel}} when is_binary(kernel) and kernel != "" -> true
          _ -> false
        end

      _ ->
        false
    end
  end
end
