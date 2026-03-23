defmodule DrawbridgeTui.ServiceSubscriber do
  @moduledoc """
  GenServer that polls ServiceManager every second and pushes
  state updates to the Dashboard process.
  """

  use GenServer

  @poll_interval 1_000

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, [], name: __MODULE__)
  end

  @impl true
  def init(_) do
    schedule_poll()
    {:ok, %{}}
  end

  @impl true
  def handle_info(:poll, state) do
    services = fetch_services()
    DrawbridgeTui.Dashboard.update(services)
    schedule_poll()
    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  defp schedule_poll do
    Process.send_after(self(), :poll, @poll_interval)
  end

  defp fetch_services do
    DrawbridgeCore.ServiceManager.list_services()
    |> Enum.sort_by(& &1.name)
  end
end
