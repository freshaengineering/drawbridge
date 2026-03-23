defmodule DrawbridgeCore.ServiceRegistry do
  @moduledoc """
  Registry wrapper for looking up services by name, hostname, or host port.

  Uses the Registry started in Application under DrawbridgeCore.ServiceRegistry.
  Each service registers three keys: {:name, name}, {:hostname, hostname}, {:port, port}
  """

  @registry DrawbridgeCore.ServiceRegistry

  @doc "Register a service with lookup keys for hostname, ports, and optionally database."
  def register_service(name, hostname, ports, opts \\ []) do
    database = Keyword.get(opts, :database)

    # Register by name
    Registry.register(@registry, {:name, name}, %{hostname: hostname, ports: ports})

    # Register by hostname
    if hostname do
      Registry.register(@registry, {:hostname, hostname}, %{name: name})
    end

    # Database-routed services share a port — skip per-port registration
    unless database do
      Enum.each(ports, fn {host_port, _container_port} ->
        Registry.register(@registry, {:port, host_port}, %{name: name})
      end)
    end

    if database do
      Registry.register(@registry, {:database, database}, %{name: name})
    end

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

  @doc "Look up a service by database name. Returns `{:ok, {pid, service_name}}` or `:error`."
  def lookup_by_database(database) do
    case Registry.lookup(@registry, {:database, database}) do
      [{pid, %{name: name}}] -> {:ok, {pid, name}}
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
