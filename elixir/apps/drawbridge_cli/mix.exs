defmodule DrawbridgeCli.MixProject do
  use Mix.Project

  def project do
    [
      app: :drawbridge_cli,
      version: "0.4.0",
      build_path: "../../_build",
      config_path: "../../config/config.exs",
      deps_path: "../../deps",
      lockfile: "../../mix.lock",
      elixir: "~> 1.17",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      escript: escript()
    ]
  end

  def application do
    [
      extra_applications: [:logger]
    ]
  end

  defp escript do
    [main_module: DrawbridgeCli, name: "drawbridge"]
  end

  defp deps do
    [
      {:drawbridge_core, in_umbrella: true},
      {:drawbridge_proxy, in_umbrella: true},
      {:drawbridge_api, in_umbrella: true},
      {:drawbridge_tui, in_umbrella: true}
    ]
  end
end
