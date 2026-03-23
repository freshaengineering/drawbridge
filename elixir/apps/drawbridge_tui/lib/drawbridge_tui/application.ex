defmodule DrawbridgeTui.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = []
    Supervisor.start_link(children, strategy: :one_for_one, name: DrawbridgeTui.Supervisor)
  end

  @doc "Start the dashboard processes under the existing supervisor."
  def start_dashboard(domain) do
    {:ok, _} =
      Supervisor.start_child(DrawbridgeTui.Supervisor, {DrawbridgeTui.Dashboard, domain: domain})

    {:ok, _} =
      Supervisor.start_child(DrawbridgeTui.Supervisor, {DrawbridgeTui.ServiceSubscriber, []})

    {:ok, _} =
      Supervisor.start_child(DrawbridgeTui.Supervisor, {DrawbridgeTui.InputReader, []})

    {:ok, :started}
  end
end
