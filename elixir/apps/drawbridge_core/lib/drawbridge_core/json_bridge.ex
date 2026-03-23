defmodule DrawbridgeCore.JsonBridge do
  @moduledoc """
  GenServer that talks to the Swift DrawbridgeAgent via newline-delimited JSON
  over an Erlang Port (stdin/stdout).

  Each request gets a unique `id`; responses are correlated back to the caller
  via that id so multiple requests can be in-flight concurrently.
  """
  use GenServer
  require Logger

  @behaviour DrawbridgeCore.SwiftBridge

  @reconnect_interval 2_000

  defstruct [
    :port,
    :swift_binary_path,
    :swift_args,
    ready: false,
    next_id: 1,
    pending: %{},
    line_buffer: "",
    progress_subscribers: MapSet.new()
  ]

  # -- Public API --

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl DrawbridgeCore.SwiftBridge
  def call_agent(command, timeout \\ 30_000) do
    GenServer.call(__MODULE__, {:call_agent, command, timeout}, timeout)
  end

  @doc """
  Subscribe the calling process to pull progress events.
  The subscriber receives `{:pull_progress, data}` messages where
  `data` is the decoded progress map from the Swift agent.
  """
  def subscribe_progress do
    GenServer.call(__MODULE__, :subscribe_progress)
  end

  @doc "Unsubscribe from pull progress events."
  def unsubscribe_progress do
    GenServer.call(__MODULE__, :unsubscribe_progress)
  end

  # -- GenServer callbacks --

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)

    binary = opts[:swift_binary] || find_swift_binary()
    args = opts[:swift_args] || []

    state = %__MODULE__{
      swift_binary_path: binary,
      swift_args: args
    }

    {:ok, state, {:continue, :start_port}}
  end

  @impl true
  def handle_continue(:start_port, state) do
    {:noreply, open_port(state)}
  end

  @impl true
  def handle_call(:subscribe_progress, {pid, _}, state) do
    Process.monitor(pid)
    {:reply, :ok, %{state | progress_subscribers: MapSet.put(state.progress_subscribers, pid)}}
  end

  def handle_call(:unsubscribe_progress, {pid, _}, state) do
    {:reply, :ok, %{state | progress_subscribers: MapSet.delete(state.progress_subscribers, pid)}}
  end

  def handle_call({:call_agent, _command, _timeout}, _from, %{port: nil} = state) do
    {:reply, {:error, :not_connected}, state}
  end

  def handle_call({:call_agent, _command, _timeout}, _from, %{ready: false} = state) do
    {:reply, {:error, :not_ready}, state}
  end

  def handle_call({:call_agent, command, timeout}, from, state) do
    id = state.next_id
    id_str = Integer.to_string(id)

    json = encode_command(id_str, command)
    timer = Process.send_after(self(), {:timeout, id_str}, timeout)

    pending = Map.put(state.pending, id_str, {from, timer})
    state = %{state | next_id: id + 1, pending: pending}

    Port.command(state.port, [json, "\n"])
    {:noreply, state}
  end

  @impl true
  def handle_info({port, {:data, {:eol, line}}}, %{port: port} = state) when is_port(port) do
    full_line = state.line_buffer <> line
    state = %{state | line_buffer: ""}
    {:noreply, process_line(full_line, state)}
  end

  def handle_info({port, {:data, {:noeol, chunk}}}, %{port: port} = state) when is_port(port) do
    {:noreply, %{state | line_buffer: state.line_buffer <> chunk}}
  end

  def handle_info({port, {:exit_status, status}}, %{port: port} = state) when is_port(port) do
    Logger.error("[JsonBridge] Swift process exited with status #{status}")
    state = fail_all_pending(state, {:error, :port_crashed})
    Process.send_after(self(), :reconnect, @reconnect_interval)
    {:noreply, %{state | port: nil, ready: false, line_buffer: ""}}
  end

  def handle_info({:EXIT, port, reason}, %{port: port} = state) when is_port(port) do
    Logger.error("[JsonBridge] Port died with reason: #{inspect(reason)}")
    state = fail_all_pending(state, {:error, :port_crashed})
    Process.send_after(self(), :reconnect, @reconnect_interval)
    {:noreply, %{state | port: nil, ready: false, line_buffer: ""}}
  end

  def handle_info(:reconnect, state) do
    Logger.info("[JsonBridge] Attempting reconnect...")
    {:noreply, open_port(state)}
  end

  def handle_info({:timeout, id}, state) do
    case Map.pop(state.pending, id) do
      {{from, _timer}, pending} ->
        GenServer.reply(from, {:error, :timeout})
        {:noreply, %{state | pending: pending}}

      {nil, _} ->
        {:noreply, state}
    end
  end

  def handle_info({:DOWN, _ref, :process, pid, _reason}, state) do
    {:noreply, %{state | progress_subscribers: MapSet.delete(state.progress_subscribers, pid)}}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    fail_all_pending(state, {:error, :shutting_down})

    if state.port do
      try do
        Port.close(state.port)
      rescue
        _ -> :ok
      end
    end

    :ok
  end

  # -- Private --

  defp open_port(state) do
    case state.swift_binary_path do
      nil ->
        Logger.warning("[JsonBridge] Swift binary not found — bridge disabled")
        %{state | port: nil, ready: false}

      binary_path ->
        port =
          Port.open({:spawn_executable, binary_path}, [
            :binary,
            {:line, 65_536},
            :exit_status,
            :use_stdio,
            {:args, state.swift_args}
          ])

        Logger.info("[JsonBridge] Launched Swift agent: #{binary_path}")
        %{state | port: port, ready: false, line_buffer: ""}
    end
  end

  defp process_line(line, state) do
    line = String.trim(line)

    cond do
      line == "" ->
        state

      String.starts_with?(line, "[CommandServer] Ready") ->
        Logger.info("[JsonBridge] Swift agent ready")
        %{state | ready: true}

      true ->
        handle_json_response(line, state)
    end
  end

  defp handle_json_response(line, state) do
    case Jason.decode(line) do
      {:ok, %{"progress" => true, "data" => data}} ->
        broadcast_progress(state, data)
        state

      {:ok, %{"id" => id} = resp} ->
        case Map.pop(state.pending, to_string(id)) do
          {{from, timer}, pending} ->
            Process.cancel_timer(timer)
            result = decode_response(resp)
            GenServer.reply(from, result)
            %{state | pending: pending}

          {nil, _} ->
            Logger.warning("[JsonBridge] Response for unknown id=#{id}: #{line}")
            state
        end

      {:ok, %{"ready" => true}} ->
        Logger.info("[JsonBridge] Swift agent ready (JSON)")
        %{state | ready: true}

      {:ok, resp} ->
        Logger.warning("[JsonBridge] Response without id: #{inspect(resp)}")
        state

      {:error, _} ->
        Logger.debug("[JsonBridge] Non-JSON from Swift: #{line}")
        state
    end
  end

  defp broadcast_progress(state, data) do
    for pid <- state.progress_subscribers do
      send(pid, {:pull_progress, data})
    end
  end

  defp decode_response(%{"ok" => true, "data" => data}), do: {:ok, data}
  defp decode_response(%{"ok" => true}), do: {:ok, nil}

  defp decode_response(%{"ok" => false, "error" => msg, "code" => code}),
    do: {:error, {code, msg}}

  defp decode_response(%{"ok" => false, "error" => msg}), do: {:error, msg}
  defp decode_response(other), do: {:error, {:unexpected_response, other}}

  defp encode_command(id, {:start, name, image, ports, env}) do
    Jason.encode!(%{
      id: id,
      cmd: "start",
      name: name,
      image: image,
      ports: Enum.map(ports, fn {h, c} -> %{host: h, container: c} end),
      env: env
    })
  end

  defp encode_command(id, {:stop, name}),
    do: Jason.encode!(%{id: id, cmd: "stop", name: name})

  defp encode_command(id, {:pull, image}),
    do: Jason.encode!(%{id: id, cmd: "pull", image: image})

  defp encode_command(id, {:status, name}),
    do: Jason.encode!(%{id: id, cmd: "status", name: name})

  defp encode_command(id, :list),
    do: Jason.encode!(%{id: id, cmd: "list"})

  defp encode_command(id, :health),
    do: Jason.encode!(%{id: id, cmd: "health"})

  defp encode_command(id, {:image_inspect, image}),
    do: Jason.encode!(%{id: id, cmd: "image_inspect", image: image})

  defp encode_command(id, {:raw_cmd, cmd}),
    do: Jason.encode!(%{id: id, cmd: cmd})

  defp fail_all_pending(state, error) do
    for {_id, {from, timer}} <- state.pending do
      Process.cancel_timer(timer)
      GenServer.reply(from, error)
    end

    %{state | pending: %{}}
  end

  defp find_swift_binary do
    configured = Application.get_env(:drawbridge_core, :swift_binary_path)

    paths =
      [
        configured,
        app_dir_binary(),
        System.find_executable("drawbridge-agent")
      ]
      |> Enum.reject(&is_nil/1)

    Enum.find(paths, &File.exists?/1)
  end

  defp app_dir_binary do
    Application.app_dir(:drawbridge_core, "priv/swift/DrawbridgeAgent")
  rescue
    # app_dir raises if the app isn't loaded yet (e.g. during dev/test)
    _ -> nil
  end
end
