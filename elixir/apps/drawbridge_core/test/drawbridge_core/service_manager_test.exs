defmodule DrawbridgeCore.ServiceManagerTest do
  use ExUnit.Case, async: false

  alias DrawbridgeCore.ServiceManager
  alias DrawbridgeCore.Config.Service

  @service %Service{
    name: "test-svc",
    image: "test:latest",
    hostname: "test.dev.local",
    ports: [{8080, 80}],
    env: %{},
    idle_timeout: 1,
    boot_timeout: 5,
    tls_backend: false,
    depends_on: []
  }

  setup do
    # Each test gets its own service name to avoid Registry conflicts
    name = "test-svc-#{:rand.uniform(100_000)}"

    svc = %{
      @service
      | name: name,
        hostname: "#{name}.dev.local",
        ports: [{:rand.uniform(60_000) + 1024, 80}]
    }

    {:ok, svc: svc}
  end

  defp start_manager(svc) do
    {:ok, pid} = ServiceManager.start_service(svc)
    pid
  end

  test "starts in :not_pulled state", %{svc: svc} do
    start_manager(svc)
    info = ServiceManager.get_state(svc.name)
    assert info.state == :not_pulled
    assert info.connections == 0
    assert info.uptime == nil
  end

  test "transitions to :booting on request_connection from :not_pulled", %{svc: svc} do
    pid = start_manager(svc)

    # Mock SwiftBridge response: send container_ready after short delay
    self_pid = self()

    spawn(fn ->
      Process.sleep(50)
      send(pid, {:container_ready, svc.name, "127.0.0.1", svc.ports})
      send(self_pid, :done)
    end)

    result = ServiceManager.request_connection(svc.name, 2_000)
    assert {:ok, {"127.0.0.1", 80}} = result

    info = ServiceManager.get_state(svc.name)
    assert info.state == :running
    assert info.connections == 1
  end

  test "multiple waiters all get notified on container_ready", %{svc: svc} do
    pid = start_manager(svc)

    # Spawn 3 concurrent callers before container comes up
    tasks =
      for _ <- 1..3 do
        Task.async(fn -> ServiceManager.request_connection(svc.name, 3_000) end)
      end

    Process.sleep(50)
    send(pid, {:container_ready, svc.name, "10.0.0.1", svc.ports})

    results = Task.await_many(tasks, 3_000)
    assert Enum.all?(results, &match?({:ok, {"10.0.0.1", 80}}, &1))
  end

  test "container_error notifies all waiters with error", %{svc: svc} do
    pid = start_manager(svc)

    tasks =
      for _ <- 1..2 do
        Task.async(fn -> ServiceManager.request_connection(svc.name, 3_000) end)
      end

    Process.sleep(50)
    send(pid, {:container_error, svc.name, :image_not_found})

    results = Task.await_many(tasks, 3_000)
    assert Enum.all?(results, &match?({:error, :image_not_found}, &1))

    info = ServiceManager.get_state(svc.name)
    assert info.state == :stopped
  end

  test "release_connection decrements active_connections", %{svc: svc} do
    pid = start_manager(svc)
    send(pid, {:container_ready, svc.name, "127.0.0.1", svc.ports})
    Process.sleep(20)

    {:ok, _} = ServiceManager.request_connection(svc.name, 1_000)
    info = ServiceManager.get_state(svc.name)
    assert info.connections == 1

    ServiceManager.release_connection(svc.name)
    info = ServiceManager.get_state(svc.name)
    assert info.connections == 0
  end

  test "stop_service transitions to :stopped", %{svc: svc} do
    pid = start_manager(svc)
    send(pid, {:container_ready, svc.name, "127.0.0.1", svc.ports})
    Process.sleep(20)

    :ok = ServiceManager.stop_service(svc.name)
    info = ServiceManager.get_state(svc.name)
    assert info.state == :stopped
    assert info.ip == nil
  end

  test "service_not_found for unknown service" do
    assert {:error, :service_not_found} = ServiceManager.get_state("no-such-service-xyz")
    assert {:error, :service_not_found} = ServiceManager.request_connection("no-such-service-xyz")
  end

  test "ack resets idle timer while running", %{svc: svc} do
    pid = start_manager(svc)
    send(pid, {:container_ready, svc.name, "127.0.0.1", svc.ports})
    Process.sleep(20)

    # Request + release to start idle timer
    {:ok, _} = ServiceManager.request_connection(svc.name, 1_000)
    ServiceManager.release_connection(svc.name)
    Process.sleep(10)

    # Grab the timer ref before ack
    %{idle_timer: timer_before} = :sys.get_state(pid)
    assert timer_before != nil

    # ack should reset the timer (new ref)
    ServiceManager.ack(svc.name)
    Process.sleep(10)
    %{idle_timer: timer_after} = :sys.get_state(pid)
    assert timer_after != nil
    assert timer_after != timer_before
  end

  test "ack is ignored when not running", %{svc: svc} do
    _pid = start_manager(svc)
    # Service is :not_pulled, ack should be a no-op (no crash)
    assert :ok = ServiceManager.ack(svc.name)
    info = ServiceManager.get_state(svc.name)
    assert info.state == :not_pulled
  end

  test "running state returns immediately on request_connection", %{svc: svc} do
    pid = start_manager(svc)
    send(pid, {:container_ready, svc.name, "192.168.1.1", svc.ports})
    Process.sleep(20)

    # First call transitions from not_pulled; simulate ready
    result = ServiceManager.request_connection(svc.name, 1_000)
    assert {:ok, {"192.168.1.1", 80}} = result
  end
end
