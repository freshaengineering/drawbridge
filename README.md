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
| L7 protocol inspection | Planned | HTTP/gRPC/Kafka/Postgres wire protocol decoding |
| OpenTelemetry / Datadog | Planned | Local distributed tracing and log aggregation |
| TUI | Planned | Terminal UI for service topology and traffic flow |

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

### Install and build

```bash
git clone https://github.com/surgeventures/drawbridge.git
cd drawbridge/elixir
mix deps.get && mix compile

# Build the Swift agent
cd ../swift
swift build -c release
```

### Configure your stack

```bash
cd ~/your-project
mix drawbridge.init    # generates drawbridge.yml
```

Edit `drawbridge.yml`:

```yaml
domain: dev.local
idle_timeout: 300
max_containers: 8

services:
  postgres:
    image: postgres:16
    hostname: postgres.dev.local
    ports:
      - "5432:5432"
    env:
      POSTGRES_PASSWORD: dev
    idle_timeout: 900

  redis:
    image: redis:7
    hostname: redis.dev.local
    ports:
      - "6379:6379"

  api-b2c:
    image: ghcr.io/org/api-b2c:latest
    hostname: api.b2c.dev.local
    ports:
      - "443:4000"
    env:
      DATABASE_URL: "postgres://postgres.dev.local:5432/b2c"
      REDIS_URL: "redis://redis.dev.local:6379"
    health_check: "curl -sf http://localhost:4000/health"
    boot_timeout: 60
    depends_on:
      - postgres
      - redis
```

### Run

```bash
# Start the proxy (first run generates certs + configures DNS)
mix drawbridge.up

# In another terminal — this triggers postgres + redis + api-b2c to boot:
curl https://api.b2c.dev.local/health

# Check what's running
mix drawbridge.status

# Pre-pull images for faster first boot
mix drawbridge.pull --all

# Stop everything
mix drawbridge.down
```

### Example session

```
$ mix drawbridge.up
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
  api-b2c             api.b2c.dev.local             443:4000            sleeping

  Proxy running. Hit Ctrl+C to stop.

# Meanwhile, in another terminal:
$ curl https://api.b2c.dev.local/health
# → postgres boots (depends_on)
# → redis boots (depends_on)
# → api-b2c boots
# → health check passes
# → {"status": "ok"}

$ mix drawbridge.status
  Service             State       Hostname                    Ports           Conns   Uptime
  ──────────────────────────────────────────────────────────────────────────────────────────
  postgres            running     postgres.dev.local          5432:5432       1       2m 14s
  redis               running     redis.dev.local             6379:6379       1       2m 12s
  api-b2c             running     api.b2c.dev.local           443:4000        0       2m 5s

# After 5 minutes of no traffic:
$ mix drawbridge.status
  Service             State       Hostname                    Ports           Conns   Uptime
  ──────────────────────────────────────────────────────────────────────────────────────────
  postgres            sleeping    postgres.dev.local          5432:5432       0       -
  redis               sleeping    redis.dev.local             6379:6379       0       -
  api-b2c             sleeping    api.b2c.dev.local           443:4000        0       -
```

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
│       └── drawbridge_cli/     # Mix tasks (up, down, status, pull, init)
├── swift/
│   └── Sources/DrawbridgeAgent/  # Apple Container lifecycle manager
└── config/
    └── example.drawbridge.yml
```

**Why Elixir + Swift?** Elixir/OTP is built for this — Ranch handles thousands of concurrent connections, supervision trees recover from crashes, and the BEAM's distribution protocol lets the Swift agent join the cluster as a native node. Swift is needed because Apple Container's runtime is macOS-native.

**Why not just Docker?** Apple Container runs lightweight VMs via Virtualization.framework — no Docker Desktop, no Linux VM overhead, native macOS networking. Each container is fully isolated at the hypervisor level.

## Status

Experimental. Pre-alpha. The core proxy and state management are implemented and tested (33 tests). Integration with Apple Container requires macOS 26.

Known risks:
- Apple Container is pre-1.0 — API may break between minor versions
- swift-erlang-actor-system is early-stage (stdin/stdout JSON fallback included)
- macOS 26 is required for container networking features

## Roadmap

- [ ] End-to-end integration test on macOS 26
- [ ] L7 protocol-aware proxy (HTTP/gRPC/Kafka/Postgres wire protocol inspection)
- [ ] OpenTelemetry + Datadog local collector for distributed tracing
- [ ] TUI for service topology, traffic flow, and log tailing
- [ ] `drawbridge.lock` for reproducible image version pinning
- [ ] AI agent API — expose proxy state and wire protocol data to coding agents

## Credits

- [@mbearne-fresha](https://github.com/mbearne-fresha) — original idea and concept
- Built with [Ranch](https://ninenines.eu/docs/en/ranch/2.2/guide/), [swift-erlang-actor-system](https://github.com/otp-interop/swift-erlang-actor-system), and [Apple Container](https://github.com/apple/container)
