defmodule DrawbridgeTui.Dashboard do
  @moduledoc """
  Owl LiveScreen-based dashboard rendering.

  Receives service data from ServiceSubscriber and renders a live-updating
  table with color-coded states.
  """

  use GenServer

  @name __MODULE__

  # -- Public API --

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: @name)
  end

  @doc "Push new service data to the dashboard for rendering."
  def update(services) do
    GenServer.cast(@name, {:update, services})
  end

  @doc "Push pull progress data from the Swift agent."
  def pull_progress(data) do
    GenServer.cast(@name, {:pull_progress, data})
  end

  # -- Callbacks --

  @impl true
  def init(opts) do
    domain = Keyword.get(opts, :domain, "dev.local")
    Owl.LiveScreen.add_block(:dashboard, state: render([], domain, %{}))
    {:ok, %{domain: domain, pull_progress: %{}}}
  end

  @impl true
  def handle_cast({:update, services}, state) do
    # Clear progress for images no longer in :booting state
    booting_images =
      services
      |> Enum.filter(&(&1.state == :booting))
      |> Enum.map(& &1[:image])
      |> Enum.reject(&is_nil/1)
      |> MapSet.new()

    pull_progress = Map.filter(state.pull_progress, fn {image, _} -> image in booting_images end)
    state = %{state | pull_progress: pull_progress}

    Owl.LiveScreen.update(:dashboard, render(services, state.domain, state.pull_progress))
    {:noreply, state}
  end

  def handle_cast({:pull_progress, data}, state) do
    image = data["image"] || "unknown"
    progress = Map.merge(state.pull_progress[image] || %{}, data)
    pull_progress = Map.put(state.pull_progress, image, progress)
    {:noreply, %{state | pull_progress: pull_progress}}
  end

  # -- Rendering --

  @doc false
  def render(services, domain, pull_progress \\ %{}) do
    timestamp = Calendar.strftime(DateTime.utc_now(), "%H:%M:%S UTC")

    header =
      Owl.Data.tag("Drawbridge", :bright)
      |> Owl.Data.to_chardata()

    header_line = [header, " — *.", domain, "  ", Owl.Data.tag(timestamp, :faint)]

    separator = String.duplicate("─", 90)

    col_header =
      [
        pad("Service", 18),
        pad("State", 12),
        pad("Hostname", 28),
        pad("Ports", 16),
        pad("Conns", 8),
        "Uptime"
      ]
      |> Owl.Data.tag(:faint)

    rows = Enum.map(services, &render_row(&1, pull_progress))

    footer =
      Owl.Data.tag("  keybindings coming soon: q quit  •  b boot  •  s stop", :faint)

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

  defp render_row(svc, pull_progress) do
    state_tag = state_color(svc.state)

    ports =
      svc.ports
      |> Enum.map_join(", ", fn {h, c} -> "#{h}:#{c}" end)

    base = [
      pad(to_string(svc.name), 18),
      pad_tagged(state_tag, 12),
      pad(svc.hostname || "-", 28),
      pad(ports, 16),
      pad(to_string(svc.connections), 8),
      format_uptime(svc.uptime)
    ]

    image = Map.get(svc, :image)
    progress = if image, do: Map.get(pull_progress, image), else: nil

    if svc.state == :booting && progress do
      [base, "\n", render_progress_bar(progress)]
    else
      base
    end
  end

  @doc false
  def render_progress_bar(progress) do
    percent = parse_percent(progress["percent"])
    downloaded = progress["downloaded"] || "?"
    total = progress["total"] || "?"

    bar_width = 20
    filled = round(bar_width * percent / 100)
    empty = bar_width - filled

    bar = [
      Owl.Data.tag(String.duplicate("\u2588", filled), :cyan),
      Owl.Data.tag(String.duplicate("\u2591", empty), :faint)
    ]

    percent_str = "#{round(percent)}%"

    [
      pad("", 18),
      Owl.Data.tag("Pulling: ", :yellow),
      bar,
      " ",
      percent_str,
      " (#{downloaded}/#{total})"
    ]
  end

  defp parse_percent(nil), do: 0
  defp parse_percent(val) when is_number(val), do: val

  defp parse_percent(val) when is_binary(val) do
    case Float.parse(val) do
      {f, _} -> f
      :error -> 0
    end
  end

  defp parse_percent(_), do: 0

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
    # Strip ANSI escapes to get visible character count for padding
    text =
      tagged
      |> Owl.Data.to_chardata()
      |> IO.chardata_to_string()
      |> String.replace(~r/\e\[[0-9;]*m/, "")

    padding = max(0, width - String.length(text))
    [tagged, String.duplicate(" ", padding)]
  end
end
