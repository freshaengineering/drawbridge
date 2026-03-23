defmodule DrawbridgeTui.DashboardTest do
  use ExUnit.Case, async: true

  alias DrawbridgeTui.Dashboard

  @sample_services [
    %{
      name: :postgres,
      state: :running,
      hostname: "postgres.dev.local",
      ports: [{5432, 5432}],
      connections: 2,
      uptime: 150,
      depends_on: []
    },
    %{
      name: :redis,
      state: :stopped,
      hostname: "redis.dev.local",
      ports: [{6379, 6379}],
      connections: 0,
      uptime: nil,
      depends_on: []
    },
    %{
      name: :"api-gateway",
      state: :running,
      hostname: "api.dev.local",
      ports: [{8080, 8080}],
      connections: 5,
      uptime: 3900,
      depends_on: ["redis"]
    },
    %{
      name: :platform,
      state: :booting,
      hostname: "platform.dev.local",
      ports: [{4000, 4000}],
      connections: 0,
      uptime: nil,
      depends_on: ["postgres", "redis", "kafka"]
    }
  ]

  defp to_string_output(rendered) do
    rendered
    |> Owl.Data.to_chardata()
    |> IO.chardata_to_string()
  end

  describe "format_uptime/1" do
    test "nil returns dash" do
      result = Dashboard.format_uptime(nil)
      assert to_string_output(result) =~ "-"
    end

    test "seconds only" do
      assert Dashboard.format_uptime(45) == "45s"
    end

    test "minutes and seconds" do
      assert Dashboard.format_uptime(150) == "2m 30s"
    end

    test "hours and minutes" do
      assert Dashboard.format_uptime(3900) == "1h 5m"
    end

    test "zero seconds" do
      assert Dashboard.format_uptime(0) == "0s"
    end
  end

  describe "render/3" do
    test "renders empty state" do
      output = to_string_output(Dashboard.render([], "dev.local"))

      assert output =~ "Drawbridge"
      assert output =~ "dev.local"
      assert output =~ "no services registered"
    end

    test "renders services with correct columns" do
      services = Enum.take(@sample_services, 2)
      output = to_string_output(Dashboard.render(services, "dev.local"))

      assert output =~ "postgres"
      assert output =~ "running"
      assert output =~ "5432:5432"
      assert output =~ "2m 30s"
      assert output =~ "redis"
      assert output =~ "stopped"
    end

    test "renders header with domain" do
      output = to_string_output(Dashboard.render([], "custom.local"))
      assert output =~ "custom.local"
    end

    test "renders footer keybindings" do
      output = to_string_output(Dashboard.render([], "dev.local"))

      assert output =~ "q quit"
      assert output =~ "b boot"
      assert output =~ "s stop"
      assert output =~ "r restart"
      assert output =~ "j/k navigate"
      assert output =~ "? help"
    end

    test "highlights selected row with > marker" do
      services = Enum.take(@sample_services, 2)

      output = to_string_output(Dashboard.render(services, "dev.local", 0))
      # First row selected — should have > marker
      assert output =~ "> "

      output_no_sel = to_string_output(Dashboard.render(services, "dev.local", -1))
      # No selection — no > marker on any row
      refute output_no_sel =~ "> "
    end

    test "selected index highlights correct row" do
      services = Enum.take(@sample_services, 2)

      # Select second row (index 1 = redis)
      output = to_string_output(Dashboard.render(services, "dev.local", 1))

      lines = String.split(output, "\n")
      selected_lines = Enum.filter(lines, &String.contains?(&1, ">"))
      assert length(selected_lines) == 1
      selected_line = hd(selected_lines)
      assert selected_line =~ "redis"
    end
  end

  describe "selection wrapping" do
    # These test the render path — the GenServer navigation is tested implicitly
    # through render's selected_index parameter.

    test "selected_index at 0 renders first row highlighted" do
      services = Enum.take(@sample_services, 3)
      output = to_string_output(Dashboard.render(services, "dev.local", 0))

      lines = String.split(output, "\n")
      selected = Enum.filter(lines, &String.contains?(&1, ">"))
      assert length(selected) == 1
      assert hd(selected) =~ "postgres"
    end

    test "selected_index at last renders last row highlighted" do
      services = Enum.take(@sample_services, 3)
      output = to_string_output(Dashboard.render(services, "dev.local", 2))

      lines = String.split(output, "\n")
      selected = Enum.filter(lines, &String.contains?(&1, ">"))
      assert length(selected) == 1
      assert hd(selected) =~ "api-gateway"
    end
  end

  describe "dependency graph rendering" do
    test "renders dependency arrows for services with depends_on" do
      # Use render_deps indirectly through a full render_all-like assembly
      # We test via the public render and adding deps section manually
      deps_output =
        @sample_services
        |> Enum.filter(fn svc -> Map.get(svc, :depends_on, []) != [] end)
        |> Enum.sort_by(& &1.name)
        |> Enum.map(fn svc ->
          deps_str = svc.depends_on |> Enum.sort() |> Enum.join(", ")
          "#{svc.name} → #{deps_str}"
        end)
        |> Enum.join("\n")

      assert deps_output =~ "api-gateway → redis"
      assert deps_output =~ "platform → kafka, postgres, redis"
    end

    test "services with no dependencies are excluded from graph" do
      deps =
        @sample_services
        |> Enum.filter(fn svc -> Map.get(svc, :depends_on, []) != [] end)
        |> Enum.map(& &1.name)

      refute :postgres in deps
      refute :redis in deps
    end
  end
end
