defmodule DrawbridgeCore.SwiftBridge do
  @moduledoc """
  Manages the Swift container agent process and monitors its Erlang node.

  The Swift process joins the Erlang cluster via swift-erlang-actor-system.
  This module launches the process, monitors the node, and handles reconnection.
  """
  use GenServer
  require Logger

  @swift_node_prefix "drawbridge_agent"
  @reconnect_interval 5_000

  defstruct [:port, :node_name, :cookie, :connected, :swift_binary_path]

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Send a command to the Swift container agent."
  def call_agent(command, timeout \\ 30_000) do
    GenServer.call(__MODULE__, {:call_agent, command}, timeout)
  end

  @doc "Check if the Swift node is connected."
  def connected? do
    GenServer.call(__MODULE__, :connected?)
  end

  @impl true
  def init(opts) do
    cookie = opts[:cookie] || Node.get_cookie()
    swift_binary = opts[:swift_binary] || find_swift_binary()
    node_name = :"#{@swift_node_prefix}@#{hostname()}"

    state = %__MODULE__{
      cookie: cookie,
      node_name: node_name,
      connected: false,
      swift_binary_path: swift_binary
    }

    {:ok, state, {:continue, :start_swift}}
  end

  @impl true
  def handle_continue(:start_swift, state) do
    state = launch_swift_process(state)
    {:noreply, state}
  end

  @impl true
  def handle_call(:connected?, _from, state) do
    {:reply, state.connected, state}
  end

  def handle_call({:call_agent, _command}, _from, %{connected: false} = state) do
    {:reply, {:error, :not_connected}, state}
  end

  def handle_call({:call_agent, command}, from, state) do
    # Forward to the Swift distributed actor via GenServer.call
    task =
      Task.async(fn ->
        try do
          GenServer.call({:container_manager, state.node_name}, command, 30_000)
        catch
          :exit, reason -> {:error, {:swift_call_failed, reason}}
        end
      end)

    # Reply asynchronously when the task completes
    spawn(fn ->
      result = Task.await(task, 35_000)
      GenServer.reply(from, result)
    end)

    {:noreply, state}
  end

  @impl true
  def handle_info({:nodedown, node}, %{node_name: node} = state) do
    Logger.warning("[SwiftBridge] Swift node #{node} went down, reconnecting in #{@reconnect_interval}ms")
    Process.send_after(self(), :reconnect, @reconnect_interval)
    {:noreply, %{state | connected: false, port: nil}}
  end

  def handle_info(:reconnect, state) do
    state = launch_swift_process(state)
    {:noreply, state}
  end

  def handle_info({port, {:data, data}}, %{port: port} = state) when is_port(port) do
    Logger.debug("[SwiftBridge] Swift stdout: #{String.trim(data)}")
    {:noreply, state}
  end

  def handle_info({port, {:exit_status, status}}, %{port: port} = state) when is_port(port) do
    Logger.error("[SwiftBridge] Swift process exited with status #{status}")
    Process.send_after(self(), :reconnect, @reconnect_interval)
    {:noreply, %{state | connected: false, port: nil}}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # -- Private --

  defp launch_swift_process(state) do
    case state.swift_binary_path do
      nil ->
        Logger.warning("[SwiftBridge] Swift binary not found, running in stub mode")
        %{state | connected: false}

      binary_path ->
        args = [
          "--node-name", to_string(state.node_name),
          "--cookie", to_string(state.cookie),
          "--epmd-port", "4369"
        ]

        port =
          Port.open({:spawn_executable, binary_path}, [
            :binary,
            :exit_status,
            :use_stdio,
            :stderr_to_stdout,
            args: args
          ])

        Node.monitor(state.node_name, true)

        # Give the Swift process time to connect
        Process.send_after(self(), :check_connection, 5_000)

        %{state | port: port}
    end
  end

  defp find_swift_binary do
    paths = [
      Path.expand("../../swift/.build/release/DrawbridgeAgent"),
      Path.expand("../../swift/.build/debug/DrawbridgeAgent"),
      System.find_executable("drawbridge-agent")
    ]

    Enum.find(paths, &(&1 && File.exists?(&1)))
  end

  defp hostname do
    {:ok, name} = :inet.gethostname()
    to_string(name)
  end
end
