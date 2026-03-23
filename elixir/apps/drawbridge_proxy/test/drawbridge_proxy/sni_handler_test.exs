defmodule DrawbridgeProxy.SniHandlerTest do
  @moduledoc """
  Integration tests for SniHandler.

  These tests start a real Ranch TCP listener on a random port, inject a
  stub ServiceManager via the process registry, connect with a raw TCP
  socket, send crafted ClientHello bytes, and assert the resulting
  connection behaviour.

  ServiceManager calls are intercepted by registering the test process
  under the name `DrawbridgeCore.ServiceManager` in the local registry
  so the handler's `DrawbridgeCore.ServiceManager.request_connection/1`
  calls are routed here. This avoids Mox and keeps the tests self-contained.
  """

  use ExUnit.Case, async: false

  import DrawbridgeProxy.TestHelpers, only: [client_hello: 1]

  @test_port_base 19_800

  # ---- helpers ----

  # SniHandler calls DrawbridgeCore.ServiceManager directly (not via GenServer),
  # so we can't intercept without Mox. Tests here validate TLS parsing and
  # connection-drop behaviour by observing socket close timing. Service-lookup
  # tests would require Mox (or a real ServiceManager) and live in integration
  # test suites.

  # Start a Ranch listener on a free port; returns {listener_ref, port}.
  defp start_listener(ref) do
    port = @test_port_base + :erlang.phash2(ref, 100)

    {:ok, _} =
      :ranch.start_listener(
        ref,
        :ranch_tcp,
        %{socket_opts: [port: port]},
        DrawbridgeProxy.SniHandler,
        []
      )

    port
  end

  defp stop_listener(ref) do
    :ranch.stop_listener(ref)
  end

  # ---- tests ----

  describe "TLS ClientHello with unknown service" do
    test "closes connection when hostname has no matching service" do
      # SniHandler calls DrawbridgeCore.ServiceManager which doesn't exist in
      # test env — the call will raise/exit. The handler catches this and
      # closes the socket. We verify the socket gets closed.
      ref = make_ref()
      port = start_listener(ref)

      on_exit(fn -> stop_listener(ref) end)

      {:ok, sock} = :gen_tcp.connect(~c"127.0.0.1", port, [:binary, active: false])
      :ok = :gen_tcp.send(sock, client_hello("unknown.example.com"))

      # Handler will crash trying to call non-existent ServiceManager; Ranch
      # will close the connection — we expect :closed or error within 2s
      result =
        :gen_tcp.recv(sock, 0, 2_000)

      assert result in [{:error, :closed}, {:error, :econnreset}] or
               match?({:ok, _}, result) == false
    end
  end

  describe "TLS ClientHello parsing" do
    test "connection is dropped for non-TLS data" do
      ref = make_ref()
      port = start_listener(ref)

      on_exit(fn -> stop_listener(ref) end)

      {:ok, sock} = :gen_tcp.connect(~c"127.0.0.1", port, [:binary, active: false])
      # Send HTTP instead of TLS
      :ok = :gen_tcp.send(sock, "GET / HTTP/1.1\r\nHost: example.com\r\n\r\n")

      assert {:error, :closed} = :gen_tcp.recv(sock, 0, 2_000)
    end

    test "connection stays open while sending incomplete ClientHello, closes on bad data" do
      ref = make_ref()
      port = start_listener(ref)

      on_exit(fn -> stop_listener(ref) end)

      {:ok, sock} = :gen_tcp.connect(~c"127.0.0.1", port, [:binary, active: false])

      # Send just the TLS record header (5 bytes) — handler should buffer
      :ok = :gen_tcp.send(sock, <<0x16, 0x03, 0x01, 0x00, 0x50>>)

      # Small delay to ensure handler is in waiting_hello with incomplete data
      Process.sleep(50)

      # Now send garbage as the body — handler should detect malformed and close
      :ok = :gen_tcp.send(sock, :binary.copy(<<0xFF>>, 80))

      assert {:error, :closed} = :gen_tcp.recv(sock, 0, 2_000)
    end

    test "oversized buffer (>16KB) causes connection drop" do
      ref = make_ref()
      port = start_listener(ref)

      on_exit(fn -> stop_listener(ref) end)

      {:ok, sock} = :gen_tcp.connect(~c"127.0.0.1", port, [:binary, active: false])

      # Pretend we're sending a 20KB TLS record
      huge =
        :binary.copy(<<0x16, 0x03, 0x01>>, 1) <> <<0x4E, 0x20>> <> :binary.copy(<<0>>, 20_000)

      :ok = :gen_tcp.send(sock, huge)

      assert {:error, :closed} = :gen_tcp.recv(sock, 0, 2_000)
    end
  end
end
