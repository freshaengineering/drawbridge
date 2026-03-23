defmodule DrawbridgeProxy.PortHandler do
  @moduledoc """
  Ranch protocol handler for non-TLS port-based routing (Redis, Postgres,
  Kafka, etc.).

  No TLS inspection needed — we know the service purely from which port
  the connection arrived on. The service name is passed via Ranch protocol
  opts when the listener is started.

  State machine:
    connecting  ->  waiting_boot  ->  relaying
               \\->  relaying (immediate, if container already up)
  """

  @behaviour :ranch_protocol
  @behaviour :gen_statem

  require Logger

  @backend_connect_timeout 5_000
  @boot_wait_timeout 30_000
  # Only parse first 4KB of a chunk for protocol detection to avoid
  # excessive allocation from large pipelined requests or payloads.
  @max_detect_bytes 4_096

  # ---- Ranch protocol entry point ----

  @impl :ranch_protocol
  def start_link(ref, transport, opts) do
    {:ok, :proc_lib.spawn_link(__MODULE__, :init, [{ref, transport, opts}])}
  end

  @impl :gen_statem
  def init({ref, transport, opts}) do
    {:ok, socket} = :ranch.handshake(ref)
    :ok = transport.setopts(socket, active: :once)
    # Ranch 2.x transport.messages/0 returns {ok, closed, error, passive}
    {msg_ok, msg_closed, msg_error, _msg_passive} = transport.messages()

    service_name = Keyword.fetch!(opts, :service_name)

    data = %{
      transport: transport,
      socket: socket,
      service_name: service_name,
      backend_socket: nil,
      wait_ref: nil,
      conn_ref: make_ref(),
      protocol_detected: false,
      msg_ok: msg_ok,
      msg_closed: msg_closed,
      msg_error: msg_error
    }

    :gen_statem.enter_loop(__MODULE__, [], :connecting, data)
  end

  @impl :gen_statem
  def callback_mode, do: :state_functions

  # ---- connecting — initial state, runs immediately on enter ----

  def connecting(:enter, _old_state, %{service_name: svc} = data) do
    case DrawbridgeCore.ServiceManager.request_connection(svc) do
      {:ok, {ip, port}} ->
        {:keep_state, data, [{:next_event, :internal, {:connect, ip, port}}]}

      {:wait, ref} ->
        Logger.debug("[PortHandler] waiting for container boot: #{svc}")

        {:next_state, :waiting_boot, %{data | wait_ref: ref},
         [{:state_timeout, @boot_wait_timeout, :boot_timeout}]}

      {:error, reason} ->
        Logger.debug("[PortHandler] unknown service #{svc}: #{inspect(reason)}")
        {:stop, :normal}
    end
  end

  def connecting(:internal, {:connect, ip, port}, data) do
    do_connect_backend(ip, port, data)
  end

  def connecting(:info, {msg_closed, socket}, %{msg_closed: msg_closed, socket: socket}) do
    {:stop, :normal}
  end

  def connecting(:info, {msg_error, socket, reason}, %{msg_error: msg_error, socket: socket}) do
    Logger.debug("[PortHandler] client error in connecting: #{inspect(reason)}")
    {:stop, :normal}
  end

  def connecting(event_type, event, data),
    do: handle_common(event_type, event, :connecting, data)

  # ---- waiting_boot ----

  def waiting_boot(:info, {:container_ready, ref, ip, port}, %{wait_ref: ref} = data) do
    do_connect_backend(ip, port, data)
  end

  def waiting_boot(:state_timeout, :boot_timeout, %{service_name: svc} = data) do
    Logger.warning("[PortHandler] timeout waiting for container #{svc}")
    DrawbridgeCore.ServiceManager.release_connection(svc)
    close_sockets(data)
    {:stop, :normal}
  end

  def waiting_boot(:info, {msg_closed, socket}, %{msg_closed: msg_closed, socket: socket} = data) do
    DrawbridgeCore.ServiceManager.release_connection(data.service_name)
    {:stop, :normal}
  end

  def waiting_boot(event_type, event, data),
    do: handle_common(event_type, event, :waiting_boot, data)

  # ---- relaying ----

  # Client -> backend
  def relaying(
        :info,
        {msg_ok, socket, chunk},
        %{msg_ok: msg_ok, socket: socket, backend_socket: backend, transport: transport} = data
      ) do
    data = maybe_detect_protocol(chunk, data)

    case :gen_tcp.send(backend, chunk) do
      :ok ->
        transport.setopts(socket, active: :once)
        {:keep_state, data}

      {:error, _} ->
        close_and_stop(data)
    end
  end

  # Backend -> client
  def relaying(
        :info,
        {:tcp, socket, chunk},
        %{backend_socket: socket, socket: client, transport: transport} = data
      ) do
    case transport.send(client, chunk) do
      :ok ->
        :inet.setopts(socket, active: :once)
        {:keep_state, data}

      {:error, _} ->
        close_and_stop(data)
    end
  end

  def relaying(:info, {msg_closed, socket}, %{msg_closed: msg_closed, socket: socket} = data) do
    close_and_stop(data)
  end

  def relaying(:info, {:tcp_closed, socket}, %{backend_socket: socket} = data) do
    close_and_stop(data)
  end

  def relaying(:info, {msg_error, socket, reason}, %{msg_error: msg_error, socket: socket} = data) do
    Logger.debug("[PortHandler] client error in relay: #{inspect(reason)}")
    close_and_stop(data)
  end

  def relaying(:info, {:tcp_error, socket, reason}, %{backend_socket: socket} = data) do
    Logger.debug("[PortHandler] backend error in relay: #{inspect(reason)}")
    close_and_stop(data)
  end

  def relaying(event_type, event, data),
    do: handle_common(event_type, event, :relaying, data)

  # ---- gen_statem callbacks ----

  @impl :gen_statem
  def terminate(_reason, _state, data) do
    if data[:service_name] && data[:conn_ref] do
      DrawbridgeProxy.ProtocolRegistry.delete(data.service_name, data.conn_ref)
    end

    close_sockets(data)
    :ok
  end

  # ---- private ----

  defp maybe_detect_protocol(_chunk, %{protocol_detected: true} = data), do: data
  defp maybe_detect_protocol(_chunk, %{service_name: nil} = data), do: data

  defp maybe_detect_protocol(chunk, %{service_name: svc, conn_ref: ref} = data) do
    detect_chunk =
      if byte_size(chunk) > @max_detect_bytes,
        do: binary_part(chunk, 0, @max_detect_bytes),
        else: chunk

    case DrawbridgeProxy.Protocol.detect_all(detect_chunk) do
      {:ok, meta} ->
        DrawbridgeProxy.ProtocolRegistry.store(svc, ref, meta)

      :unknown ->
        :ok
    end

    %{data | protocol_detected: true}
  end

  defp do_connect_backend(ip, port, data) do
    ip_addr = parse_ip(ip)

    case :gen_tcp.connect(
           ip_addr,
           port,
           [:binary, active: :once, nodelay: true],
           @backend_connect_timeout
         ) do
      {:ok, backend_socket} ->
        :ok = data.transport.setopts(data.socket, active: :once)
        Logger.debug("[PortHandler] relaying #{data.service_name} -> #{ip}:#{port}")
        {:next_state, :relaying, %{data | backend_socket: backend_socket}}

      {:error, reason} ->
        Logger.warning("[PortHandler] backend connect #{ip}:#{port} failed: #{inspect(reason)}")
        DrawbridgeCore.ServiceManager.release_connection(data.service_name)
        {:stop, :normal}
    end
  end

  defp close_and_stop(data) do
    close_sockets(data)
    {:stop, :normal}
  end

  defp close_sockets(%{transport: t, socket: s, backend_socket: b, service_name: svc}) do
    t.close(s)
    if b, do: :gen_tcp.close(b)
    if svc, do: DrawbridgeCore.ServiceManager.release_connection(svc)
  end

  defp close_sockets(_), do: :ok

  defp handle_common(_type, _event, state, _data) do
    Logger.debug("[PortHandler] unexpected event in #{state}")
    :keep_state_and_data
  end

  defp parse_ip(ip) when is_binary(ip) do
    {:ok, addr} = ip |> String.to_charlist() |> :inet.parse_address()
    addr
  end

  defp parse_ip(ip) when is_tuple(ip), do: ip
end
