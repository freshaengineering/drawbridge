defmodule DrawbridgeTui.Dashboard do
  @moduledoc """
  Owl LiveScreen-based dashboard rendering.

  Receives service data from ServiceSubscriber and renders a live-updating
  table with color-coded states, selection highlight, and dependency graph.
  """

  use GenServer

  @name __MODULE__
  @flash_duration 2_000

  # -- Public API --

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: @name)
  end

  @doc "Push new service data to the dashboard for rendering."
  def update(services) do
    GenServer.cast(@name, {:update, services})
  end

  @doc "Move selection to next service."
  def select_next, do: GenServer.cast(@name, :select_next)

  @doc "Move selection to previous service."
  def select_prev, do: GenServer.cast(@name, :select_prev)

  @doc "Execute an action on the selected service."
  def action(act) when act in [:boot, :stop, :restart] do
    GenServer.cast(@name, {:action, act})
  end

  @doc "Toggle help overlay."
  def toggle_help, do: GenServer.cast(@name, :toggle_help)

  # -- Callbacks --

  @impl true
  def init(opts) do
    domain = Keyword.get(opts, :domain, "dev.local")

    state = %{
      domain: domain,
      services: [],
      selected_index: 0,
      flash: nil,
      show_help: false
    }

    Owl.LiveScreen.add_block(:dashboard, state: render_all(state))
    {:ok, state}
  end

  @impl true
  def handle_cast({:update, services}, state) do
    state = %{state | services: services}
    # Clamp selection if services list shrunk
    state = clamp_selection(state)
    Owl.LiveScreen.update(:dashboard, render_all(state))
    {:noreply, state}
  end

  def handle_cast(:select_next, state) do
    count = length(state.services)

    state =
      if count > 0 do
        %{state | selected_index: rem(state.selected_index + 1, count)}
      else
        state
      end

    Owl.LiveScreen.update(:dashboard, render_all(state))
    {:noreply, state}
  end

  def handle_cast(:select_prev, state) do
    count = length(state.services)

    state =
      if count > 0 do
        new_idx = state.selected_index - 1
        new_idx = if new_idx < 0, do: count - 1, else: new_idx
        %{state | selected_index: new_idx}
      else
        state
      end

    Owl.LiveScreen.update(:dashboard, render_all(state))
    {:noreply, state}
  end

  def handle_cast({:action, act}, state) do
    case selected_service(state) do
      nil ->
        {:noreply, state}

      svc ->
        execute_action(act, svc.name)
        label = action_label(act)
        state = %{state | flash: "#{label} #{svc.name}..."}
        Owl.LiveScreen.update(:dashboard, render_all(state))
        Process.send_after(self(), :clear_flash, @flash_duration)
        {:noreply, state}
    end
  end

  def handle_cast(:toggle_help, state) do
    state = %{state | show_help: !state.show_help}
    Owl.LiveScreen.update(:dashboard, render_all(state))
    {:noreply, state}
  end

  @impl true
  def handle_info(:clear_flash, state) do
    state = %{state | flash: nil}
    Owl.LiveScreen.update(:dashboard, render_all(state))
    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # -- Rendering --

  defp render_all(state) do
    parts = render(state.services, state.domain, state.selected_index)

    parts =
      if state.services != [] do
        parts ++ [render_deps(state.services)]
      else
        parts
      end

    parts =
      if state.flash do
        parts ++ ["\n", Owl.Data.tag("  #{state.flash}", :yellow)]
      else
        parts
      end

    parts =
      if state.show_help do
        parts ++ ["\n", render_help()]
      else
        parts
      end

    parts
  end

  @doc false
  def render(services, domain, selected_index \\ -1) do
    timestamp = Calendar.strftime(DateTime.utc_now(), "%H:%M:%S UTC")

    header =
      Owl.Data.tag("Drawbridge", :bright)
      |> Owl.Data.to_chardata()

    header_line = [header, " — *.", domain, "  ", Owl.Data.tag(timestamp, :faint)]

    separator = String.duplicate("─", 90)

    col_header =
      [
        "  ",
        pad("Service", 18),
        pad("State", 12),
        pad("Hostname", 28),
        pad("Ports", 16),
        pad("Conns", 8),
        "Uptime"
      ]
      |> Owl.Data.tag(:faint)

    rows =
      services
      |> Enum.with_index()
      |> Enum.map(fn {svc, idx} -> render_row(svc, idx == selected_index) end)

    footer =
      Owl.Data.tag(
        "  q quit │ j/k navigate │ b boot │ s stop │ r restart │ ? help",
        :faint
      )

    [header_line, "\n", separator, "\n", col_header, "\n"]
    |> then(fn parts ->
      if rows == [] do
        parts ++ [Owl.Data.tag("  (no services registered)", :faint), "\n"]
      else
        parts ++ Enum.intersperse(rows, "\n") ++ ["\n"]
      end
    end)
    |> Kernel.++(["─\n", footer])
  end

  defp render_row(svc, selected?) do
    state_tag = state_color(svc.state)

    ports =
      svc.ports
      |> Enum.map_join(", ", fn {h, c} -> "#{h}:#{c}" end)

    marker = if selected?, do: Owl.Data.tag("> ", :bright), else: "  "

    [
      marker,
      pad(to_string(svc.name), 18),
      pad_tagged(state_tag, 12),
      pad(svc.hostname || "-", 28),
      pad(ports, 16),
      pad(to_string(svc.connections), 8),
      format_uptime(svc.uptime)
    ]
  end

  defp render_deps(services) do
    deps =
      services
      |> Enum.filter(fn svc -> Map.get(svc, :depends_on, []) != [] end)
      |> Enum.sort_by(& &1.name)
      |> Enum.map(fn svc ->
        deps_str = svc.depends_on |> Enum.sort() |> Enum.join(", ")
        "  #{svc.name} → #{deps_str}"
      end)

    case deps do
      [] ->
        ""

      lines ->
        [
          "\n",
          Owl.Data.tag("Dependencies:", :faint),
          "\n",
          Owl.Data.tag(Enum.join(lines, "\n"), :faint)
        ]
    end
  end

  defp render_help do
    Owl.Data.tag(
      """
        Keyboard shortcuts:
          q       Quit drawbridge
          j / k   Move selection down / up
          b       Boot selected service
          s       Stop selected service
          r       Restart selected service
          ?       Toggle this help
      """,
      :faint
    )
  end

  defp state_color(:running), do: Owl.Data.tag("running", :green)
  defp state_color(:booting), do: Owl.Data.tag("booting", :yellow)
  defp state_color(:stopped), do: Owl.Data.tag("stopped", :faint)
  defp state_color(:not_pulled), do: Owl.Data.tag("not_pulled", :faint)
  defp state_color(other), do: Owl.Data.tag(to_string(other), :faint)

  @doc false
  def format_uptime(nil), do: Owl.Data.tag("-", :faint)

  def format_uptime(seconds) when is_integer(seconds) and seconds >= 0 do
    cond do
      seconds < 60 ->
        "#{seconds}s"

      seconds < 3600 ->
        m = div(seconds, 60)
        s = rem(seconds, 60)
        "#{m}m #{s}s"

      true ->
        h = div(seconds, 3600)
        m = div(rem(seconds, 3600), 60)
        "#{h}h #{m}m"
    end
  end

  def format_uptime(_), do: "-"

  defp pad(str, width), do: String.pad_trailing(str, width)

  defp pad_tagged(tagged, width) do
    text =
      tagged
      |> Owl.Data.to_chardata()
      |> IO.chardata_to_string()
      |> String.replace(~r/\e\[[0-9;]*m/, "")

    padding = max(0, width - String.length(text))
    [tagged, String.duplicate(" ", padding)]
  end

  # -- Action execution --

  defp execute_action(:boot, name) do
    Task.start(fn ->
      DrawbridgeCore.ServiceManager.request_connection(name)
    end)
  end

  defp execute_action(:stop, name) do
    Task.start(fn ->
      DrawbridgeCore.ServiceManager.stop_service(name)
    end)
  end

  defp execute_action(:restart, name) do
    Task.start(fn ->
      DrawbridgeCore.ServiceManager.stop_service(name)
      DrawbridgeCore.ServiceManager.request_connection(name)
    end)
  end

  defp selected_service(%{services: services, selected_index: idx}) do
    Enum.at(services, idx)
  end

  defp clamp_selection(%{services: []} = state), do: %{state | selected_index: 0}

  defp clamp_selection(state) do
    max_idx = length(state.services) - 1
    %{state | selected_index: min(state.selected_index, max_idx)}
  end

  defp action_label(:boot), do: "Booting"
  defp action_label(:stop), do: "Stopping"
  defp action_label(:restart), do: "Restarting"
end
