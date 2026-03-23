defmodule DrawbridgeCore.SwiftBridge do
  @moduledoc """
  Behaviour for communicating with the Swift container agent.

  The implementation is selected via config:

      config :drawbridge_core, swift_bridge: DrawbridgeCore.JsonBridge

  In tests, use `DrawbridgeCore.StubSwiftBridge`.
  """

  @callback call_agent(command :: term(), timeout :: non_neg_integer()) ::
              {:ok, map() | term()} | {:error, term()}

  @doc "Dispatch to the configured SwiftBridge implementation."
  def call_agent(command, timeout \\ 30_000) do
    impl = Application.get_env(:drawbridge_core, :swift_bridge, DrawbridgeCore.JsonBridge)
    impl.call_agent(command, timeout)
  end
end
