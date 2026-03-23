defmodule DrawbridgeCore.HostNetwork do
  @moduledoc """
  Container-to-host networking helpers.

  Apple Container VMs sit on a NAT network (default 192.168.64.0/24) with the
  host reachable at the gateway IP (typically 192.168.64.1). Services running on
  the host advertise themselves as `*.dev.local`, but containers can't resolve
  those — they need the raw gateway IP instead.
  """

  require Logger

  @default_gateway "192.168.64.1"
  @persistent_term_key :drawbridge_host_gateway_ip

  @doc """
  Discover the host gateway IP that containers use to reach the host.

  Calls `container network inspect default` and parses the `ipv4Gateway` field.
  The result is cached in `:persistent_term`. Falls back to `#{@default_gateway}`
  on any failure.
  """
  def host_gateway_ip do
    case :persistent_term.get(@persistent_term_key, nil) do
      nil -> discover_and_cache_gateway()
      ip -> ip
    end
  end

  @doc """
  Replace `*.domain` hostnames in env values with the host gateway IP.

  Useful for container environments where `*.dev.local` names resolve on the host
  but not inside the container — we swap them for the NAT gateway IP so the
  container can reach host-side services.

  Returns a new env map with substitutions applied.
  """
  def resolve_env_for_container(env, domain \\ "dev.local")
  def resolve_env_for_container(env, _domain) when map_size(env) == 0, do: env

  def resolve_env_for_container(env, domain) do
    gateway = host_gateway_ip()
    escaped = Regex.escape(domain)
    pattern = Regex.compile!("[a-zA-Z0-9._-]+\\.#{escaped}")

    Map.new(env, fn {key, value} ->
      {key, Regex.replace(pattern, value, gateway)}
    end)
  end

  # -- Private --

  defp discover_and_cache_gateway do
    ip =
      case cmd_runner().("container", ["network", "inspect", "default"]) do
        {json, 0} ->
          parse_gateway(json)

        {output, code} ->
          Logger.warning("[HostNetwork] container network inspect exited #{code}: #{output}")
          @default_gateway
      end

    :persistent_term.put(@persistent_term_key, ip)
    ip
  end

  defp parse_gateway(json) do
    case Jason.decode(json) do
      {:ok, %{"ipv4Gateway" => gw}} when is_binary(gw) and gw != "" ->
        gw

      {:ok, _} ->
        Logger.warning("[HostNetwork] No ipv4Gateway in network inspect output")
        @default_gateway

      {:error, _} ->
        Logger.warning("[HostNetwork] Failed to parse network inspect JSON")
        @default_gateway
    end
  end

  defp cmd_runner do
    Application.get_env(:drawbridge_core, :host_network_cmd_runner, &System.cmd/2)
  end
end
