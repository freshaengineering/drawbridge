defmodule DrawbridgeProxy.PortHandler do
  @moduledoc """
  Ranch protocol handler for non-TLS port-based routing (Redis, Postgres,
  Kafka, etc.).

  No TLS inspection needed — we know the service purely from which port
  the connection arrived on. The service name is passed via Ranch protocol
  opts when the listener is started.

  For Postgres-aware ports (`pg_aware: true`), the handler buffers the
  initial bytes to extract the database name from the StartupMessage and
  routes to the correct service by database. Falls back to port-based
  routing when no database match is found.

  State machine:
    connecting        ->  waiting_boot  ->  relaying
                     \\->  relaying (immediate, if container already up)
    waiting_pg_startup -> connecting (after database extraction)
  """

  @behaviour :ranch_protocol
  @behaviour :gen_statem

  require Logger

  @backend_connect_timeout 5_000
  @boot_wait_timeout 30_000
  @pg_startup_timeout 5_000
  @max_pg_buffer 4_096
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

    service_name = Keyword.get(opts, :service_name)
    pg_aware = Keyword.get(opts, :pg_aware, false)
    grpc_aware = Keyword.get(opts, :grpc_aware, false)

    data = %{
      transport: transport,
      socket: socket,
      service_name: service_name,
      backend_socket: nil,
      wait_ref: nil,
      conn_ref: make_ref(),
      protocol_detected: false,
      pg_aware: pg_aware,
      grpc_aware: grpc_aware,
      buffer: <<>>,
      msg_ok: msg_ok,
      msg_closed: msg_closed,
      msg_error: msg_error,
      started_at: System.monotonic_time(:millisecond)
    }

    cond do
      pg_aware ->
        actions = [{:state_timeout, @pg_startup_timeout, :pg_timeout}]
        :gen_statem.enter_loop(__MODULE__, [], :waiting_pg_startup, data, actions)

      grpc_aware ->
        actions = [{:state_timeout, 5_000, :grpc_timeout}]
        :gen_statem.enter_loop(__MODULE__, [], :waiting_grpc_authority, data, actions)

      true ->
        DrawbridgeCore.Telemetry.emit_connection_start(service_name, :port)
        actions = [{:state_timeout, 0, :do_connect}]
        :gen_statem.enter_loop(__MODULE__, [], :connecting, data, actions)
    end
  end

  @impl :gen_statem
  def callback_mode, do: :state_functions

  # ---- waiting_pg_startup — buffer PG startup bytes ----

  def waiting_pg_startup(
        :info,
        {msg_ok, socket, chunk},
        %{msg_ok: msg_ok, socket: socket, transport: transport, buffer: buf} = data
      ) do
    new_buf = buf <> chunk

    cond do
      byte_size(new_buf) > @max_pg_buffer ->
        Logger.debug("[PortHandler] PG startup buffer exceeded, dropping")
        {:stop, :normal}

      true ->
        handle_pg_bytes(new_buf, %{data | buffer: new_buf}, transport)
    end
  end

  def waiting_pg_startup(:state_timeout, :pg_timeout, data) do
    # Timed out waiting for PG startup — not a Postgres client. Pass the
    # buffered bytes through as regular port-based traffic.
    Logger.debug("[PortHandler] PG startup timeout, falling back to port routing")
    fallback_to_port_routing(data)
  end

  def waiting_pg_startup(:info, {msg_closed, socket}, %{msg_closed: msg_closed, socket: socket}) do
    {:stop, :normal}
  end

  def waiting_pg_startup(
        :info,
        {msg_error, socket, reason},
        %{msg_error: msg_error, socket: socket}
      ) do
    Logger.debug("[PortHandler] client error in waiting_pg_startup: #{inspect(reason)}")
    {:stop, :normal}
  end

  def waiting_pg_startup(event_type, event, data),
    do: handle_common(event_type, event, :waiting_pg_startup, data)

  # ---- waiting_grpc_authority — buffer HTTP/2 bytes for :authority ----

  def waiting_grpc_authority(
        :info,
        {msg_ok, socket, chunk},
        %{msg_ok: msg_ok, socket: socket, transport: transport, buffer: buf} = data
      ) do
    new_buf = buf <> chunk

    if byte_size(new_buf) > 8_192 do
      Logger.debug("[PortHandler] gRPC buffer exceeded, dropping")
      {:stop, :normal}
    else
      Logger.info("[PortHandler] gRPC received #{byte_size(new_buf)} bytes")

      # HTTP/2 requires a SETTINGS ack before client sends HEADERS.
      # Send our own SETTINGS + ack their SETTINGS so the client proceeds.
      data =
        if not Map.get(data, :h2_settings_sent, false) and byte_size(new_buf) >= 24 do
          settings_frame = <<0::24, 4::8, 0::8, 0::32>>
          settings_ack = <<0::24, 4::8, 1::8, 0::32>>
          transport.send(socket, settings_frame <> settings_ack)
          Map.put(data, :h2_settings_sent, true)
        else
          data
        end

      case DrawbridgeProxy.Protocol.Http2.extract_authority(new_buf) do
        {:ok, authority} ->
          Logger.info("[PortHandler] gRPC routing authority=#{authority}")

          case DrawbridgeCore.ServiceRegistry.lookup_by_hostname(authority) do
            {:ok, _pid} ->
              Logger.info("[PortHandler] gRPC matched service for #{authority}")
              data = %{data | service_name: authority, buffer: new_buf}
              DrawbridgeCore.Telemetry.emit_connection_start(authority, :grpc)
              {:next_state, :connecting, data, [{:state_timeout, 0, :do_connect}]}

            :error ->
              Logger.warning("[PortHandler] gRPC no service for authority=#{authority}")
              fallback_to_port_routing(%{data | buffer: new_buf})
          end

        {:error, :incomplete} ->
          Logger.info("[PortHandler] gRPC incomplete, waiting for more bytes")
          :ok = transport.setopts(socket, active: :once)
          {:keep_state, %{data | buffer: new_buf}}

        {:error, reason} ->
          Logger.warning(
            "[PortHandler] gRPC parse error: #{inspect(reason)}, buf=#{inspect(binary_part(new_buf, 0, min(byte_size(new_buf), 50)))}"
          )

          fallback_to_port_routing(%{data | buffer: new_buf})
      end
    end
  end

  def waiting_grpc_authority(:state_timeout, :grpc_timeout, data) do
    Logger.debug("[PortHandler] gRPC authority timeout, falling back to port routing")
    fallback_to_port_routing(data)
  end

  def waiting_grpc_authority(:info, {msg_closed, socket}, %{
        msg_closed: msg_closed,
        socket: socket
      }) do
    {:stop, :normal}
  end

  def waiting_grpc_authority(event_type, event, data),
    do: handle_common(event_type, event, :waiting_grpc_authority, data)

  # ---- connecting — initial state ----

  def connecting(:state_timeout, :do_connect, %{service_name: svc} = data) do
    case DrawbridgeCore.ServiceManager.request_connection(svc) do
      {:ok, {ip, port}} ->
        do_connect_backend(ip, port, data)

      {:wait, ref} ->
        Logger.debug("[PortHandler] waiting for container boot: #{svc}")

        {:next_state, :waiting_boot, %{data | wait_ref: ref},
         [{:state_timeout, @boot_wait_timeout, :boot_timeout}]}

      {:error, reason} ->
        Logger.debug("[PortHandler] unknown service #{svc}: #{inspect(reason)}")
        {:stop, :normal}
    end
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
    DrawbridgeCore.ServiceManager.ack(data.service_name)

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
    DrawbridgeCore.ServiceManager.ack(data.service_name)

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
    if data[:service_name] && data[:started_at] do
      duration = System.monotonic_time(:millisecond) - data.started_at
      DrawbridgeCore.Telemetry.emit_connection_stop(data.service_name, duration)
    end

    if data[:service_name] && data[:conn_ref] do
      DrawbridgeProxy.ProtocolRegistry.delete(data.service_name, data.conn_ref)
    end

    close_sockets(data)
    :ok
  end

  # ---- private: Postgres startup handling ----

  # SSLRequest — deny with 'N', client retries with plain StartupMessage
  defp handle_pg_bytes(<<8::32, 80_877_103::32, rest::binary>>, data, transport) do
    :ok = transport.send(data.socket, <<"N">>)
    :ok = transport.setopts(data.socket, active: :once)

    if byte_size(rest) > 0 do
      handle_pg_bytes(rest, %{data | buffer: rest}, transport)
    else
      {:keep_state, %{data | buffer: <<>>}, [{:state_timeout, @pg_startup_timeout, :pg_timeout}]}
    end
  end

  # StartupMessage: version 3.0 (196608)
  defp handle_pg_bytes(
         <<len::32, 196_608::32, _rest::binary>> = buf,
         data,
         _transport
       )
       when len > 8 and byte_size(buf) >= len do
    case DrawbridgeProxy.Protocol.Postgres.detect(buf) do
      {:ok, %{details: %{database: db}}} when is_binary(db) ->
        resolve_by_database(db, data)

      _ ->
        # Postgres startup but no database param — fall back
        fallback_to_port_routing(data)
    end
  end

  # We have a partial StartupMessage header — need more bytes
  defp handle_pg_bytes(<<len::32, 196_608::32, _rest::binary>> = buf, data, transport)
       when len > 8 and byte_size(buf) < len do
    :ok = transport.setopts(data.socket, active: :once)
    {:keep_state, data}
  end

  # Not enough bytes for even a header — keep waiting
  defp handle_pg_bytes(buf, data, transport) when byte_size(buf) < 8 do
    :ok = transport.setopts(data.socket, active: :once)
    {:keep_state, data}
  end

  # Unrecognized PG bytes — not a Postgres startup, fall back.
  # This also catches CancelRequest (<<16::32, 80877102::32, pid::32, key::32>>)
  # which is a 16-byte message with no version field. Falling through to port
  # routing is the correct behaviour: cancel requests are rare and the port
  # fallback will forward them to the right backend.
  defp handle_pg_bytes(_buf, data, _transport) do
    fallback_to_port_routing(data)
  end

  defp resolve_by_database(database, data) do
    case DrawbridgeCore.ServiceRegistry.lookup_by_database(database) do
      {:ok, {_pid, service_name}} ->
        Logger.debug("[PortHandler] PG routing database=#{database} -> #{service_name}")
        data = %{data | service_name: service_name}
        DrawbridgeCore.Telemetry.emit_connection_start(service_name, :database)
        {:next_state, :connecting, data, [{:state_timeout, 0, :do_connect}]}

      :error ->
        Logger.debug("[PortHandler] no service for database=#{database}, falling back to port")
        fallback_to_port_routing(data)
    end
  end

  defp fallback_to_port_routing(%{service_name: nil} = _data) do
    Logger.debug("[PortHandler] PG-aware port has no fallback service, dropping")
    {:stop, :normal}
  end

  defp fallback_to_port_routing(%{service_name: svc} = data) do
    DrawbridgeCore.Telemetry.emit_connection_start(svc, :port)
    {:next_state, :connecting, data, [{:state_timeout, 0, :do_connect}]}
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
        buf = Map.get(data, :buffer, <<>>)

        if byte_size(buf) > 0 do
          :ok = :gen_tcp.send(backend_socket, buf)
        end

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
