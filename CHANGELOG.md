# Changelog

All notable changes to Drawbridge will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- GraphQL API via Absinthe (`drawbridge_api` umbrella app) — queries for services/state, mutations for boot/stop
- MCP server over stdio JSON-RPC 2.0 (`drawbridge mcp`) — exposes `schema_sdl` and `graphql` tools for AI agent integration
- HTTP daemon mode (`drawbridge api`) with GraphiQL playground at `/` and `/graphql` endpoint
- `setupPrompt` query returning markdown setup guide for AI agents configuring new projects
- `schemaSdl` query for runtime schema introspection
- L7 protocol-aware proxy: detect HTTP/1.1, Postgres, Redis, and Kafka wire protocols on first client chunk
- Protocol behaviour (`DrawbridgeProxy.Protocol`) with `detect/1` callback for pluggable parsers
- ETS-backed `ProtocolRegistry` for storing per-connection protocol metadata (keyed by service + connection ref)
- Optional `protocol` hint field on `Config.Service` for explicit protocol declaration
- SniHandler records `:tls` protocol with SNI hostname; PortHandler runs full protocol detection on raw TCP
- TUI dashboard via Owl LiveScreen — live-updating service table with color-coded states, uptime, and connection counts
- `drawbridge tui` command and `drawbridge up --tui` flag
- New `drawbridge_tui` umbrella app with ServiceSubscriber (1s polling) and Dashboard renderer

## [0.1.0] - 2026-03-16

### Added

- SNI-aware TLS proxy via Elixir/Ranch — extracts hostname from TLS ClientHello
- Port-based TCP routing for non-TLS services (Postgres, Redis, Kafka, Elasticsearch)
- On-demand container lifecycle — containers boot on first request, sleep on idle
- Connection queuing during container boot with zero dropped connections
- Service state machine: not_pulled → stopped → booting → running → idle sleep
- Configurable idle timeouts (global + per-service override)
- Health checks (TCP connect or shell command) with configurable boot timeout
- Dependency ordering via `depends_on` in service config
- Local CA generation + wildcard TLS certs for `*.dev.local`
- macOS DNS resolver management (`/etc/resolver/`)
- Swift container agent wrapping Apple Container CLI
- Swift-Erlang interop via swift-erlang-actor-system (+ stdin/stdout JSON fallback)
- YAML config format (`drawbridge.yml`) with validation
- CLI: `mix drawbridge.up`, `down`, `status`, `pull`, `init`
- Example config with Postgres, Redis, Kafka, Elasticsearch, and API service
