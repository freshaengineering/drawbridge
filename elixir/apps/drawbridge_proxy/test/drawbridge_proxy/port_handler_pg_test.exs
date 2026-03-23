defmodule DrawbridgeProxy.PortHandlerPgTest do
  @moduledoc """
  Tests for Postgres wire-protocol routing in PortHandler.

  Starts a pg_aware Ranch listener, sends crafted Postgres startup
  messages, and asserts routing behaviour. Like the SniHandler tests,
  the handler will crash when it tries to call ServiceManager (not
  running in test) — we validate protocol-level responses (SSLRequest
  denial) and socket lifecycle.
  """

  use ExUnit.Case, async: false

  @test_port_base 19_900

  # ---- helpers: Postgres wire protocol ----

  defp pg_startup_message(database, user \\ "postgres") do
    params = "user\0#{user}\0database\0#{database}\0\0"
    length = 4 + 4 + byte_size(params)
    <<length::32, 196_608::32, params::binary>>
  end

  defp pg_ssl_request do
    <<8::32, 80_877_103::32>>
  end

  defp start_pg_listener(ref, opts \\ []) do
    port = @test_port_base + :erlang.phash2(ref, 100)
    service_name = Keyword.get(opts, :service_name)

    handler_opts =
      [pg_aware: true] ++ if(service_name, do: [service_name: service_name], else: [])

    {:ok, _} =
      :ranch.start_listener(
        ref,
        :ranch_tcp,
        %{socket_opts: [port: port]},
        DrawbridgeProxy.PortHandler,
        handler_opts
      )

    port
  end

  defp stop_listener(ref) do
    :ranch.stop_listener(ref)
  end

  # ---- tests ----

  describe "SSLRequest handling" do
    test "responds with 'N' to deny SSL, then accepts StartupMessage" do
      ref = make_ref()
      port = start_pg_listener(ref)
      on_exit(fn -> stop_listener(ref) end)

      {:ok, sock} = :gen_tcp.connect(~c"127.0.0.1", port, [:binary, active: false])

      # Send SSLRequest
      :ok = :gen_tcp.send(sock, pg_ssl_request())

      # Should get back 'N' (SSL denied)
      assert {:ok, "N"} = :gen_tcp.recv(sock, 1, 2_000)

      # Now send the actual StartupMessage — handler will try to look up
      # the database in ServiceRegistry (which won't find anything) and
      # then try to fall back to port routing (which will also fail since
      # no ServiceManager is running). Connection closes.
      :ok = :gen_tcp.send(sock, pg_startup_message("myapp_dev"))

      result = :gen_tcp.recv(sock, 0, 2_000)
      assert result in [{:error, :closed}, {:error, :econnreset}]
    end
  end

  describe "StartupMessage routing" do
    test "closes connection when database has no matching service" do
      ref = make_ref()
      port = start_pg_listener(ref)
      on_exit(fn -> stop_listener(ref) end)

      {:ok, sock} = :gen_tcp.connect(~c"127.0.0.1", port, [:binary, active: false])

      # Send StartupMessage directly (no SSLRequest)
      :ok = :gen_tcp.send(sock, pg_startup_message("unknown_db"))

      # Handler looks up database, finds nothing, falls back to port routing,
      # which also has no service — connection drops
      result = :gen_tcp.recv(sock, 0, 2_000)
      assert result in [{:error, :closed}, {:error, :econnreset}]
    end

    test "handles StartupMessage with extra params" do
      ref = make_ref()
      port = start_pg_listener(ref)
      on_exit(fn -> stop_listener(ref) end)

      {:ok, sock} = :gen_tcp.connect(~c"127.0.0.1", port, [:binary, active: false])

      params = "user\0admin\0database\0app_dev\0application_name\0psql\0\0"
      length = 4 + 4 + byte_size(params)
      msg = <<length::32, 196_608::32, params::binary>>

      :ok = :gen_tcp.send(sock, msg)

      result = :gen_tcp.recv(sock, 0, 2_000)
      assert result in [{:error, :closed}, {:error, :econnreset}]
    end
  end

  describe "non-Postgres traffic on pg_aware port" do
    test "falls back to port routing for HTTP traffic" do
      ref = make_ref()
      port = start_pg_listener(ref)
      on_exit(fn -> stop_listener(ref) end)

      {:ok, sock} = :gen_tcp.connect(~c"127.0.0.1", port, [:binary, active: false])

      # Send HTTP instead of Postgres
      :ok = :gen_tcp.send(sock, "GET / HTTP/1.1\r\nHost: example.com\r\n\r\n")

      # Handler can't parse this as PG, falls back to port routing,
      # no service found, connection closes
      result = :gen_tcp.recv(sock, 0, 2_000)
      assert result in [{:error, :closed}, {:error, :econnreset}]
    end

    test "handles empty/tiny payloads gracefully via timeout" do
      ref = make_ref()
      port = start_pg_listener(ref)
      on_exit(fn -> stop_listener(ref) end)

      {:ok, sock} = :gen_tcp.connect(~c"127.0.0.1", port, [:binary, active: false])

      # Send just 2 bytes — not enough for a PG header
      :ok = :gen_tcp.send(sock, <<0x00, 0x01>>)

      # Handler buffers, waits for more, eventually times out (5s) and
      # falls back to port routing — connection closes
      result = :gen_tcp.recv(sock, 0, 7_000)
      assert result in [{:error, :closed}, {:error, :econnreset}]
    end
  end

  describe "fragmented StartupMessage" do
    test "handles StartupMessage split across two TCP segments" do
      ref = make_ref()
      port = start_pg_listener(ref)
      on_exit(fn -> stop_listener(ref) end)

      {:ok, sock} = :gen_tcp.connect(~c"127.0.0.1", port, [:binary, active: false])

      # Build a full StartupMessage, then split it in two
      msg = pg_startup_message("fragmented_db")
      split_at = 8
      <<first::binary-size(split_at), rest::binary>> = msg

      # Send just the header (length + version) — handler should buffer
      :ok = :gen_tcp.send(sock, first)
      Process.sleep(50)

      # Send the rest of the params
      :ok = :gen_tcp.send(sock, rest)

      # Handler reassembles, looks up "fragmented_db", finds nothing,
      # falls back to port routing (no service) — connection closes
      result = :gen_tcp.recv(sock, 0, 2_000)
      assert result in [{:error, :closed}, {:error, :econnreset}]
    end
  end

  describe "oversized buffer" do
    test "drops connection when PG startup buffer exceeds limit" do
      ref = make_ref()
      port = start_pg_listener(ref)
      on_exit(fn -> stop_listener(ref) end)

      {:ok, sock} = :gen_tcp.connect(~c"127.0.0.1", port, [:binary, active: false])

      # Send >4KB of junk
      :ok = :gen_tcp.send(sock, :binary.copy(<<0xFF>>, 5_000))

      result = :gen_tcp.recv(sock, 0, 2_000)
      assert result in [{:error, :closed}, {:error, :econnreset}]
    end
  end
end
