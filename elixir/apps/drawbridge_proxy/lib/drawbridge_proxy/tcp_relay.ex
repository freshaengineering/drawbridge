defmodule DrawbridgeProxy.TcpRelay do
  @moduledoc """
  Bidirectional TCP relay between a Ranch-managed client socket and a
  plain :gen_tcp backend socket.

  Runs a blocking receive loop — call from a dedicated process (e.g.
  spawn_link). Closes both sockets cleanly when either side disconnects
  or errors.
  """

  require Logger

  @spec relay(port(), port(), module()) :: :ok
  def relay(client_socket, backend_socket, transport) do
    {msg_ok, msg_closed, msg_error} = transport.messages()
    :ok = transport.setopts(client_socket, active: :once)
    :ok = :inet.setopts(backend_socket, active: :once)
    loop(client_socket, backend_socket, transport, {msg_ok, msg_closed, msg_error})
  end

  defp loop(client, backend, transport, {msg_ok, msg_closed, msg_error} = msgs) do
    receive do
      # Client -> backend
      {^msg_ok, ^client, data} ->
        case :gen_tcp.send(backend, data) do
          :ok ->
            transport.setopts(client, active: :once)
            loop(client, backend, transport, msgs)

          {:error, reason} ->
            Logger.debug("[TcpRelay] backend send error: #{inspect(reason)}")
            close(client, backend, transport)
        end

      # Backend -> client
      {:tcp, ^backend, data} ->
        case transport.send(client, data) do
          :ok ->
            :inet.setopts(backend, active: :once)
            loop(client, backend, transport, msgs)

          {:error, reason} ->
            Logger.debug("[TcpRelay] client send error: #{inspect(reason)}")
            close(client, backend, transport)
        end

      {^msg_closed, ^client} ->
        close(client, backend, transport)

      {:tcp_closed, ^backend} ->
        close(client, backend, transport)

      {^msg_error, ^client, reason} ->
        Logger.debug("[TcpRelay] client error: #{inspect(reason)}")
        close(client, backend, transport)

      {:tcp_error, ^backend, reason} ->
        Logger.debug("[TcpRelay] backend error: #{inspect(reason)}")
        close(client, backend, transport)
    end
  end

  defp close(client, backend, transport) do
    transport.close(client)
    :gen_tcp.close(backend)
    :ok
  end
end
