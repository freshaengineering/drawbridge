defmodule DrawbridgeCore.ServiceManager do
  @moduledoc """
  GenServer per service. Manages the container lifecycle state machine.

  States: :not_pulled -> :stopped -> :booting -> :running

  Started via DynamicSupervisor, registered via Registry with {:name, service_name}.
  """
  use GenServer
  require Logger

  @registry DrawbridgeCore.ServiceRegistry

  defstruct [
    :service,
    :state,
    :ip,
    :ports,
    :idle_timer,
    :started_at,
    :boot_started_at,
    waiters: [],
    active_connections: 0
  ]

  # -- Public API --

  @doc "Start a ServiceManager for the given service config under the DynamicSupervisor."
  def start_service(%DrawbridgeCore.Config.Service{} = service) do
    DynamicSupervisor.start_child(
      DrawbridgeCore.ServiceSupervisor,
      {__MODULE__, service}
    )
  end

  @doc "Request a connection to a service. Returns {:ok, {ip, port}} or {:wait, ref} or {:error, reason}."
  def request_connection(service_name, timeout \\ 30_000) do
    case lookup(service_name) do
      {:ok, pid} -> GenServer.call(pid, {:request_connection, self()}, timeout)
      :error -> {:error, :service_not_found}
    end
  end

  @doc "Release a connection to a service (decrement active count, restart idle timer if 0)."
  def release_connection(service_name) do
    case lookup(service_name) do
      {:ok, pid} -> GenServer.cast(pid, :release_connection)
      :error -> :ok
    end
  end

  @doc "Get current state info for a service."
  def get_state(service_name) do
    case lookup(service_name) do
      {:ok, pid} -> GenServer.call(pid, :get_state)
      :error -> {:error, :service_not_found}
    end
  end

  @doc "Stop a running container and reset state to :stopped."
  def stop_service(service_name) do
    case lookup(service_name) do
      {:ok, pid} -> GenServer.call(pid, :stop_service)
      :error -> {:error, :service_not_found}
    end
  end

  @doc "List all services and their current states."
  def list_services do
    DrawbridgeCore.ServiceRegistry.list_services()
    |> Enum.map(fn {_meta, pid} ->
      GenServer.call(pid, :get_state)
    end)
    |> Enum.reject(&match?({:error, _}, &1))
  end

  def child_spec(%DrawbridgeCore.Config.Service{} = service) do
    %{
      id: {__MODULE__, service.name},
      start: {__MODULE__, :start_link, [service]},
      restart: :transient
    }
  end

  def start_link(%DrawbridgeCore.Config.Service{} = service) do
    GenServer.start_link(__MODULE__, service, name: via(service.name))
  end

  # -- Callbacks --

  @impl true
  def init(%DrawbridgeCore.Config.Service{} = service) do
    DrawbridgeCore.ServiceRegistry.register_service(
      service.name,
      service.hostname,
      service.ports,
      database: service.database
    )

    state = %__MODULE__{
      service: service,
      state: :not_pulled,
      ip: nil,
      ports: service.ports,
      waiters: [],
      active_connections: 0,
      idle_timer: nil,
      started_at: nil
    }

    {:ok, state}
  end

  @impl true
  def handle_call({:request_connection, _caller_pid}, _from, %{state: :running} = s) do
    s = cancel_idle_timer(s)
    s = %{s | active_connections: s.active_connections + 1}
    {_, first_container_port} = hd(s.ports)
    {:reply, {:ok, {s.ip, first_container_port}}, reset_idle_timer(s)}
  end

  def handle_call({:request_connection, _caller_pid}, from, %{state: container_state} = s)
      when container_state in [:stopped, :not_pulled] do
    ref = make_ref()
    DrawbridgeCore.Telemetry.emit_boot_start(s.service.name, s.service.image)

    s = %{
      s
      | waiters: [{from, ref} | s.waiters],
        state: :booting,
        boot_started_at: System.monotonic_time(:millisecond)
    }

    start_container_async(s.service)
    {:noreply, s}
  end

  def handle_call({:request_connection, _caller_pid}, from, %{state: :booting} = s) do
    ref = make_ref()
    s = %{s | waiters: [{from, ref} | s.waiters]}
    {:noreply, s}
  end

  def handle_call(:get_state, _from, s) do
    uptime =
      if s.started_at do
        System.monotonic_time(:second) - s.started_at
      else
        nil
      end

    info = %{
      name: s.service.name,
      state: s.state,
      hostname: s.service.hostname,
      image: s.service.image,
      ports: s.ports,
      ip: s.ip,
      connections: s.active_connections,
      uptime: uptime,
      depends_on: s.service.depends_on || []
    }

    {:reply, info, s}
  end

  def handle_call(:stop_service, _from, s) do
    s = cancel_idle_timer(s)

    if s.state == :running do
      name = s.service.name
      bridge = swift_bridge()
      Task.start(fn -> bridge.call_agent({:stop, name}) end)
    end

    {:reply, :ok, %{s | state: :stopped, ip: nil, started_at: nil, active_connections: 0}}
  end

  @impl true
  def handle_cast(:release_connection, s) do
    count = max(0, s.active_connections - 1)
    s = %{s | active_connections: count}

    s =
      if count == 0 do
        reset_idle_timer(s)
      else
        s
      end

    {:noreply, s}
  end

  @impl true
  def handle_info({:container_ready, name, ip, _ports}, s) when name == s.service.name do
    DrawbridgeCore.Telemetry.emit_boot_stop(name, boot_duration_ms(s), true)

    {_, first_container_port} = hd(s.ports)

    Enum.each(s.waiters, fn {from, _ref} ->
      GenServer.reply(from, {:ok, {ip, first_container_port}})
    end)

    s = %{
      s
      | state: :running,
        ip: ip,
        waiters: [],
        active_connections: length(s.waiters),
        started_at: System.monotonic_time(:second),
        boot_started_at: nil
    }

    {:noreply, reset_idle_timer(s)}
  end

  def handle_info({:container_error, name, reason}, s) when name == s.service.name do
    DrawbridgeCore.Telemetry.emit_boot_stop(name, boot_duration_ms(s), false)
    Logger.error("[ServiceManager] Container error for #{name}: #{inspect(reason)}")

    Enum.each(s.waiters, fn {from, _ref} ->
      GenServer.reply(from, {:error, reason})
    end)

    {:noreply, %{s | state: :stopped, waiters: [], ip: nil, boot_started_at: nil}}
  end

  def handle_info(:idle_timeout, %{active_connections: 0} = s) do
    Logger.info("[ServiceManager] Idle timeout for #{s.service.name}, stopping container")
    DrawbridgeCore.Telemetry.emit_idle_timeout(s.service.name)
    name = s.service.name
    bridge = swift_bridge()
    Task.start(fn -> bridge.call_agent({:stop, name}) end)
    {:noreply, %{s | state: :stopped, ip: nil, idle_timer: nil, started_at: nil}}
  end

  def handle_info(:idle_timeout, s) do
    # Connections still active, ignore
    {:noreply, %{s | idle_timer: nil}}
  end

  def handle_info(_msg, s), do: {:noreply, s}

  # -- Private --

  defp swift_bridge,
    do: Application.get_env(:drawbridge_core, :swift_bridge, DrawbridgeCore.SwiftBridge)

  defp via(name), do: {:via, Registry, {@registry, {:name, name}}}

  defp lookup(name) do
    case Registry.lookup(@registry, {:name, name}) do
      [{pid, _}] -> {:ok, pid}
      [] -> :error
    end
  end

  defp start_container_async(service) do
    self_pid = self()

    Task.start(fn ->
      result =
        swift_bridge().call_agent(
          {:start, service.name, service.image, service.ports, service.env},
          (service.boot_timeout + 5) * 1_000
        )

      case result do
        {:ok, %{ip: ip, ports: ports}} ->
          send(self_pid, {:container_ready, service.name, ip, ports})

        {:error, reason} ->
          send(self_pid, {:container_error, service.name, reason})

        other ->
          send(self_pid, {:container_error, service.name, {:unexpected, other}})
      end
    end)
  end

  defp reset_idle_timer(%{service: service} = s) do
    s = cancel_idle_timer(s)
    timeout_ms = service.idle_timeout * 1_000
    timer = Process.send_after(self(), :idle_timeout, timeout_ms)
    %{s | idle_timer: timer}
  end

  defp boot_duration_ms(%{boot_started_at: nil}), do: 0
  defp boot_duration_ms(%{boot_started_at: t}), do: System.monotonic_time(:millisecond) - t

  defp cancel_idle_timer(%{idle_timer: nil} = s), do: s

  defp cancel_idle_timer(%{idle_timer: timer} = s) do
    Process.cancel_timer(timer)
    %{s | idle_timer: nil}
  end
end
