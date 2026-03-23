defmodule DrawbridgeCore.StubSwiftBridge do
  @moduledoc """
  No-op SwiftBridge stub for tests.

  Two modes controlled via application env `:drawbridge_core, :stub_swift_bridge_mode`:

    - `nil` (default): blocks forever via `Process.sleep(:infinity)`, letting tests
      inject `:container_ready` / `:container_error` messages manually.
    - `:auto_ready`: immediately returns `{:ok, %{ip: ip, ports: ports}}` so the
      ServiceManager's async task sends `:container_ready` back automatically.
      The IP defaults to "127.0.0.1" but can be overridden via
      `:drawbridge_core, :stub_swift_bridge_ip`.

  Used by E2E integration tests to simulate instant container boot without
  blocking the ServiceManager.
  """

  @behaviour DrawbridgeCore.SwiftBridge

  @impl true
  def call_agent(command, timeout \\ 30_000)

  def call_agent({:start, _name, _image, ports, _env}, _timeout) do
    case Application.get_env(:drawbridge_core, :stub_swift_bridge_mode) do
      :auto_ready ->
        ip = Application.get_env(:drawbridge_core, :stub_swift_bridge_ip, "127.0.0.1")
        {:ok, %{ip: ip, ports: ports}}

      _ ->
        Process.sleep(:infinity)
    end
  end

  def call_agent({:stop, _name}, _timeout) do
    :ok
  end

  def call_agent(_command, _timeout) do
    Process.sleep(:infinity)
  end
end
