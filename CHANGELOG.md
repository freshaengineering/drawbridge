# Changelog

All notable changes to Drawbridge will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Fixed

- Reset idle timer on every relayed data packet, not just on connection release — long-running streaming connections now properly keep services alive

## [0.2.0] - 2026-03-23

### Added

- E2E integration test scaffolding
- L7 protocol-aware proxy — HTTP/1.1, Postgres, Redis, and Kafka wire protocol parsers with pluggable `Protocol` behaviour
- OpenTelemetry instrumentation — telemetry events on proxy/service lifecycle, OTel spans for connections and container ops
- TUI dashboard — Owl-based live terminal UI with color-coded service states, uptime, and connection counts (`drawbridge tui` / `drawbridge up --tui`)
- `drawbridge.lock` for reproducible image version pinning
- GraphQL API + MCP server — Absinthe schema (`drawbridge_api`), HTTP daemon with GraphiQL, stdio MCP with `schema_sdl` + `graphql` tools
- Robust JSON IPC bridge for Swift agent — replaces broken Erlang RPC with stdin/stdout JSON-RPC

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
