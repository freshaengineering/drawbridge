import Config

config :drawbridge_core,
  config_file: "drawbridge.yml",
  data_dir: "~/.drawbridge",
  default_idle_timeout: 300,
  max_containers: 8,
  swift_bridge: DrawbridgeCore.JsonBridge

config :drawbridge_proxy,
  tls_port: 443,
  # Non-TLS listeners are dynamically created from config
  cert_dir: "~/.drawbridge/certs"

config :logger,
  level: :info

import_config "#{config_env()}.exs"
