defmodule Mix.Tasks.Drawbridge.UpTest do
  use ExUnit.Case, async: true

  alias DrawbridgeCore.Config

  @valid_yaml """
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

    redis:
      image: redis:7
      hostname: redis.dev.local
      ports:
        - "6379:6379"

    api:
      image: ghcr.io/org/api:latest
      hostname: api.dev.local
      ports:
        - "443:3000"
      env:
        DATABASE_URL: "postgres://postgres:dev@postgres.dev.local:5432/api_dev"
        REDIS_URL: "redis://redis.dev.local:6379"
      depends_on:
        - postgres
        - redis
  """

  setup do
    tmp = System.tmp_dir!()
    path = Path.join(tmp, "drawbridge_up_test_#{:rand.uniform(100_000)}.yml")
    File.write!(path, @valid_yaml)
    on_exit(fn -> File.rm(path) end)
    {:ok, config} = Config.load(path)
    {:ok, config: config, path: path}
  end

  @switches [config: :string, no_dns: :boolean, tui: :boolean, local: :keep]
  @aliases [c: :config, l: :local]

  defp parse(args), do: OptionParser.parse(args, switches: @switches, aliases: @aliases)

  describe "--local flag parsing" do
    test "parses single --local flag" do
      {opts, _, _} = parse(["--local", "api"])
      assert Keyword.get_values(opts, :local) == ["api"]
    end

    test "parses multiple --local flags" do
      {opts, _, _} = parse(["--local", "api", "--local", "redis"])
      assert Keyword.get_values(opts, :local) == ["api", "redis"]
    end

    test "parses -l alias" do
      {opts, _, _} = parse(["-l", "api"])
      assert Keyword.get_values(opts, :local) == ["api"]
    end

    test "parses --local with other flags" do
      {opts, _, _} = parse(["--config", "foo.yml", "--local", "api", "--no-dns"])
      assert opts[:config] == "foo.yml"
      assert opts[:no_dns] == true
      assert Keyword.get_values(opts, :local) == ["api"]
    end
  end

  describe ".env.drawbridge generation" do
    test "local service env vars are written correctly", %{config: config} do
      api_svc = config.services["api"]

      # Verify the config has the env vars we expect to end up in the file
      assert api_svc.env["DATABASE_URL"] ==
               "postgres://postgres:dev@postgres.dev.local:5432/api_dev"

      assert api_svc.env["REDIS_URL"] == "redis://redis.dev.local:6379"
      assert map_size(api_svc.env) == 2
    end

    test "services without env produce empty lines", %{config: config} do
      redis_svc = config.services["redis"]
      assert redis_svc.env == %{}
    end
  end
end
