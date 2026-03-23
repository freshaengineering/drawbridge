# Changelog

All notable changes to Drawbridge will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- `drawbridge auth` command — auto-detects GHCR and ECR registries from config and authenticates via `gh auth token` / `aws ecr get-login-password`. Supports `--ghcr` and `--ecr` flags to target a specific registry.
- `--local <service>` flag for `drawbridge up` — excludes services from orchestration while keeping their DNS hostnames pointed to 127.0.0.1, letting you run them from source
- `.env.drawbridge` generation — auto-creates a sourceable env file with the local service's configured environment variables
- Org-wide example config (`config/examples/surgeventures.drawbridge.yml`) mapping the full B2C stack with private registry images (ghcr.io + ECR)
- `Config.exclude_services/2` and `Config.local_hostnames/2` for programmatic service filtering
- `cpus` and `memory` fields on `Config.Service` for container resource limits (`--cpus`/`--memory` flags)

## [0.3.0] - 2026-03-23

### Added

- Per-packet idle timer reset — timers reset on every relayed data packet, not just on connection release, keeping long-running streaming connections alive
- Fallback HTML page for unknown SNI hostnames — TLS-terminates with local CA cert and returns a 503 page listing configured services instead of silently dropping connections
- Project-level CLAUDE.md + LLM-actionable setup docs and example configs (minimal, node-fullstack, elixir-phoenix, microservices)
- PostgreSQL wire protocol routing by database name — multiple PG services share port 5432, routed by database extracted from StartupMessage
- SSLRequest denial (`N` response) for PG-aware listeners, client retries with plain StartupMessage
- `database` field in service config for PG database-routed services
- Fallback to port-based routing when database name doesn't match any service
- Image pull progress streaming to TUI — real-time layer download progress via JSON bridge
- TUI keyboard navigation — `j`/`k` to select services, `b`/`s`/`r` to boot/stop/restart, `q` to quit, `?` for help overlay
- TUI dependency graph — ASCII visualization of service `depends_on` relationships below the service table
- TUI flash messages — brief confirmation when triggering service actions
- InputReader GenServer — raw-mode stdin reader replacing `Process.sleep(:infinity)` blocking

### Changed

- Evaluated mbearne-fresha swift-erlang-actor-system fork — benchmarked actor discovery, assessed viability (research, no code changes)

### Fixed

- CLI escript mode: replace `Mix.Task.run/Mix.shell/Mix.raise` with stdlib equivalents so commands work outside Mix


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
