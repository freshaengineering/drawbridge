defmodule DrawbridgeCore.Application do
  use Application

  @impl true
  def start(_type, _args) do
    DrawbridgeCore.Telemetry.setup()

    bridge_mod = Application.get_env(:drawbridge_core, :swift_bridge, DrawbridgeCore.JsonBridge)

    bridge_children =
      if bridge_mod == DrawbridgeCore.StubSwiftBridge do
        []
      else
        [{bridge_mod, []}]
      end

    dns_children =
      if bridge_mod == DrawbridgeCore.StubSwiftBridge do
        []
      else
        [{DrawbridgeCore.DnsServer, []}]
      end

    children =
      [
        {Registry, keys: :unique, name: DrawbridgeCore.ServiceRegistry},
        {DynamicSupervisor, name: DrawbridgeCore.ServiceSupervisor, strategy: :one_for_one}
      ] ++ bridge_children ++ dns_children

    opts = [strategy: :one_for_one, name: DrawbridgeCore.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
