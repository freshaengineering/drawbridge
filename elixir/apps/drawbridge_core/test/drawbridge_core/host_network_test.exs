defmodule DrawbridgeCore.HostNetworkTest do
  use ExUnit.Case, async: false

  alias DrawbridgeCore.HostNetwork

  # Clear cached gateway between tests so each test gets a clean slate.
  # Seed a known gateway so resolve_env tests don't shell out to `container` CLI.
  setup do
    :persistent_term.erase(:drawbridge_host_gateway_ip)
    :persistent_term.put(:drawbridge_host_gateway_ip, "192.168.64.1")

    on_exit(fn ->
      :persistent_term.erase(:drawbridge_host_gateway_ip)
      Application.delete_env(:drawbridge_core, :host_network_cmd_runner)
    end)

    :ok
  end

  describe "resolve_env_for_container/2" do
    test "replaces single hostname" do
      env = %{"DATABASE_URL" => "postgres://u:p@postgres.dev.local:5432/db"}

      result = HostNetwork.resolve_env_for_container(env)

      assert result["DATABASE_URL"] == "postgres://u:p@192.168.64.1:5432/db"
    end

    test "replaces multiple hostnames in a single value" do
      env = %{
        "CONN" => "redis://cache.dev.local:6379,sentinel://sentinel.dev.local:26379"
      }

      result = HostNetwork.resolve_env_for_container(env)

      assert result["CONN"] ==
               "redis://192.168.64.1:6379,sentinel://192.168.64.1:26379"
    end

    test "replaces hostnames across multiple keys" do
      env = %{
        "PG" => "postgres.dev.local",
        "REDIS" => "redis.dev.local",
        "PLAIN" => "no-match-here"
      }

      result = HostNetwork.resolve_env_for_container(env)

      assert result["PG"] == "192.168.64.1"
      assert result["REDIS"] == "192.168.64.1"
      assert result["PLAIN"] == "no-match-here"
    end

    test "leaves values without matching hostnames untouched" do
      env = %{"FOO" => "bar", "NUM" => "42"}

      assert HostNetwork.resolve_env_for_container(env) == env
    end

    test "handles custom domain" do
      env = %{"URL" => "http://app.mylocal:3000/api"}

      result = HostNetwork.resolve_env_for_container(env, "mylocal")

      assert result["URL"] == "http://192.168.64.1:3000/api"
    end

    test "returns empty map unchanged" do
      assert HostNetwork.resolve_env_for_container(%{}) == %{}
    end

    test "does not match bare domain (no subdomain prefix)" do
      env = %{"HOST" => "dev.local"}

      # "dev.local" has no subdomain prefix, so should NOT be replaced
      assert HostNetwork.resolve_env_for_container(env) == env
    end
  end

  describe "host_gateway_ip/0" do
    # These tests need a cold cache to exercise discovery.
    setup do
      :persistent_term.erase(:drawbridge_host_gateway_ip)
      :ok
    end

    test "returns discovered gateway from container CLI" do
      json = Jason.encode!(%{"ipv4Gateway" => "10.0.0.1"})
      Application.put_env(:drawbridge_core, :host_network_cmd_runner, fn _, _ -> {json, 0} end)

      assert HostNetwork.host_gateway_ip() == "10.0.0.1"
    end

    test "falls back to default on CLI failure" do
      Application.put_env(:drawbridge_core, :host_network_cmd_runner, fn _, _ -> {"error", 1} end)

      assert HostNetwork.host_gateway_ip() == "192.168.64.1"
    end

    test "falls back to default on bad JSON" do
      Application.put_env(:drawbridge_core, :host_network_cmd_runner, fn _, _ ->
        {"not json", 0}
      end)

      assert HostNetwork.host_gateway_ip() == "192.168.64.1"
    end

    test "caches result in persistent_term" do
      call_count = :counters.new(1, [:atomics])

      Application.put_env(:drawbridge_core, :host_network_cmd_runner, fn _, _ ->
        :counters.add(call_count, 1, 1)
        {Jason.encode!(%{"ipv4Gateway" => "10.0.0.1"}), 0}
      end)

      assert HostNetwork.host_gateway_ip() == "10.0.0.1"
      assert HostNetwork.host_gateway_ip() == "10.0.0.1"
      assert :counters.get(call_count, 1) == 1
    end
  end
end
