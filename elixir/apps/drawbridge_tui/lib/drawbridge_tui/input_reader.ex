defmodule DrawbridgeTui.InputReader do
  @moduledoc """
  Reads single keypresses from stdin and dispatches actions to the Dashboard.

  Runs in a tight loop using `:io.get_chars/3` after setting the terminal
  to raw mode (no echo, no canonical buffering).
  """

  use GenServer

  @name __MODULE__

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: @name)
  end

  @impl true
  def init(_opts) do
    set_raw_mode()
    spawn_reader()
    {:ok, %{}}
  end

  @impl true
  def handle_info({:keypress, key}, state) do
    handle_key(key)
    spawn_reader()
    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, _state) do
    restore_terminal()
    :ok
  end

  # -- Private --

  defp spawn_reader do
    pid = self()

    spawn(fn ->
      case :io.get_chars(:stdio, "", 1) do
        :eof -> :ok
        {:error, _} -> :ok
        char when is_binary(char) -> send(pid, {:keypress, char})
        char when is_list(char) -> send(pid, {:keypress, List.to_string(char)})
      end
    end)
  end

  defp handle_key("q") do
    restore_terminal()
    System.halt(0)
  end

  defp handle_key("j"), do: DrawbridgeTui.Dashboard.select_next()
  defp handle_key("k"), do: DrawbridgeTui.Dashboard.select_prev()
  defp handle_key("b"), do: DrawbridgeTui.Dashboard.action(:boot)
  defp handle_key("s"), do: DrawbridgeTui.Dashboard.action(:stop)
  defp handle_key("r"), do: DrawbridgeTui.Dashboard.action(:restart)
  defp handle_key("?"), do: DrawbridgeTui.Dashboard.toggle_help()
  defp handle_key(_), do: :ok

  defp set_raw_mode do
    System.cmd("stty", ["-echo", "-icanon", "min", "1"],
      into: IO.stream(:stdio, :line),
      stderr_to_stdout: true
    )
  rescue
    _ -> :ok
  end

  defp restore_terminal do
    System.cmd("stty", ["echo", "icanon"],
      into: IO.stream(:stdio, :line),
      stderr_to_stdout: true
    )
  rescue
    _ -> :ok
  end
end
