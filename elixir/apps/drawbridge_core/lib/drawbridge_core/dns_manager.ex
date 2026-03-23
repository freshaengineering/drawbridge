defmodule DrawbridgeCore.DnsManager do
  @moduledoc """
  Manages macOS DNS resolver configuration for the proxy domain.

  Creates/removes /etc/resolver/{domain} to route all *.{domain}
  queries to 127.0.0.1 where the Drawbridge proxy listens.
  """
  require Logger

  @resolver_dir "/etc/resolver"

  @doc "Set up DNS resolver for the given domain."
  def setup(domain) do
    resolver_path = Path.join(@resolver_dir, domain)

    content = """
    # Managed by Drawbridge - do not edit
    nameserver 127.0.0.1
    port 53
    """

    if File.exists?(resolver_path) do
      Logger.debug("[DnsManager] Resolver already exists at #{resolver_path}")
      :ok
    else
      ensure_resolver_dir()

      case write_with_sudo(resolver_path, content) do
        :ok ->
          Logger.info("[DnsManager] DNS resolver configured for *.#{domain}")
          :ok

        {:error, reason} ->
          Logger.error("[DnsManager] Failed to configure DNS: #{reason}")
          {:error, reason}
      end
    end
  end

  @doc "Remove DNS resolver for the given domain."
  def teardown(domain) do
    resolver_path = Path.join(@resolver_dir, domain)

    if File.exists?(resolver_path) do
      case System.cmd("sudo", ["rm", resolver_path], stderr_to_stdout: true) do
        {_, 0} ->
          Logger.info("[DnsManager] DNS resolver removed for *.#{domain}")
          :ok

        {output, _code} ->
          Logger.error("[DnsManager] Failed to remove resolver: #{output}")
          {:error, :removal_failed}
      end
    else
      :ok
    end
  end

  @doc "Check if DNS resolver is configured for the given domain."
  def status(domain) do
    resolver_path = Path.join(@resolver_dir, domain)

    if File.exists?(resolver_path) do
      {:ok, :configured}
    else
      {:ok, :not_configured}
    end
  end

  # -- Private --

  defp ensure_resolver_dir do
    unless File.dir?(@resolver_dir) do
      System.cmd("sudo", ["mkdir", "-p", @resolver_dir], stderr_to_stdout: true)
    end
  end

  defp write_with_sudo(path, content) do
    # Write content to a temp file, then sudo mv it into place
    tmp = Path.join(System.tmp_dir!(), "drawbridge_resolver_#{:rand.uniform(999_999)}")
    File.write!(tmp, content)

    case System.cmd("sudo", ["cp", tmp, path], stderr_to_stdout: true) do
      {_, 0} ->
        File.rm(tmp)
        :ok

      {output, code} ->
        File.rm(tmp)
        Logger.error("[DnsManager] sudo cp failed (exit #{code}): #{output}")
        {:error, :write_failed}
    end
  end
end
