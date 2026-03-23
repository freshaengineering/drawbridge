defmodule DrawbridgeCore.JsonBridgeProgressTest do
  use ExUnit.Case, async: true

  alias DrawbridgeCore.JsonBridge

  @moduletag :json_bridge

  defp mock_script_path do
    Path.join([__DIR__, "..", "support", "mock_swift_agent.exs"])
  end

  defp elixir_executable do
    System.find_executable("elixir")
  end

  defp start_bridge do
    name = :"json_bridge_progress_#{:erlang.unique_integer([:positive])}"

    {:ok, pid} =
      GenServer.start_link(
        JsonBridge,
        [
          swift_binary: elixir_executable(),
          swift_args: [mock_script_path()]
        ],
        name: name
      )

    # Wait for the bridge to become ready (mock agent sends "[CommandServer] Ready" on boot)
    wait_until_ready(name, 20, 100)
    {pid, name}
  end

  defp wait_until_ready(_name, 0, _interval), do: :ok

  defp wait_until_ready(name, retries, interval) do
    case GenServer.call(name, {:call_agent, :health, 2_000}, 3_000) do
      {:ok, _} ->
        :ok

      {:error, :not_ready} ->
        Process.sleep(interval)
        wait_until_ready(name, retries - 1, interval)

      {:error, _} ->
        :ok
    end
  end

  test "progress events are broadcast to subscribers" do
    {pid, name} = start_bridge()

    # Subscribe this test process to progress
    :ok = GenServer.call(name, :subscribe_progress)

    # Pull with __progress__ prefix triggers synthetic progress in mock agent
    task =
      Task.async(fn ->
        GenServer.call(name, {:call_agent, {:pull, "__progress__test"}, 10_000}, 10_000)
      end)

    # Collect progress messages
    progress_msgs = collect_progress([], 5_000)

    # The pull should complete successfully
    result = Task.await(task, 10_000)
    assert {:ok, %{"image" => "__progress__test"}} = result

    # We should have received progress events
    assert length(progress_msgs) >= 1

    # Each progress message should have image and percent
    Enum.each(progress_msgs, fn data ->
      assert is_map(data)
      assert Map.has_key?(data, "image")
      assert Map.has_key?(data, "percent")
    end)

    GenServer.stop(pid)
  end

  test "unsubscribed process does not receive progress" do
    {pid, name} = start_bridge()

    # Subscribe then unsubscribe
    :ok = GenServer.call(name, :subscribe_progress)
    :ok = GenServer.call(name, :unsubscribe_progress)

    task =
      Task.async(fn ->
        GenServer.call(name, {:call_agent, {:pull, "__progress__unsub"}, 10_000}, 10_000)
      end)

    # Should not receive any progress
    refute_receive {:pull_progress, _}, 2_000

    Task.await(task, 10_000)
    GenServer.stop(pid)
  end

  test "pull without __progress__ prefix still works" do
    {pid, name} = start_bridge()

    :ok = GenServer.call(name, :subscribe_progress)

    result = GenServer.call(name, {:call_agent, {:pull, "some-image:latest"}, 10_000}, 10_000)
    assert {:ok, %{"image" => "some-image:latest"}} = result

    GenServer.stop(pid)
  end

  defp collect_progress(acc, timeout) do
    receive do
      {:pull_progress, data} ->
        collect_progress([data | acc], timeout)
    after
      timeout -> Enum.reverse(acc)
    end
  end
end
