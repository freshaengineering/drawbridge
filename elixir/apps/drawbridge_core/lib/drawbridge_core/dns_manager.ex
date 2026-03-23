defmodule DrawbridgeCore.DnsManager do
  @moduledoc """
  Manages DNS for Drawbridge service hostnames.

  Two strategies:
  - `/etc/hosts` — upserts a managed block with explicit hostname entries (works everywhere)
  - `/etc/resolver/` — creates a resolver file (requires a local DNS server on port 53)

  Defaults to `/etc/hosts` as it's the most reliable across VPN/corporate DNS setups.
  """
  require Logger

  @hosts_path "/etc/hosts"
  @begin_marker "# BEGIN drawbridge"
  @end_marker "# END drawbridge"

  # -- Public API --

  @doc "Set up DNS for all hostnames in the given config. Uses /etc/hosts."
  def setup_hosts(%DrawbridgeCore.Config{} = config) do
    hostnames =
      config.services
      |> Enum.map(fn {_, svc} -> svc.hostname end)
      |> Enum.reject(&is_nil/1)
      |> Enum.sort()

    if hostnames == [] do
      Logger.info("[DnsManager] No hostnames to configure")
      :ok
    else
      upsert_hosts(hostnames)
    end
  end

  @doc "Set up DNS for a raw domain (legacy — creates /etc/resolver/ file)."
  def setup(domain) do
    resolver_dir = "/etc/resolver"
    resolver_path = Path.join(resolver_dir, domain)

    content = """
    # Managed by Drawbridge - do not edit
    nameserver 127.0.0.1
    port 53
    """

    if File.exists?(resolver_path) do
      Logger.debug("[DnsManager] Resolver already exists at #{resolver_path}")
      :ok
    else
      unless File.dir?(resolver_dir) do
        System.cmd("sudo", ["mkdir", "-p", resolver_dir], stderr_to_stdout: true)
      end

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

  @doc "Remove the drawbridge block from /etc/hosts."
  def cleanup_hosts do
    case File.read(@hosts_path) do
      {:ok, content} ->
        cleaned = remove_managed_block(content)

        if cleaned == content do
          Logger.info("[DnsManager] No drawbridge entries in /etc/hosts")
          :ok
        else
          case write_with_sudo(@hosts_path, cleaned) do
            :ok ->
              flush_dns_cache()
              Logger.info("[DnsManager] Removed drawbridge entries from /etc/hosts")
              :ok

            error ->
              error
          end
        end

      {:error, reason} ->
        Logger.error("[DnsManager] Cannot read #{@hosts_path}: #{reason}")
        {:error, reason}
    end
  end

  @doc "Remove DNS resolver for the given domain."
  def teardown(domain) do
    resolver_path = Path.join("/etc/resolver", domain)

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

  @doc "Check if DNS is configured (checks /etc/hosts for drawbridge block)."
  def status(domain) do
    hosts_ok =
      case File.read(@hosts_path) do
        {:ok, content} -> String.contains?(content, @begin_marker)
        _ -> false
      end

    resolver_ok = File.exists?(Path.join("/etc/resolver", domain))

    cond do
      hosts_ok -> {:ok, :configured}
      resolver_ok -> {:ok, :configured}
      true -> {:ok, :not_configured}
    end
  end

  # -- Private --

  defp upsert_hosts(hostnames) do
    block = build_hosts_block(hostnames)

    case File.read(@hosts_path) do
      {:ok, content} ->
        new_content =
          if String.contains?(content, @begin_marker) do
            replace_managed_block(content, block)
          else
            String.trim_trailing(content) <> "\n\n" <> block <> "\n"
          end

        case write_with_sudo(@hosts_path, new_content) do
          :ok ->
            flush_dns_cache()
            Logger.info("[DnsManager] Updated /etc/hosts with #{length(hostnames)} hostnames")
            :ok

          error ->
            error
        end

      {:error, reason} ->
        Logger.error("[DnsManager] Cannot read #{@hosts_path}: #{reason}")
        {:error, reason}
    end
  end

  defp build_hosts_block(hostnames) do
    entries = Enum.map_join(hostnames, "\n", &"127.0.0.1 #{&1}")
    "#{@begin_marker}\n#{entries}\n#{@end_marker}"
  end

  defp replace_managed_block(content, new_block) do
    # Replace everything between BEGIN and END markers (inclusive)
    Regex.replace(
      ~r/#{Regex.escape(@begin_marker)}.*?#{Regex.escape(@end_marker)}/s,
      content,
      new_block
    )
  end

  defp remove_managed_block(content) do
    # Remove the block and any trailing blank line
    Regex.replace(
      ~r/\n?#{Regex.escape(@begin_marker)}.*?#{Regex.escape(@end_marker)}\n?/s,
      content,
      "\n"
    )
  end

  defp flush_dns_cache do
    System.cmd("dscacheutil", ["-flushcache"], stderr_to_stdout: true)
    System.cmd("sudo", ["killall", "-HUP", "mDNSResponder"], stderr_to_stdout: true)
    Logger.debug("[DnsManager] DNS cache flushed")
  end

  defp write_with_sudo(path, content) do
    tmp = Path.join(System.tmp_dir!(), "drawbridge_dns_#{:rand.uniform(999_999)}")
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
