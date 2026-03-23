defmodule DrawbridgeCore.ConfigTest do
  use ExUnit.Case, async: true

  alias DrawbridgeCore.Config
  alias DrawbridgeCore.Config.Service

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
      idle_timeout: 900

    redis:
      image: redis:7
      hostname: redis.dev.local
      ports:
        - "6379:6379"
  """

  setup do
    tmp = System.tmp_dir!()
    path = Path.join(tmp, "drawbridge_test_#{:rand.uniform(100_000)}.yml")
    on_exit(fn -> File.rm(path) end)
    {:ok, path: path}
  end

  defp write_yaml(path, content) do
    File.write!(path, content)
  end

  test "parses valid config", %{path: path} do
    write_yaml(path, @valid_yaml)
    assert {:ok, %Config{} = config} = Config.load(path)
    assert config.domain == "dev.local"
    assert config.idle_timeout == 300
    assert config.max_containers == 8
    assert map_size(config.services) == 2

    postgres = config.services["postgres"]
    assert %Service{} = postgres
    assert postgres.name == "postgres"
    assert postgres.image == "postgres:16"
    assert postgres.hostname == "postgres.dev.local"
    assert postgres.ports == [{5432, 5432}]
    assert postgres.env == %{"POSTGRES_PASSWORD" => "dev"}
    assert postgres.idle_timeout == 900
  end

  test "inherits global idle_timeout when service does not override", %{path: path} do
    write_yaml(path, @valid_yaml)
    {:ok, config} = Config.load(path)
    redis = config.services["redis"]
    assert redis.idle_timeout == 300
  end

  test "defaults: boot_timeout 30, tls_backend false, depends_on []", %{path: path} do
    write_yaml(path, @valid_yaml)
    {:ok, config} = Config.load(path)
    svc = config.services["redis"]
    assert svc.boot_timeout == 30
    assert svc.tls_backend == false
    assert svc.depends_on == []
  end

  test "parses port strings into tuples", %{path: path} do
    yaml = """
    domain: test.local
    services:
      app:
        image: app:latest
        hostname: app.test.local
        ports:
          - "8080:80"
          - "9443:443"
    """

    write_yaml(path, yaml)
    {:ok, config} = Config.load(path)
    assert config.services["app"].ports == [{8080, 80}, {9443, 443}]
  end

  test "fails on duplicate hostnames", %{path: path} do
    yaml = """
    domain: test.local
    services:
      a:
        image: a:1
        hostname: same.test.local
        ports:
          - "8080:80"
      b:
        image: b:1
        hostname: same.test.local
        ports:
          - "9090:90"
    """

    write_yaml(path, yaml)
    assert {:error, msg} = Config.load(path)
    assert msg =~ "duplicate hostnames"
  end

  test "fails on duplicate host ports", %{path: path} do
    yaml = """
    domain: test.local
    services:
      a:
        image: a:1
        hostname: a.test.local
        ports:
          - "8080:80"
      b:
        image: b:1
        hostname: b.test.local
        ports:
          - "8080:90"
    """

    write_yaml(path, yaml)
    assert {:error, msg} = Config.load(path)
    assert msg =~ "duplicate host ports"
  end

  test "fails on out-of-range ports", %{path: path} do
    yaml = """
    domain: test.local
    services:
      a:
        image: a:1
        hostname: a.test.local
        ports:
          - "99999:80"
    """

    write_yaml(path, yaml)
    assert {:error, _} = Config.load(path)
  end

  test "load! raises on invalid config", %{path: path} do
    write_yaml(path, "not: valid: yaml: at all: [")
    assert_raise RuntimeError, fn -> Config.load!(path) end
  end

  test "load! returns config on valid input", %{path: path} do
    write_yaml(path, @valid_yaml)
    config = Config.load!(path)
    assert %Config{} = config
  end

  test "missing file returns error" do
    assert {:error, _} = Config.load("/tmp/nonexistent_drawbridge_#{:rand.uniform()}.yml")
  end

  test "parses database field for Postgres routing", %{path: path} do
    yaml = """
    domain: test.local
    services:
      pg:
        image: postgres:16
        hostname: pg.test.local
        ports:
          - "5432:5432"
        database: myapp_dev
    """

    write_yaml(path, yaml)
    {:ok, config} = Config.load(path)
    assert config.services["pg"].database == "myapp_dev"
  end

  test "database defaults to nil when not set", %{path: path} do
    write_yaml(path, @valid_yaml)
    {:ok, config} = Config.load(path)
    assert config.services["postgres"].database == nil
  end

  test "allows duplicate host ports when services use different database names", %{path: path} do
    yaml = """
    domain: test.local
    services:
      pg_users:
        image: postgres:16
        hostname: pg1.test.local
        ports:
          - "5432:5432"
        database: users_dev
      pg_platform:
        image: postgres:16
        hostname: pg2.test.local
        ports:
          - "5432:5432"
        database: platform_dev
    """

    write_yaml(path, yaml)
    assert {:ok, config} = Config.load(path)
    assert config.services["pg_users"].database == "users_dev"
    assert config.services["pg_platform"].database == "platform_dev"
  end

  test "rejects duplicate database names", %{path: path} do
    yaml = """
    domain: test.local
    services:
      pg1:
        image: postgres:16
        hostname: pg1.test.local
        ports:
          - "5432:5432"
        database: same_db
      pg2:
        image: postgres:16
        hostname: pg2.test.local
        ports:
          - "5432:5432"
        database: same_db
    """

    write_yaml(path, yaml)
    assert {:error, msg} = Config.load(path)
    assert msg =~ "duplicate database"
  end

  test "rejects database-routed and plain services sharing a port", %{path: path} do
    yaml = """
    domain: test.local
    services:
      pg_db:
        image: postgres:16
        hostname: pg1.test.local
        ports:
          - "5432:5432"
        database: mydb
      pg_plain:
        image: postgres:16
        hostname: pg2.test.local
        ports:
          - "5432:5432"
    """

    write_yaml(path, yaml)
    assert {:error, msg} = Config.load(path)
    assert msg =~ "database-routed and plain"
  end
end
