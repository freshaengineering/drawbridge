defmodule DrawbridgeProxy.MixProject do
  use Mix.Project

  def project do
    [
      app: :drawbridge_proxy,
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
      extra_applications: [:logger, :ssl],
      mod: {DrawbridgeProxy.Application, []}
    ]
  end

  defp deps do
    [
      {:ranch, "~> 2.2"},
      {:drawbridge_core, in_umbrella: true},
      {:opentelemetry_api, "~> 1.5"}
    ]
  end
end
