defmodule DrawbridgeTui do
  @moduledoc """
  Terminal UI for Drawbridge — live dashboard showing service states,
  connections, and uptime via Owl LiveScreen.
  """

  @doc """
  Start the TUI dashboard. Blocks the caller until the dashboard exits.

  Launches the ServiceSubscriber (polls ServiceManager), Dashboard
  (renders to terminal via Owl), and InputReader (handles keypresses).
  """
  def start(domain \\ "dev.local") do
    {:ok, _} = DrawbridgeTui.Application.start_dashboard(domain)
    block_until_quit()
  end

  defp block_until_quit do
    # InputReader handles 'q' → System.halt(0).
    # We still need to block the caller so the supervision tree stays alive.
    Process.sleep(:infinity)
  end
end
