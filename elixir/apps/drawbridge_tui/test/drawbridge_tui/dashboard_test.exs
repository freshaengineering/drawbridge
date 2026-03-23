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
          image: "postgres:16",
          ports: [{5432, 5432}],
          connections: 2,
          uptime: 150
        },
        %{
          name: :redis,
          state: :stopped,
          hostname: "redis.dev.local",
          image: "redis:7",
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

  describe "render/3 with pull progress" do
    test "renders progress bar for booting service with active pull" do
      services = [
        %{
          name: :search,
          state: :booting,
          hostname: "search.dev.local",
          image: "ghcr.io/app/search:latest",
          ports: [{50053, 50051}],
          connections: 0,
          uptime: nil
        }
      ]

      pull_progress = %{
        "ghcr.io/app/search:latest" => %{
          "image" => "ghcr.io/app/search:latest",
          "percent" => "45",
          "downloaded" => "230MB",
          "total" => "512MB"
        }
      }

      output =
        Dashboard.render(services, "dev.local", pull_progress)
        |> Owl.Data.to_chardata()
        |> IO.chardata_to_string()

      assert output =~ "search"
      assert output =~ "booting"
      assert output =~ "Pulling:"
      assert output =~ "45%"
      assert output =~ "230MB/512MB"
    end

    test "does not render progress for running services" do
      services = [
        %{
          name: :postgres,
          state: :running,
          hostname: "postgres.dev.local",
          image: "postgres:16",
          ports: [{5432, 5432}],
          connections: 1,
          uptime: 60
        }
      ]

      pull_progress = %{
        "postgres:16" => %{
          "image" => "postgres:16",
          "percent" => "100",
          "downloaded" => "200MB",
          "total" => "200MB"
        }
      }

      output =
        Dashboard.render(services, "dev.local", pull_progress)
        |> Owl.Data.to_chardata()
        |> IO.chardata_to_string()

      refute output =~ "Pulling:"
    end
  end

  describe "render_progress_bar/1" do
    test "renders 0% progress" do
      output =
        Dashboard.render_progress_bar(%{
          "percent" => "0",
          "downloaded" => "0MB",
          "total" => "100MB"
        })
        |> Owl.Data.to_chardata()
        |> IO.chardata_to_string()

      assert output =~ "0%"
      assert output =~ "0MB/100MB"
    end

    test "renders 50% progress" do
      output =
        Dashboard.render_progress_bar(%{
          "percent" => "50",
          "downloaded" => "50MB",
          "total" => "100MB"
        })
        |> Owl.Data.to_chardata()
        |> IO.chardata_to_string()

      assert output =~ "50%"
      assert output =~ "50MB/100MB"
    end

    test "handles nil percent gracefully" do
      output =
        Dashboard.render_progress_bar(%{"downloaded" => "?", "total" => "?"})
        |> Owl.Data.to_chardata()
        |> IO.chardata_to_string()

      assert output =~ "0%"
    end
  end
end
