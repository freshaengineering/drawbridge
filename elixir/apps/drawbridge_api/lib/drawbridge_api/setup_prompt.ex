defmodule DrawbridgeApi.SetupPrompt do
  @moduledoc false

  def render do
    """
    # Drawbridge Setup Guide

    Drawbridge is an on-demand local dev stack proxy. Services boot automatically when
    traffic arrives and sleep after idle timeout. No Docker Compose, no manual orchestration.

    ## Creating drawbridge.yml

    Place `drawbridge.yml` in your project root:

    ```yaml
    domain: dev.local
    idle_timeout: 300      # global idle timeout in seconds
    max_containers: 8      # max concurrent containers

    services:
      postgres:
        image: postgres:17
        hostname: postgres.dev.local
        ports:
          - "5432:5432"
        env:
          POSTGRES_PASSWORD: dev
          POSTGRES_DB: myapp_dev
        idle_timeout: 1800   # override: 30min for databases

      redis:
        image: redis:7
        hostname: redis.dev.local
        ports:
          - "6379:6379"

      elasticsearch:
        image: elasticsearch:8.15.0
        hostname: es.dev.local
        ports:
          - "9200:9200"
        env:
          discovery.type: single-node
        boot_timeout: 60

      myapp:
        image: ghcr.io/org/myapp:latest
        hostname: myapp.dev.local
        ports:
          - "443:4000"
        env:
          DATABASE_URL: "postgres://postgres:dev@postgres.dev.local:5432/myapp_dev"
          REDIS_URL: "redis://redis.dev.local:6379"
        depends_on: [postgres, redis]
    ```

    ## Service Config Reference

    | Field          | Default       | Description                                    |
    |----------------|---------------|------------------------------------------------|
    | `image`        | **required**  | OCI image reference                            |
    | `hostname`     | **required**  | Hostname for SNI routing                       |
    | `ports`        | **required**  | Port mappings (`host:container`)               |
    | `env`          | `{}`          | Environment variables passed to container      |
    | `idle_timeout` | global (300s) | Seconds of inactivity before sleeping          |
    | `boot_timeout` | `30`          | Max seconds to wait for health check           |
    | `health_check` | TCP connect   | Shell command to verify readiness              |
    | `tls_backend`  | `false`       | Whether the container expects TLS              |
    | `depends_on`   | `[]`          | Services that must be running first            |

    ## Global Config

    | Field            | Default     | Description                        |
    |------------------|-------------|------------------------------------|
    | `domain`         | `dev.local` | Base domain for all services       |
    | `idle_timeout`   | `300`       | Default idle timeout for services  |
    | `max_containers` | `8`         | Maximum concurrent containers      |

    ## CLI Commands

    ```bash
    drawbridge up [--config path] [--no-dns]   # Start proxy + orchestrator
    drawbridge down [--config path]             # Stop all containers + proxy
    drawbridge status                           # Show service states
    drawbridge pull [service...] [--all]        # Pre-pull images
    drawbridge init                             # Generate example drawbridge.yml
    drawbridge api [--port 4001]                # Start GraphQL HTTP server
    drawbridge mcp                              # Start MCP server (stdio)
    ```

    ## GraphQL API

    Query the schema SDL via the `schemaSdl` query to see all available operations.
    The API exposes queries for listing services and their states, plus mutations
    for booting and stopping individual services.

    ## MCP Server

    Connect the MCP server to Claude Code by adding to `.claude/settings.json`:

    ```json
    {
      "mcpServers": {
        "drawbridge": {
          "command": "drawbridge",
          "args": ["mcp", "--config", "drawbridge.yml"]
        }
      }
    }
    ```

    The MCP server exposes two tools:
    - `schema_sdl` — returns the GraphQL schema as SDL
    - `graphql` — execute arbitrary GraphQL queries/mutations
    """
  end
end
