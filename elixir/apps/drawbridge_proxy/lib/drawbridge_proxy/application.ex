defmodule DrawbridgeProxy.Application do
  use Application
  require Logger

  @impl true
  def start(_type, _args) do
    children = [
      DrawbridgeProxy.ProtocolRegistry,
      DrawbridgeProxy.ListenerSupervisor
    ]

    opts = [strategy: :one_for_one, name: DrawbridgeProxy.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
