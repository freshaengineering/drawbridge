defmodule DrawbridgeApi.MixProject do
  use Mix.Project

  def project do
    [
      app: :drawbridge_api,
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
      mod: {DrawbridgeApi.Application, []}
    ]
  end

  defp deps do
    [
      {:absinthe, "~> 1.7"},
      {:absinthe_plug, "~> 1.5"},
      {:plug_cowboy, "~> 2.7"},
      {:jason, "~> 1.4"},
      {:drawbridge_core, in_umbrella: true}
    ]
  end
end
