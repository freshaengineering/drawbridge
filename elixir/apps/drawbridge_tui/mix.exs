defmodule DrawbridgeTui.MixProject do
  use Mix.Project

  def project do
    [
      app: :drawbridge_tui,
      version: "0.4.0",
      build_path: "../../_build",
      config_path: "../../config/config.exs",
      deps_path: "../../deps",
      lockfile: "../../mix.lock",
      elixir: "~> 1.17",
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  def application do
    [
      extra_applications: [:logger],
      mod: {DrawbridgeTui.Application, []}
    ]
  end

  defp deps do
    [
      {:owl, "~> 0.13"},
      {:drawbridge_core, in_umbrella: true}
    ]
  end
end
