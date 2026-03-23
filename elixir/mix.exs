defmodule Drawbridge.MixProject do
  use Mix.Project

  def project do
    [
      apps_path: "apps",
      version: "0.1.0",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      releases: releases()
    ]
  end

  defp deps do
    [
      {:yaml_elixir, "~> 2.11"},
      {:jason, "~> 1.4"}
    ]
  end

  defp releases do
    [
      drawbridge: [
        applications: [
          drawbridge_core: :permanent,
          drawbridge_proxy: :permanent,
          drawbridge_tui: :permanent,
          drawbridge_cli: :permanent
        ]
      ]
    ]
  end
end
