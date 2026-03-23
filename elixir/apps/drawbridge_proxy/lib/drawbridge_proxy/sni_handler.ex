defmodule DrawbridgeProxy.SniHandler do
  @moduledoc """
  Ranch protocol handler for TLS connections on port 443 (and any other
  TLS-terminated port).

  We accept the raw TCP connection, buffer bytes until we have a complete
  TLS ClientHello, extract the SNI hostname, look up the service, and
  then relay the *unmodified* byte stream (including the ClientHello we
  already read) to the backend container. TLS is terminated by the
  container, not by us.

  State machine:
    waiting_hello  ->  connecting_backend  ->  relaying
                  \\->  relaying (immediate, if container already up)
  """

  @behaviour :ranch_protocol
  @behaviour :gen_statem

  require Logger

  @max_buffer 16_384
  @backend_connect_timeout 5_000
  # max time to wait for a container to boot before dropping the connection
  @boot_wait_timeout 30_000

  # ---- Ranch protocol entry point ----

  @impl :ranch_protocol
  def start_link(ref, transport, opts) do
    {:ok, :proc_lib.spawn_link(__MODULE__, :init, [{ref, transport, opts}])}
  end

  @impl :gen_statem
  def init({ref, transport, _opts}) do
    {:ok, socket} = :ranch.handshake(ref)
    :ok = transport.setopts(socket, active: :once)
    # Ranch 2.x transport.messages/0 returns {ok, closed, error, passive}
    {msg_ok, msg_closed, msg_error, _msg_passive} = transport.messages()

    data = %{
      transport: transport,
      socket: socket,
      buffer: <<>>,
      service_name: nil,
      backend_socket: nil,
      wait_ref: nil,
      conn_ref: make_ref(),
      protocol_detected: false,
      msg_ok: msg_ok,
      msg_closed: msg_closed,
      msg_error: msg_error,
      started_at: System.monotonic_time(:millisecond)
    }

    :gen_statem.enter_loop(__MODULE__, [], :waiting_hello, data)
  end

  @impl :gen_statem
  def callback_mode, do: :state_functions

  # ---- waiting_hello ----

  def waiting_hello(
        :info,
        {msg_ok, socket, chunk},
        %{msg_ok: msg_ok, socket: socket, transport: transport, buffer: buf} = data
      ) do
    new_buf = buf <> chunk

    cond do
      byte_size(new_buf) > @max_buffer ->
        Logger.debug("[SniHandler] ClientHello exceeds #{@max_buffer} bytes, dropping")
        {:stop, :normal}

      true ->
        case DrawbridgeProxy.TlsParser.parse_client_hello(new_buf) do
          {:ok, hostname} ->
            do_sni_lookup(hostname, new_buf, %{data | buffer: new_buf})

          {:error, :incomplete} ->
            :ok = transport.setopts(socket, active: :once)
            {:keep_state, %{data | buffer: new_buf}}

          {:error, reason} ->
            Logger.debug("[SniHandler] TLS parse error: #{reason}, dropping")
            {:stop, :normal}
        end
    end
  end

  def waiting_hello(:info, {msg_closed, socket}, %{msg_closed: msg_closed, socket: socket}) do
    {:stop, :normal}
  end

  def waiting_hello(:info, {msg_error, socket, reason}, %{msg_error: msg_error, socket: socket}) do
    Logger.debug("[SniHandler] socket error in waiting_hello: #{inspect(reason)}")
    {:stop, :normal}
  end

  def waiting_hello(event_type, event, data),
    do: handle_common(event_type, event, :waiting_hello, data)

  # ---- connecting_backend ----

  def connecting_backend(
        :info,
        {:container_ready, ref, ip, port},
        %{wait_ref: ref, buffer: buf} = data
      ) do
    do_connect_backend(ip, port, buf, data)
  end

  def connecting_backend(:state_timeout, :boot_timeout, %{service_name: svc} = data) do
    Logger.warning("[SniHandler] timeout waiting for container #{svc}")
    DrawbridgeCore.ServiceManager.release_connection(svc)
    close_sockets(data)
    {:stop, :normal}
  end

  def connecting_backend(
        :info,
        {msg_closed, socket},
        %{msg_closed: msg_closed, socket: socket} = data
      ) do
    DrawbridgeCore.ServiceManager.release_connection(data.service_name)
    {:stop, :normal}
  end

  def connecting_backend(event_type, event, data),
    do: handle_common(event_type, event, :connecting_backend, data)

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

      {:error, _reason} ->
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

      {:error, _reason} ->
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
    Logger.debug("[SniHandler] client error in relay: #{inspect(reason)}")
    close_and_stop(data)
  end

  def relaying(:info, {:tcp_error, socket, reason}, %{backend_socket: socket} = data) do
    Logger.debug("[SniHandler] backend error in relay: #{inspect(reason)}")
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

  # ---- private ----

  defp maybe_detect_protocol(_chunk, %{protocol_detected: true} = data), do: data
  defp maybe_detect_protocol(_chunk, %{service_name: nil} = data), do: data

  defp maybe_detect_protocol(_chunk, %{service_name: svc, conn_ref: ref} = data) do
    # For TLS connections we can't inspect the encrypted payload,
    # so we just record :tls with the SNI hostname
    meta = %{protocol: :tls, details: %{sni_hostname: svc}}
    DrawbridgeProxy.ProtocolRegistry.store(svc, ref, meta)
    %{data | protocol_detected: true}
  end

  defp do_sni_lookup(hostname, buffered, data) do
    case DrawbridgeCore.ServiceManager.request_connection(hostname) do
      {:ok, {ip, port}} ->
        DrawbridgeCore.Telemetry.emit_connection_start(hostname, :sni)
        do_connect_backend(ip, port, buffered, %{data | service_name: hostname})

      {:wait, ref} ->
        DrawbridgeCore.Telemetry.emit_connection_start(hostname, :sni)
        Logger.debug("[SniHandler] waiting for container boot: #{hostname}")
        new_data = %{data | service_name: hostname, wait_ref: ref}

        {:next_state, :connecting_backend, new_data,
         [{:state_timeout, @boot_wait_timeout, :boot_timeout}]}

      {:error, reason} ->
        Logger.debug("[SniHandler] unknown service #{hostname}: #{inspect(reason)}")
        send_fallback_page(data.socket, data.transport, hostname)
        {:stop, :normal, data}
    end
  end

  defp send_fallback_page(socket, transport, hostname) do
    paths = DrawbridgeCore.CertManager.cert_paths()

    ssl_opts = [
      certfile: paths.cert,
      keyfile: paths.key
    ]

    case :ssl.handshake(socket, ssl_opts, 5_000) do
      {:ok, ssl_socket} ->
        html = build_fallback_html(hostname)

        response =
          "HTTP/1.1 503 Service Unavailable\r\n" <>
            "Content-Type: text/html; charset=utf-8\r\n" <>
            "Content-Length: #{byte_size(html)}\r\n" <>
            "Connection: close\r\n" <>
            "\r\n" <>
            html

        :ssl.send(ssl_socket, response)
        :ssl.close(ssl_socket)

      {:error, reason} ->
        Logger.debug("[SniHandler] fallback TLS handshake failed: #{inspect(reason)}")
        transport.close(socket)
    end
  end

  defp build_fallback_html(hostname) do
    services = fetch_service_rows()

    service_rows =
      if services == [] do
        ~s(<tr><td colspan="4" style="text-align:center;color:#888;">No services configured</td></tr>)
      else
        Enum.map_join(services, "\n", fn svc ->
          ports_str =
            svc.ports
            |> Enum.map(fn {h, c} -> "#{h}:#{c}" end)
            |> Enum.join(", ")

          state_color =
            case svc.state do
              :running -> "#4caf50"
              :booting -> "#ff9800"
              _ -> "#888"
            end

          """
          <tr>
            <td>#{html_escape(svc.name)}</td>
            <td>#{html_escape(svc.hostname || "—")}</td>
            <td>#{html_escape(ports_str)}</td>
            <td style="color:#{state_color};font-weight:600;">#{html_escape(svc.state)}</td>
          </tr>
          """
        end)
      end

    """
    <!DOCTYPE html>
    <html lang="en">
    <head>
      <meta charset="utf-8">
      <meta name="viewport" content="width=device-width, initial-scale=1">
      <title>Drawbridge — Unknown Host</title>
      <style>
        * { margin: 0; padding: 0; box-sizing: border-box; }
        body { font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif; background: #1a1a2e; color: #e0e0e0; display: flex; justify-content: center; padding: 3rem 1rem; }
        .container { max-width: 640px; width: 100%; }
        h1 { font-size: 1.5rem; color: #ff6b6b; margin-bottom: .5rem; }
        .hostname { font-family: monospace; background: #16213e; padding: 2px 8px; border-radius: 4px; color: #ffd93d; }
        p { margin: .75rem 0; line-height: 1.5; color: #aaa; }
        table { width: 100%; border-collapse: collapse; margin-top: 1.5rem; }
        th { text-align: left; padding: .5rem .75rem; border-bottom: 2px solid #333; color: #ccc; font-size: .85rem; text-transform: uppercase; letter-spacing: .05em; }
        td { padding: .5rem .75rem; border-bottom: 1px solid #262640; font-size: .9rem; }
        tr:hover td { background: #16213e; }
        .hint { margin-top: 2rem; padding: 1rem; background: #16213e; border-left: 3px solid #ffd93d; border-radius: 4px; font-size: .85rem; color: #bbb; }
        code { font-family: monospace; color: #ffd93d; }
      </style>
    </head>
    <body>
      <div class="container">
        <h1>Unknown hostname</h1>
        <p>Drawbridge received a request for <span class="hostname">#{html_escape(hostname)}</span> but no service is configured for that hostname.</p>

        <h2 style="font-size:1.1rem;margin-top:1.5rem;">Configured services</h2>
        <table>
          <thead><tr><th>Name</th><th>Hostname</th><th>Ports</th><th>State</th></tr></thead>
          <tbody>
            #{service_rows}
          </tbody>
        </table>

        <div class="hint">
          To add a service, edit <code>drawbridge.yml</code> and add a <code>hostname</code> field to your service definition, then restart Drawbridge.
        </div>
      </div>
    </body>
    </html>
    """
  end

  defp fetch_service_rows do
    DrawbridgeCore.ServiceManager.list_services()
  catch
    _, _ -> []
  end

  defp html_escape(nil), do: ""

  defp html_escape(val) when is_atom(val), do: html_escape(Atom.to_string(val))

  defp html_escape(str) when is_binary(str) do
    str
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
    |> String.replace("\"", "&quot;")
  end

  defp do_connect_backend(ip, port, initial_bytes, data) do
    ip_addr = parse_ip(ip)

    case :gen_tcp.connect(
           ip_addr,
           port,
           [:binary, active: :once, nodelay: true],
           @backend_connect_timeout
         ) do
      {:ok, backend_socket} ->
        # Forward the buffered ClientHello verbatim so the backend does TLS handshake
        :ok = :gen_tcp.send(backend_socket, initial_bytes)
        :ok = data.transport.setopts(data.socket, active: :once)
        Logger.debug("[SniHandler] relaying #{data.service_name} -> #{ip}:#{port}")
        {:next_state, :relaying, %{data | backend_socket: backend_socket}}

      {:error, reason} ->
        Logger.warning("[SniHandler] backend connect #{ip}:#{port} failed: #{inspect(reason)}")

        if data.service_name,
          do: DrawbridgeCore.ServiceManager.release_connection(data.service_name)

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
    Logger.debug("[SniHandler] unexpected event in #{state}")
    :keep_state_and_data
  end

  defp parse_ip(ip) when is_binary(ip) do
    {:ok, addr} = ip |> String.to_charlist() |> :inet.parse_address()
    addr
  end

  defp parse_ip(ip) when is_tuple(ip), do: ip
end
