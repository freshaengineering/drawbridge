defmodule DrawbridgeTui do
  @moduledoc """
  Terminal UI for Drawbridge — live dashboard showing service states,
  connections, and uptime via Owl LiveScreen.
  """

  @doc """
  Start the TUI dashboard. Blocks the caller until the dashboard exits.

  Launches the ServiceSubscriber (polls ServiceManager) and Dashboard
  (renders to terminal via Owl).
  """
  def start(domain \\ "dev.local") do
    {:ok, _} = DrawbridgeTui.Application.start_dashboard(domain)
    block_until_quit()
  end

  defp block_until_quit do
    # Block until Ctrl+C / q keypress triggers shutdown
    Process.sleep(:infinity)
  end
end
