defmodule DrawbridgeCore.StubSwiftBridge do
  @moduledoc "No-op SwiftBridge stub for tests — never replies, letting tests inject responses manually."

  @behaviour DrawbridgeCore.SwiftBridge

  @impl true
  def call_agent(_command, _timeout \\ 30_000) do
    # Block forever so the test controls when {:container_ready,...} / {:container_error,...} arrives
    Process.sleep(:infinity)
  end
end
