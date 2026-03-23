defmodule DrawbridgeProxy.IntegrationTest do
  @moduledoc """
  Full-stack E2E integration tests exercising:
    config parse -> orchestrator -> service manager -> proxy listener -> SNI/port routing -> TCP relay

  Uses a real TCP backend on localhost with StubSwiftBridge in :auto_ready mode
  so ServiceManager boots instantly (no actual containers).
  """

  use ExUnit.Case, async: false

  alias DrawbridgeCore.Config
  alias DrawbridgeCore.Config.Service
  alias DrawbridgeCore.Orchestrator

  import DrawbridgeProxy.TestHelpers, only: [client_hello: 1]

  # ---- helpers ----

  defp start_echo_backend do
    {:ok, lsock} = :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true])
    {:ok, port} = :inet.port(lsock)

    pid =
      spawn_link(fn ->
        receive do
          :own -> :ok
        after
          5_000 -> raise "controlling_process handoff timed out"
        end

        do_accept_loop(lsock)
      end)

    :ok = :gen_tcp.controlling_process(lsock, pid)
    send(pid, :own)

    {lsock, port}
  end

  defp do_accept_loop(lsock) do
    case :gen_tcp.accept(lsock, 5_000) do
      {:ok, sock} ->
        spawn_link(fn -> echo_loop(sock) end)
        do_accept_loop(lsock)

      {:error, :timeout} ->
        do_accept_loop(lsock)

      {:error, :closed} ->
        :ok
    end
  end

  defp echo_loop(sock) do
    case :gen_tcp.recv(sock, 0, 5_000) do
      {:ok, data} ->
        :gen_tcp.send(sock, "echo:" <> data)
        echo_loop(sock)

      {:error, _} ->
        :gen_tcp.close(sock)
    end
  end

  defp make_service(name, hostname, ports) do
    %Service{
      name: name,
      image: "test:latest",
      hostname: hostname,
      ports: ports,
      env: %{},
      idle_timeout: 300,
      boot_timeout: 5,
      tls_backend: false,
      depends_on: []
    }
  end

  defp make_config(services) when is_list(services) do
    svc_map = Map.new(services, fn svc -> {svc.name, svc} end)

    %Config{
      domain: "dev.local",
      idle_timeout: 300,
      max_containers: 8,
      services: svc_map
    }
  end

  defp start_ranch_listener(ref, handler, opts \\ []) do
    {:ok, _} =
      :ranch.start_listener(
        ref,
        :ranch_tcp,
        %{socket_opts: [port: 0]},
        handler,
        opts
      )

    on_exit(fn -> :ranch.stop_listener(ref) end)

    # Read back the OS-assigned port to avoid TOCTOU race
    {_ip, port} = :ranch.get_addr(ref)
    wait_for_listener(port)
    port
  end

  defp wait_for_listener(port, attempts \\ 20) do
    case :gen_tcp.connect(~c"127.0.0.1", port, [:binary], 200) do
      {:ok, sock} ->
        :gen_tcp.close(sock)
        :ok

      {:error, _} when attempts > 0 ->
        Process.sleep(50)
        wait_for_listener(port, attempts - 1)

      {:error, reason} ->
        {:error, reason}
    end
  end

  # ---- setup / teardown ----

  setup do
    Application.put_env(:drawbridge_core, :stub_swift_bridge_mode, :auto_ready)

    on_exit(fn ->
      Application.delete_env(:drawbridge_core, :stub_swift_bridge_mode)

      try do
        Orchestrator.stop_all()
      catch
        _, _ -> :ok
      end
    end)

    :ok
  end

  # ---- tests ----

  describe "full-stack integration" do
    test "SNI-routed connection reaches backend through full stack" do
      {backend_lsock, backend_port} = start_echo_backend()
      on_exit(fn -> :gen_tcp.close(backend_lsock) end)

      # SniHandler looks up by service name, so name must equal the SNI hostname
      hostname = "sni-test-#{:rand.uniform(100_000)}.dev.local"
      ref = :"sni_integration_#{:rand.uniform(100_000)}"

      # Start listener first (port 0), then configure orchestrator with actual port
      tls_port = start_ranch_listener(ref, DrawbridgeProxy.SniHandler)

      service = make_service(hostname, hostname, [{tls_port, backend_port}])
      :ok = Orchestrator.start(make_config([service]))

      {:ok, sock} = :gen_tcp.connect(~c"127.0.0.1", tls_port, [:binary, active: false], 3_000)
      hello = client_hello(hostname)
      :ok = :gen_tcp.send(sock, hello)

      # Backend receives the ClientHello verbatim and echoes it back
      {:ok, response} = :gen_tcp.recv(sock, 0, 5_000)
      assert response == "echo:" <> hello

      :gen_tcp.close(sock)
    end

    test "port-routed connection reaches backend through full stack" do
      {backend_lsock, backend_port} = start_echo_backend()
      on_exit(fn -> :gen_tcp.close(backend_lsock) end)

      svc_name = "port-test-#{:rand.uniform(100_000)}"
      ref = :"port_integration_#{:rand.uniform(100_000)}"

      # Start listener first (port 0), then configure orchestrator with actual port
      host_port = start_ranch_listener(ref, DrawbridgeProxy.PortHandler, service_name: svc_name)

      service = make_service(svc_name, "#{svc_name}.dev.local", [{host_port, backend_port}])
      :ok = Orchestrator.start(make_config([service]))

      {:ok, sock} = :gen_tcp.connect(~c"127.0.0.1", host_port, [:binary, active: false], 3_000)
      :ok = :gen_tcp.send(sock, "hello from port test")

      {:ok, response} = :gen_tcp.recv(sock, 0, 5_000)
      assert response == "echo:hello from port test"

      # Verify bidirectional relay
      :ok = :gen_tcp.send(sock, "second message")
      {:ok, response2} = :gen_tcp.recv(sock, 0, 5_000)
      assert response2 == "echo:second message"

      :gen_tcp.close(sock)
    end

    test "connection to unknown hostname is dropped" do
      ref = :"sni_unknown_#{:rand.uniform(100_000)}"
      tls_port = start_ranch_listener(ref, DrawbridgeProxy.SniHandler)

      {:ok, sock} = :gen_tcp.connect(~c"127.0.0.1", tls_port, [:binary, active: false], 3_000)
      :ok = :gen_tcp.send(sock, client_hello("nonexistent.dev.local"))

      result = :gen_tcp.recv(sock, 0, 3_000)
      assert result in [{:error, :closed}, {:error, :econnreset}]
    end

    test "multiple concurrent connections are routed correctly" do
      {backend_lsock, backend_port} = start_echo_backend()
      on_exit(fn -> :gen_tcp.close(backend_lsock) end)

      svc_name = "concurrent-test-#{:rand.uniform(100_000)}"
      ref = :"port_concurrent_#{:rand.uniform(100_000)}"

      # Start listener first (port 0), then configure orchestrator with actual port
      host_port =
        start_ranch_listener(ref, DrawbridgeProxy.PortHandler, service_name: svc_name)

      service = make_service(svc_name, "#{svc_name}.dev.local", [{host_port, backend_port}])
      :ok = Orchestrator.start(make_config([service]))

      tasks =
        for i <- 1..5 do
          Task.async(fn ->
            {:ok, sock} =
              :gen_tcp.connect(~c"127.0.0.1", host_port, [:binary, active: false], 3_000)

            payload = "conn-#{i}"
            :ok = :gen_tcp.send(sock, payload)
            {:ok, resp} = :gen_tcp.recv(sock, 0, 5_000)
            :gen_tcp.close(sock)
            {i, resp}
          end)
        end

      results = Task.await_many(tasks, 10_000)

      for {i, resp} <- results do
        assert resp == "echo:conn-#{i}", "Connection #{i} got wrong response: #{inspect(resp)}"
      end
    end
  end
end
