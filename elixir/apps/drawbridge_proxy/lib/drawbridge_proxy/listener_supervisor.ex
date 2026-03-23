defmodule DrawbridgeProxy.ListenerSupervisor do
  @moduledoc """
  Supervisor for Ranch TCP listeners.

  Starts a TLS-sniffing listener on the configured port (default 443) using
  SniHandler, plus any port-based listeners configured at startup. Exposes
  `start_port_listener/2` and `stop_port_listener/1` for runtime management
  of non-TLS service listeners (called by ServiceManager when a new service
  with a dedicated port is registered).

  We use ranch_tcp (NOT ranch_ssl) because we need to read the raw ClientHello
  bytes to extract SNI before any TLS handshake occurs.
  """

  use Supervisor

  require Logger

  def start_link(opts \\ []) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl Supervisor
  def init(_opts) do
    tls_port = Application.get_env(:drawbridge_proxy, :tls_port, 443)

    Logger.info("[ListenerSupervisor] starting SNI listener on port #{tls_port}")

    children = [
      :ranch.child_spec(
        :sni_listener,
        :ranch_tcp,
        %{socket_opts: [port: tls_port]},
        DrawbridgeProxy.SniHandler,
        []
      )
    ]

    # Also start any port-based listeners from config
    port_listeners =
      Application.get_env(:drawbridge_proxy, :port_listeners, [])
      |> Enum.map(fn {service_name, port} ->
        Logger.info("[ListenerSupervisor] starting port listener #{service_name} on port #{port}")

        :ranch.child_spec(
          {:port_listener, service_name},
          :ranch_tcp,
          %{socket_opts: [port: port]},
          DrawbridgeProxy.PortHandler,
          service_name: service_name
        )
      end)

    Supervisor.init(children ++ port_listeners, strategy: :one_for_one)
  end

  @doc """
  Dynamically start a port-based listener for a service.
  Called at runtime when ServiceManager registers a service with a dedicated port.
  """
  @spec start_port_listener(atom() | String.t(), non_neg_integer()) ::
          {:ok, pid()} | {:error, term()}
  def start_port_listener(service_name, port) do
    child_spec =
      :ranch.child_spec(
        {:port_listener, service_name},
        :ranch_tcp,
        %{socket_opts: [port: port]},
        DrawbridgeProxy.PortHandler,
        service_name: service_name
      )

    case Supervisor.start_child(__MODULE__, child_spec) do
      {:ok, _pid} = ok ->
        Logger.info("[ListenerSupervisor] started port listener #{service_name} on #{port}")
        ok

      {:error, {:already_started, pid}} ->
        {:ok, pid}

      {:error, _} = err ->
        err
    end
  end

  @doc """
  Stop and remove a port-based listener for a service.
  """
  @spec stop_port_listener(atom() | String.t()) :: :ok | {:error, term()}
  def stop_port_listener(service_name) do
    id = {:port_listener, service_name}

    case Supervisor.terminate_child(__MODULE__, id) do
      :ok ->
        Supervisor.delete_child(__MODULE__, id)
        Logger.info("[ListenerSupervisor] stopped port listener #{service_name}")
        :ok

      {:error, :not_found} ->
        :ok

      err ->
        err
    end
  end
end
