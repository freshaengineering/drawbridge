defmodule DrawbridgeCore.Application do
  use Application

  @impl true
  def start(_type, _args) do
    bridge_mod = Application.get_env(:drawbridge_core, :swift_bridge, DrawbridgeCore.JsonBridge)

    bridge_children =
      if bridge_mod == DrawbridgeCore.StubSwiftBridge do
        []
      else
        [{bridge_mod, []}]
      end

    children =
      [
        {Registry, keys: :unique, name: DrawbridgeCore.ServiceRegistry},
        {DynamicSupervisor, name: DrawbridgeCore.ServiceSupervisor, strategy: :one_for_one}
      ] ++ bridge_children

    opts = [strategy: :one_for_one, name: DrawbridgeCore.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
