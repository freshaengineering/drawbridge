# Drawbridge Development

## Structure
- `elixir/` — Elixir umbrella (OTP 28.2, Elixir 1.19.5)
  - `apps/drawbridge_core/` — Config, service lifecycle, Swift bridge, certs, DNS
  - `apps/drawbridge_proxy/` — Ranch-based L4 proxy (SNI + port routing)
  - `apps/drawbridge_cli/` — Escript CLI (up, down, status, pull, lock, auth, tui, api, mcp)
  - `apps/drawbridge_tui/` — Owl-based terminal dashboard
  - `apps/drawbridge_api/` — Absinthe GraphQL API + MCP server
- `swift/` — Swift 6.0 container agent (Apple Container CLI wrapper)
- `config/` — Example drawbridge.yml configs

## Commands
- `cd elixir && mise x -- mix test` — run all tests
- `cd elixir && mise x -- mix format` — format code
- `cd elixir && mise x -- mix compile --warnings-as-errors` — compile with strict warnings
- `cd elixir && mise x -- mix deps.get` — fetch dependencies
- `cd swift && swift build` — build Swift agent
- `task setup` — full setup (deps + build)
- `task up` — start drawbridge

## Testing patterns
- Tests use `StubSwiftBridge` (configured in `config/test.exs`)
- Inject `:container_ready` / `:container_error` messages to ServiceManager manually
- Integration tests use real TCP backend servers on localhost
- Protocol parser tests use real wire format binary samples

## Key patterns
- ServiceManager: one GenServer per service, registered via Registry
- Handlers (SniHandler, PortHandler): gen_statem state machines
- Swift IPC: newline-delimited JSON over Erlang Port (JsonBridge)
- Protocol detection: first-chunk-only, stored in ETS ProtocolRegistry
- Telemetry: :telemetry events → OpenTelemetry spans

## PR conventions
- Run format + compile + test before pushing
- Update CHANGELOG.md under `## [Unreleased]`
- Update README.md feature table/roadmap if applicable
