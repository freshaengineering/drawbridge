import Config

config :drawbridge_core,
  config_file: "drawbridge.yml",
  data_dir: "~/.drawbridge",
  default_idle_timeout: 300,
  max_containers: 8

config :drawbridge_proxy,
  tls_port: 443,
  # Non-TLS listeners are dynamically created from config
  cert_dir: "~/.drawbridge/certs"

config :opentelemetry,
  span_processor: :batch,
  traces_exporter: {:opentelemetry_exporter, %{endpoints: ["http://localhost:4317"]}}

config :logger,
  level: :info

import_config "#{config_env()}.exs"
