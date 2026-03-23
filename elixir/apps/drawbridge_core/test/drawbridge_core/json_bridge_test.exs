defmodule DrawbridgeCore.JsonBridgeTest do
  use ExUnit.Case, async: true

  alias DrawbridgeCore.JsonBridge

  @moduletag :json_bridge

  defp mock_script_path do
    Path.join([__DIR__, "..", "support", "mock_swift_agent.exs"])
  end

  defp elixir_executable do
    System.find_executable("elixir")
  end

  defp start_bridge(name \\ nil) do
    name = name || :"json_bridge_#{:erlang.unique_integer([:positive])}"

    {:ok, pid} =
      GenServer.start_link(
        JsonBridge,
        [
          swift_binary: elixir_executable(),
          swift_args: [mock_script_path()]
        ],
        name: name
      )

    # Wait for ready signal
    Process.sleep(500)
    {pid, name}
  end

  test "health check round-trips" do
    {pid, name} = start_bridge()

    result = GenServer.call(name, {:call_agent, :health}, 5_000)
    assert {:ok, "pong"} = result

    GenServer.stop(pid)
  end

  test "request/response correlation with concurrent calls" do
    {pid, name} = start_bridge()

    tasks =
      for i <- 1..5 do
        Task.async(fn ->
          GenServer.call(name, {:call_agent, {:status, "svc-#{i}"}}, 5_000)
        end)
      end

    results = Task.await_many(tasks, 10_000)
    assert length(results) == 5
    assert Enum.all?(results, &match?({:ok, _}, &1))

    GenServer.stop(pid)
  end

  test "list command" do
    {pid, name} = start_bridge()

    result = GenServer.call(name, {:call_agent, :list}, 5_000)
    assert {:ok, []} = result

    GenServer.stop(pid)
  end

  test "error responses include code" do
    {pid, name} = start_bridge()

    result = GenServer.call(name, {:call_agent, {:raw_cmd, "bogus_cmd"}}, 5_000)
    assert {:error, {"unknown_command", "unknown cmd 'bogus_cmd'"}} = result

    GenServer.stop(pid)
  end

  test "not_connected when port is nil" do
    name = :"json_bridge_nil_#{:erlang.unique_integer([:positive])}"

    {:ok, pid} =
      GenServer.start_link(JsonBridge, [swift_binary: nil], name: name)

    result = GenServer.call(name, {:call_agent, :health}, 1_000)
    assert {:error, :not_connected} = result

    GenServer.stop(pid)
  end

  test "port crash replies error to all pending and reconnects" do
    {pid, name} = start_bridge()

    # Send a "crash" command that makes the mock script exit
    task =
      Task.async(fn ->
        GenServer.call(name, {:call_agent, {:pull, "__crash__"}}, 5_000)
      end)

    result = Task.await(task, 5_000)
    assert {:error, _} = result

    # Give it time to reconnect
    Process.sleep(3_000)

    # Should be working again after reconnect
    result = GenServer.call(name, {:call_agent, :health}, 5_000)
    assert {:ok, "pong"} = result

    GenServer.stop(pid)
  end

  test "behaviour dispatch via SwiftBridge module" do
    assert Application.get_env(:drawbridge_core, :swift_bridge) ==
             DrawbridgeCore.StubSwiftBridge
  end
end
