defmodule DrawbridgeCore.Application do
  use Application

  @impl true
  def start(_type, _args) do
    children = [
      {Registry, keys: :unique, name: DrawbridgeCore.ServiceRegistry},
      {DynamicSupervisor, name: DrawbridgeCore.ServiceSupervisor, strategy: :one_for_one},
      DrawbridgeCore.SwiftBridge
    ]

    opts = [strategy: :one_for_one, name: DrawbridgeCore.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
