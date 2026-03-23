defmodule DrawbridgeTui.DashboardTest do
  use ExUnit.Case, async: true

  alias DrawbridgeTui.Dashboard

  describe "format_uptime/1" do
    test "nil returns dash" do
      result = Dashboard.format_uptime(nil)
      assert IO.chardata_to_string(Owl.Data.to_chardata(result)) =~ "-"
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

  describe "render/2" do
    test "renders empty state" do
      output =
        Dashboard.render([], "dev.local")
        |> Owl.Data.to_chardata()
        |> IO.chardata_to_string()

      assert output =~ "Drawbridge"
      assert output =~ "dev.local"
      assert output =~ "no services registered"
    end

    test "renders services with correct columns" do
      services = [
        %{
          name: :postgres,
          state: :running,
          hostname: "postgres.dev.local",
          ports: [{5432, 5432}],
          connections: 2,
          uptime: 150
        },
        %{
          name: :redis,
          state: :stopped,
          hostname: "redis.dev.local",
          ports: [{6379, 6379}],
          connections: 0,
          uptime: nil
        }
      ]

      output =
        Dashboard.render(services, "dev.local")
        |> Owl.Data.to_chardata()
        |> IO.chardata_to_string()

      assert output =~ "postgres"
      assert output =~ "running"
      assert output =~ "5432:5432"
      assert output =~ "2m 30s"
      assert output =~ "redis"
      assert output =~ "stopped"
    end

    test "renders header with domain" do
      output =
        Dashboard.render([], "custom.local")
        |> Owl.Data.to_chardata()
        |> IO.chardata_to_string()

      assert output =~ "custom.local"
    end

    test "renders footer keybindings" do
      output =
        Dashboard.render([], "dev.local")
        |> Owl.Data.to_chardata()
        |> IO.chardata_to_string()

      assert output =~ "q quit"
      assert output =~ "b boot"
      assert output =~ "s stop"
    end
  end
end
