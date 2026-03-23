defmodule Mix.Tasks.Drawbridge.Status do
  @moduledoc "Show status of all Drawbridge services."

  if Code.ensure_loaded?(Mix.Task) do
    use Mix.Task
  end

  def run(_args) do
    DrawbridgeCli.ensure_started()

    services = DrawbridgeCore.ServiceManager.list_services()

    if services == [] do
      IO.puts("No services configured. Is Drawbridge running?")
    else
      header =
        String.pad_trailing("Service", 18) <>
          String.pad_trailing("State", 12) <>
          String.pad_trailing("Hostname", 28) <>
          String.pad_trailing("Ports", 16) <>
          String.pad_trailing("Conns", 8) <>
          "Uptime"

      IO.puts("")
      IO.puts("  #{header}")
      IO.puts("  #{String.duplicate("─", 90)}")

      Enum.each(services, fn svc ->
        state_str = format_state(svc.state)
        ports_str = Enum.map_join(svc.ports, ", ", fn {h, c} -> "#{h}:#{c}" end)
        uptime_str = format_uptime(svc.uptime)

        row =
          String.pad_trailing(svc.name, 18) <>
            String.pad_trailing(state_str, 12) <>
            String.pad_trailing(svc.hostname || "", 28) <>
            String.pad_trailing(ports_str, 16) <>
            String.pad_trailing(to_string(svc.connections), 8) <>
            uptime_str

        IO.puts("  #{row}")
      end)

      IO.puts("")
    end
  end

  defp format_state(:running), do: "running"
  defp format_state(:booting), do: "booting"
  defp format_state(:stopped), do: "sleeping"
  defp format_state(:not_pulled), do: "not pulled"
  defp format_state(other), do: to_string(other)

  defp format_uptime(nil), do: "-"
  defp format_uptime(0), do: "-"

  defp format_uptime(seconds) when is_integer(seconds) do
    cond do
      seconds < 60 -> "#{seconds}s"
      seconds < 3600 -> "#{div(seconds, 60)}m #{rem(seconds, 60)}s"
      true -> "#{div(seconds, 3600)}h #{div(rem(seconds, 3600), 60)}m"
    end
  end
end
