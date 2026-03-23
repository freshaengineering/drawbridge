import Config

config :logger, level: :warning

config :opentelemetry,
  traces_exporter: :none

config :drawbridge_core,
  swift_bridge: DrawbridgeCore.StubSwiftBridge

config :drawbridge_proxy,
  tls_port: 8443
