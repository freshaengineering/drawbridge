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
    children = [
      {DrawbridgeTui.Dashboard, domain: domain},
      {DrawbridgeTui.ServiceSubscriber, []}
    ]

    Enum.each(children, fn spec ->
      Supervisor.start_child(DrawbridgeTui.Supervisor, spec)
    end)

    {:ok, :started}
  end
end
