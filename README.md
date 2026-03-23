# Drawbridge

On-demand local dev stack proxy for macOS. Hit an endpoint, the required container boots automatically. Walk away, it sleeps. No Docker Compose, no manual orchestration.

> Idea by [@mbearne-fresha](https://github.com/mbearne-fresha)

## Features

| Feature | Status | Description |
|---------|--------|-------------|
| SNI-based TLS routing | **Done** | Extracts hostname from TLS ClientHello, routes to the right container |
| Port-based TCP routing | **Done** | Non-TLS services (Postgres, Redis, Kafka) routed by port number |
| Lazy container boot | **Done** | Containers start on first request, not at startup |
| Idle sleep | **Done** | Containers stop after configurable idle timeout (default 5m) |
| Connection queuing | **Done** | Requests queue during boot — zero dropped connections |
| Health checks | **Done** | TCP or command-based readiness checks before routing traffic |
| Dependency ordering | **Done** | `depends_on` boots prerequisites first |
| Local CA + TLS certs | **Done** | Auto-generated wildcard certs trusted by macOS keychain |
| DNS resolver management | **Done** | Auto-configures `*.dev.local` via `/etc/resolver/` |
| Apple Container runtime | **Done** | Lightweight VMs via Virtualization.framework, not Docker |
| Swift-Erlang interop | **Partial** | Container agent joins BEAM cluster via swift-erlang-actor-system |
| GraphQL API + MCP server | **Done** | AI agent integration via Absinthe GraphQL and MCP stdio protocol |
| L7 protocol inspection | **Done** | HTTP/gRPC/Kafka/Postgres wire protocol decoding |
| OpenTelemetry / Datadog | **Done** | Telemetry events + OTel spans for proxy and service lifecycle |
| TUI | **Done** | Terminal UI for service topology and traffic flow |

## How it works

```
curl https://api.b2c.dev.local
        │
        │ TLS ClientHello (SNI: api.b2c.dev.local)
        ▼
┌──────────────────────────────┐
│  Elixir/Ranch Proxy          │  1. Extract hostname from SNI
│  (L4 TCP proxy)              │  2. Lookup service in registry
│                              │  3. Boot container if sleeping
│                              │  4. Queue connections until ready
│                              │  5. Bidirectional TCP relay
└──────────┬───────────────────┘
           │ Erlang distribution protocol
           ▼
┌──────────────────────────────┐
│  Swift Container Agent       │  Erlang-compatible node via
│  (DrawbridgeAgent)           │  swift-erlang-actor-system
│                              │  Pull / start / stop / health check
└──────────┬───────────────────┘
           │ Apple Container CLI
           ▼
┌──────────────────────────────┐
│  Apple Container             │  Lightweight VMs, not namespaces
│  (Virtualization.framework)  │  OCI images, vmnet networking
└──────────────────────────────┘
```

**The key insight**: TLS connections advertise the target hostname in plaintext via the SNI extension *before* encryption begins. The proxy reads this, decides which container should handle it, boots it if needed, then passes the raw TCP stream through untouched.

Non-TLS services (Postgres on 5432, Redis on 6379, etc.) are routed by port number instead.

## Quickstart

### Requirements

- macOS 26+ (Tahoe) — Apple Container requires it
- Apple Silicon
- Elixir 1.17+ / OTP 27+
- Swift 6+
- Apple Container CLI (`container`)

### Install from release

Add to your project's `.mise.toml` (or global `~/.config/mise/config.toml`):

```toml
[tools]
"github:surgeventures/drawbridge" = "latest"
```

Then:

```bash
mise install
```

Or install directly:

```bash
mise use -g "github:surgeventures/drawbridge@latest"
```

This pulls the latest release binary from GitHub and adds `drawbridge` to your PATH via mise.

### Install from source (for drawbridge development)

```bash
git clone https://github.com/surgeventures/drawbridge.git
cd drawbridge
task setup              # installs deps + builds elixir and swift
task dev:install        # adds drawbridge to PATH via ../mise.local.toml
```

This makes `drawbridge` available in all sibling project directories via mise.

### Configure your stack

Copy the example config (tailored to the Fresha B2C stack):

```bash
cp config/example.drawbridge.yml drawbridge.yml
```

The example maps the full B2C consumer flow — comment out whichever service you're developing locally:

```yaml
domain: dev.local
idle_timeout: 300
max_containers: 10

services:
  # Backing services
  postgres:
    image: postgis/postgis:17-3.5
    hostname: postgres.dev.local
    ports:
      - "5432:5432"
    env:
      POSTGRES_PASSWORD: dev
      POSTGRES_DB: shedul_dev
    idle_timeout: 1800

  redis:
    image: redis:6.2
    hostname: redis.dev.local
    ports:
      - "6379:6379"
    idle_timeout: 1800

  elasticsearch:
    image: elasticsearch:9.0.3
    hostname: es.dev.local
    ports:
      - "9200:9200"
    env:
      discovery.type: single-node
    boot_timeout: 60

  kafka:
    image: confluentinc/cp-kafka:7.6.0
    hostname: kafka.dev.local
    ports:
      - "9092:9092"
    env:
      KAFKA_ADVERTISED_LISTENERS: "PLAINTEXT://kafka.dev.local:9092"

  # B2C API Gateway (Node.js/GraphQL BFF)
  api-gateway:
    image: ghcr.io/surgeventures/app-b2c-api-gateway:latest
    hostname: api.b2c.dev.local
    ports:
      - "443:3000"
    env:
      CACHE_REDIS_URL: "redis://redis.dev.local:6379"
      B2C_USERS_GRPC_URL: "b2c-users.dev.local:50051"
      PLATFORM_GRPC_URL: "platform.dev.local:50051"
    depends_on: [redis]

  # B2C Users (Elixir/gRPC)
  b2c-users:
    image: ghcr.io/surgeventures/app-b2c-users:latest
    hostname: b2c-users.dev.local
    ports:
      - "50051:50051"
    env:
      DATABASE_URL: "postgres://postgres:dev@postgres.dev.local:5432/b2c_users_dev"
      REDIS_URL: "redis://redis.dev.local:6379"
    depends_on: [postgres, redis]

  # Platform / Shedul umbrella (Elixir — 27 apps)
  platform:
    image: ghcr.io/surgeventures/app-shedul-umbrella:latest
    hostname: platform.dev.local
    ports:
      - "50052:50051"
      - "4000:4000"
    env:
      DATABASE_URL: "postgres://postgres:dev@postgres.dev.local:5432/shedul_dev"
      REDIS_URL: "redis://redis.dev.local:6379"
      KAFKA_BROKERS: "kafka.dev.local:9092"
    depends_on: [postgres, redis, kafka]

  # Marketplace Search (Elixir — ES + Kafka)
  marketplace-search:
    image: ghcr.io/surgeventures/app-marketplace-search:latest
    hostname: search.dev.local
    ports:
      - "50053:50051"
    env:
      DATABASE_URL: "postgres://postgres:dev@postgres.dev.local:5432/marketplace_search_dev"
      ELASTICSEARCH_URL: "http://es.dev.local:9200"
      KAFKA_BROKERS: "kafka.dev.local:9092"
    depends_on: [postgres, elasticsearch, kafka]
```

### Run

```bash
# Start the proxy (first run generates certs + configures DNS)
task up

# In another terminal — hit the B2C gateway:
# This auto-boots: redis → api-gateway (and on first API call, postgres → b2c-users → platform)
curl https://api.b2c.dev.local/health

# Check what's running
task status

# Pre-pull all images for faster cold starts
task pull -- --all

# Stop everything
task down
```

### Example session

```
$ task up
[Drawbridge] Loading config from drawbridge.yml
[CertManager] Generating root CA...
[CertManager] CA trusted successfully
[CertManager] Generating wildcard cert for *.dev.local...
[DnsManager] DNS resolver configured for *.dev.local

  Drawbridge is up
  Domain: *.dev.local

  Service             Hostname                      Ports               State
  ────────────────────────────────────────────────────────────────────────────────
  postgres            postgres.dev.local            5432:5432           sleeping
  redis               redis.dev.local               6379:6379           sleeping
  elasticsearch       es.dev.local                  9200:9200           sleeping
  kafka               kafka.dev.local               9092:9092           sleeping
  api-gateway         api.b2c.dev.local             443:3000            sleeping
  b2c-users           b2c-users.dev.local           50051:50051         sleeping
  platform            platform.dev.local            50052:50051         sleeping
  marketplace-search  search.dev.local              50053:50051         sleeping

  Proxy running. Hit Ctrl+C to stop.

# Hit the B2C gateway — this triggers a cascade of lazy boots:
$ curl https://api.b2c.dev.local/health
#   → redis boots (api-gateway depends_on)
#   → api-gateway boots
#   → {"status": "ok"}

# Now the gateway's up. A real GraphQL query that fetches user data
# would trigger more services:
$ curl -X POST https://api.b2c.dev.local/graphql \
    -H 'Content-Type: application/json' \
    -d '{"query": "{ me { name favourites { id } } }"}'
#   → postgres boots (b2c-users depends_on)
#   → b2c-users boots on :50051
#   → gateway calls b2c-users via gRPC
#   → {"data": {"me": {"name": "...", "favourites": [...]}}}

# Only the services that were actually needed are running:
$ task status
  Service             State       Hostname                    Ports           Conns   Uptime
  ──────────────────────────────────────────────────────────────────────────────────────────
  postgres            running     postgres.dev.local          5432:5432       1       45s
  redis               running     redis.dev.local             6379:6379       1       52s
  elasticsearch       sleeping    es.dev.local                9200:9200       0       -
  kafka               sleeping    kafka.dev.local             9092:9092       0       -
  api-gateway         running     api.b2c.dev.local           443:3000        0       48s
  b2c-users           running     b2c-users.dev.local         50051:50051     0       42s
  platform            sleeping    platform.dev.local          50052:50051     0       -
  marketplace-search  sleeping    search.dev.local            50053:50051     0       -

# Elasticsearch, Kafka, Platform, and Marketplace Search never booted —
# they weren't needed. When they are, they'll start automatically.

# Connect to the DB directly — Drawbridge routes :5432 by port:
$ psql -h localhost -p 5432 -U postgres shedul_dev
psql (17.0)
Type "help" for help.
shedul_dev=#

# After 5 minutes idle, services sleep to free resources:
$ task status
  Service             State       Hostname                    Ports           Conns   Uptime
  ──────────────────────────────────────────────────────────────────────────────────────────
  postgres            sleeping    postgres.dev.local          5432:5432       0       -
  redis               sleeping    redis.dev.local             6379:6379       0       -
  ...
```

## Example configs

See `config/examples/` for configs tailored to common stacks:

- [`minimal.drawbridge.yml`](config/examples/minimal.drawbridge.yml) — single service + Postgres
- [`node-fullstack.drawbridge.yml`](config/examples/node-fullstack.drawbridge.yml) — Node.js API + Postgres + Redis
- [`elixir-phoenix.drawbridge.yml`](config/examples/elixir-phoenix.drawbridge.yml) — Phoenix + Postgres + Redis + Elasticsearch
- [`microservices.drawbridge.yml`](config/examples/microservices.drawbridge.yml) — gRPC services with dependency chains

## Configuration reference

### Service options

| Field | Default | Description |
|-------|---------|-------------|
| `image` | *required* | OCI image reference |
| `hostname` | *required* | Hostname for SNI routing |
| `ports` | *required* | Port mappings (`host:container`) |
| `env` | `{}` | Environment variables passed to container |
| `idle_timeout` | global (300s) | Seconds of inactivity before sleeping |
| `boot_timeout` | `30` | Max seconds to wait for health check |
| `health_check` | TCP connect | Shell command to verify readiness |
| `tls_backend` | `false` | Whether the container expects TLS |
| `depends_on` | `[]` | Services that must be running first |

### Global options

| Field | Default | Description |
|-------|---------|-------------|
| `domain` | `dev.local` | Base domain for all services |
| `idle_timeout` | `300` | Default idle timeout for all services |
| `max_containers` | `8` | Maximum concurrent containers |

## Architecture

The project is an Elixir umbrella with a Swift companion:

```
drawbridge/
├── elixir/
│   └── apps/
│       ├── drawbridge_proxy/   # Ranch-based L4 proxy (SNI + port routing)
│       ├── drawbridge_core/    # Config, state machine, Swift bridge, certs, DNS
│       ├── drawbridge_api/     # GraphQL API (Absinthe) + MCP server
│       ├── drawbridge_tui/     # Owl-based terminal dashboard
│       └── drawbridge_cli/     # Mix tasks (up, down, status, pull, init, api, mcp, tui)
├── swift/
│   └── Sources/DrawbridgeAgent/  # Apple Container lifecycle manager
└── config/
    └── example.drawbridge.yml
```

**Why Elixir + Swift?** Elixir/OTP is built for this — Ranch handles thousands of concurrent connections, supervision trees recover from crashes, and the BEAM's distribution protocol lets the Swift agent join the cluster as a native node. Swift is needed because Apple Container's runtime is macOS-native.

**Why not just Docker?** Apple Container runs lightweight VMs via Virtualization.framework — no Docker Desktop, no Linux VM overhead, native macOS networking. Each container is fully isolated at the hypervisor level.

## Status

Experimental. Pre-alpha. The core proxy and state management are implemented and tested (135 tests). Integration with Apple Container requires macOS 26.

Known risks:
- Apple Container is pre-1.0 — API may break between minor versions
- swift-erlang-actor-system is early-stage (stdin/stdout JSON fallback included)
- macOS 26 is required for container networking features

## Roadmap

- [ ] End-to-end integration test on macOS 26
- [x] L7 protocol-aware proxy (HTTP/gRPC/Kafka/Postgres wire protocol inspection)
- [x] OpenTelemetry instrumentation (telemetry events + OTel spans)
- [x] TUI for service topology, traffic flow, and log tailing
- [x] `drawbridge.lock` for reproducible image version pinning
- [x] AI agent API — GraphQL + MCP server for coding agent integration

## Credits

- [@mbearne-fresha](https://github.com/mbearne-fresha) — original idea and concept
- Built with [Ranch](https://ninenines.eu/docs/en/ranch/2.2/guide/), [swift-erlang-actor-system](https://github.com/otp-interop/swift-erlang-actor-system), and [Apple Container](https://github.com/apple/container)
