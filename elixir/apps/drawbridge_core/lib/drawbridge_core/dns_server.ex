defmodule DrawbridgeCore.DnsServer do
  @moduledoc """
  Tiny authoritative DNS server for *.dev.local inside Apple Container VMs.

  Launches a Python helper with sudo to bind UDP 192.168.64.1:53.
  Responds to A record queries for *.dev.local with the gateway IP.
  Needed because containers resolve gRPC hostnames via DNS, and we need
  them to reach the host where drawbridge proxies the connections.
  """

  use GenServer
  require Logger

  @default_port 53
  @default_ip "192.168.64.1"

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def init(opts) do
    port = Keyword.get(opts, :port, @default_port)
    ip = Keyword.get(opts, :ip, @default_ip)
    domain = Keyword.get(opts, :domain, "dev.local")
    answer_ip = Keyword.get(opts, :answer_ip, @default_ip)

    helper_script = Path.join(:code.priv_dir(:drawbridge_core), "dns_helper.py")

    unless File.exists?(helper_script) do
      Logger.warning("[DnsServer] Helper script not found at #{helper_script}")
      {:ok, %{port_ref: nil}}
    else
      port_ref =
        Port.open(
          {:spawn_executable, System.find_executable("sudo")},
          [
            :binary,
            :exit_status,
            {:line, 256},
            {:args, ["python3", helper_script, ip, to_string(port), domain, answer_ip]}
          ]
        )

      receive do
        {^port_ref, {:data, {:eol, "OK"}}} ->
          Logger.info("[DnsServer] Listening on #{ip}:#{port} for *.#{domain} (sudo helper)")
          {:ok, %{port_ref: port_ref}}

        {^port_ref, {:data, {:eol, line}}} ->
          Logger.warning("[DnsServer] Unexpected output: #{line}")
          {:ok, %{port_ref: port_ref}}

        {^port_ref, {:exit_status, code}} ->
          Logger.warning(
            "[DnsServer] Helper exited with code #{code}. Run drawbridge with sudo or configure DNS manually."
          )

          {:ok, %{port_ref: nil}}
      after
        10_000 ->
          Logger.warning("[DnsServer] Helper timed out starting")
          Port.close(port_ref)
          {:ok, %{port_ref: nil}}
      end
    end
  end

  def handle_info({port_ref, {:data, {:eol, line}}}, %{port_ref: port_ref} = state) do
    Logger.debug("[DnsServer] #{line}")
    {:noreply, state}
  end

  def handle_info({port_ref, {:exit_status, code}}, %{port_ref: port_ref} = state) do
    Logger.warning("[DnsServer] Helper exited with code #{code}")
    {:noreply, %{state | port_ref: nil}}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  def terminate(_reason, %{port_ref: port_ref}) when is_port(port_ref) do
    # Kill the sudo python process
    case Port.info(port_ref, :os_pid) do
      {:os_pid, pid} -> System.cmd("sudo", ["kill", to_string(pid)], stderr_to_stdout: true)
      _ -> :ok
    end

    Port.close(port_ref)
  end

  def terminate(_reason, _state), do: :ok
end
