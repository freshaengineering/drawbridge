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

  @dns_helper_script """
  #!/usr/bin/env python3
  import socket,struct,sys
  bind_ip=sys.argv[1];port=int(sys.argv[2]);domain=sys.argv[3].lower();answer_ip=sys.argv[4]
  s=socket.socket(socket.AF_INET,socket.SOCK_DGRAM);s.bind((bind_ip,port))
  print("OK",flush=True)
  ip_bytes=bytes(int(x) for x in answer_ip.split("."))
  while True:
      data,addr=s.recvfrom(512)
      if len(data)<12:continue
      tid=data[:2];i=12;labels=[]
      while i<len(data) and data[i]!=0:
          n=data[i];labels.append(data[i+1:i+1+n].decode());i+=1+n
      i+=1;qname=".".join(labels).lower()
      if not(qname==domain or qname.endswith("."+domain)):
          s.sendto(tid+b"\\x84\\x03"+b"\\x00"*8,addr);continue
      qsection=data[12:i+4]
      ans=b"\\xc0\\x0c\\x00\\x01\\x00\\x01\\x00\\x00\\x00\\x3c\\x00\\x04"+ip_bytes
      s.sendto(tid+b"\\x84\\x00\\x00\\x01\\x00\\x01\\x00\\x00\\x00\\x00"+qsection+ans,addr)
  """

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def init(opts) do
    port = Keyword.get(opts, :port, @default_port)
    ip = Keyword.get(opts, :ip, @default_ip)
    domain = Keyword.get(opts, :domain, "dev.local")
    answer_ip = Keyword.get(opts, :answer_ip, @default_ip)

    # Write the helper script to a temp file (escripts can't use priv_dir)
    tmp_script = Path.join(System.tmp_dir!(), "drawbridge_dns_helper.py")
    File.write!(tmp_script, @dns_helper_script)
    File.chmod!(tmp_script, 0o755)

    port_ref =
      Port.open(
        {:spawn_executable, System.find_executable("sudo")},
        [
          :binary,
          :exit_status,
          {:line, 256},
          {:args, ["python3", tmp_script, ip, to_string(port), domain, answer_ip]}
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
