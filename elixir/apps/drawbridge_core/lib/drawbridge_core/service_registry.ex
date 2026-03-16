defmodule DrawbridgeCore.ServiceRegistry do
  @moduledoc """
  Registry wrapper for looking up services by name, hostname, or host port.

  Uses the Registry started in Application under DrawbridgeCore.ServiceRegistry.
  Each service registers three keys: {:name, name}, {:hostname, hostname}, {:port, port}
  """

  @registry DrawbridgeCore.ServiceRegistry

  @doc "Register a service with lookup keys for hostname and ports."
  def register_service(name, hostname, ports) do
    # Register by name
    Registry.register(@registry, {:name, name}, %{hostname: hostname, ports: ports})

    # Register by hostname
    if hostname do
      Registry.register(@registry, {:hostname, hostname}, %{name: name})
    end

    # Register by each host port
    Enum.each(ports, fn {host_port, _container_port} ->
      Registry.register(@registry, {:port, host_port}, %{name: name})
    end)

    :ok
  end

  @doc "Look up a service PID by hostname."
  def lookup_by_hostname(hostname) do
    case Registry.lookup(@registry, {:hostname, hostname}) do
      [{pid, _meta}] -> {:ok, pid}
      [] -> :error
    end
  end

  @doc "Look up a service PID by host port."
  def lookup_by_port(port) do
    case Registry.lookup(@registry, {:port, port}) do
      [{pid, _meta}] -> {:ok, pid}
      [] -> :error
    end
  end

  @doc "List all registered services with their PIDs."
  def list_services do
    Registry.select(@registry, [{{:_, :"$1", :"$2"}, [], [{{:"$1", :"$2"}}]}])
    |> Enum.filter(fn {_pid, meta} -> is_map(meta) && Map.has_key?(meta, :hostname) end)
    |> Enum.map(fn {pid, meta} -> {meta, pid} end)
  end
end
