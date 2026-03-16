defmodule Mix.Tasks.Drawbridge.Init do
  @moduledoc "Generate a starter drawbridge.yml in the current directory."
  @shortdoc "Initialize Drawbridge config"

  use Mix.Task

  @default_config """
  # Drawbridge configuration
  # Docs: https://github.com/org/drawbridge

  domain: dev.local
  idle_timeout: 300  # seconds before sleeping inactive containers
  max_containers: 8

  services:
    # Example: PostgreSQL backing service
    # postgres:
    #   image: postgres:16
    #   hostname: postgres.dev.local
    #   ports:
    #     - "5432:5432"
    #   env:
    #     POSTGRES_PASSWORD: dev
    #   idle_timeout: 900

    # Example: Redis backing service
    # redis:
    #   image: redis:7
    #   hostname: redis.dev.local
    #   ports:
    #     - "6379:6379"

    # Example: Application service
    # api:
    #   image: ghcr.io/org/api:latest
    #   hostname: api.dev.local
    #   ports:
    #     - "443:4000"
    #   env:
    #     DATABASE_URL: "postgres://postgres.dev.local:5432/myapp"
    #   health_check: "curl -sf http://localhost:4000/health"
    #   depends_on:
    #     - postgres
    #     - redis
  """

  @impl Mix.Task
  def run(_args) do
    target = "drawbridge.yml"

    if File.exists?(target) do
      Mix.shell().info("#{target} already exists.")
    else
      File.write!(target, @default_config)
      Mix.shell().info("Created #{target} — edit it to configure your services.")
    end
  end
end
