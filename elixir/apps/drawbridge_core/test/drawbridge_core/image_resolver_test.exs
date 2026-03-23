defmodule DrawbridgeCore.ImageResolverTest do
  use ExUnit.Case, async: true

  alias DrawbridgeCore.ImageResolver

  defp stub_runner(json, exit_code \\ 0) do
    fn _cmd, _args -> {json, exit_code} end
  end

  test "resolve/2 extracts digest from Digest field" do
    json = Jason.encode!(%{"Digest" => "sha256:abc123"})

    assert {:ok, "sha256:abc123"} =
             ImageResolver.resolve("postgres:16", cmd_runner: stub_runner(json))
  end

  test "resolve/2 extracts digest from array response" do
    json = Jason.encode!([%{"Digest" => "sha256:deadbeef"}])

    assert {:ok, "sha256:deadbeef"} =
             ImageResolver.resolve("redis:7", cmd_runner: stub_runner(json))
  end

  test "resolve/2 extracts digest from RepoDigests" do
    json = Jason.encode!(%{"RepoDigests" => ["postgres@sha256:cafe"]})

    assert {:ok, "sha256:cafe"} =
             ImageResolver.resolve("postgres:16", cmd_runner: stub_runner(json))
  end

  test "resolve/2 extracts digest from RepoDigests in array" do
    json = Jason.encode!([%{"RepoDigests" => ["redis@sha256:babe"]}])
    assert {:ok, "sha256:babe"} = ImageResolver.resolve("redis:7", cmd_runner: stub_runner(json))
  end

  test "resolve/2 returns error on non-zero exit" do
    runner = stub_runner("Error: image not found", 1)
    assert {:error, msg} = ImageResolver.resolve("nope:latest", cmd_runner: runner)
    assert msg =~ "exited 1"
  end

  test "resolve/2 returns error on missing digest" do
    json = Jason.encode!(%{"Config" => %{}})
    assert {:error, msg} = ImageResolver.resolve("img:tag", cmd_runner: stub_runner(json))
    assert msg =~ "no digest found"
  end

  test "resolve/2 returns error on invalid JSON" do
    assert {:error, msg} = ImageResolver.resolve("img:tag", cmd_runner: stub_runner("not json"))
    assert msg =~ "failed to parse"
  end

  test "pull_and_resolve/2 pulls then resolves" do
    call_log = :ets.new(:pull_calls, [:set, :public])
    :ets.insert(call_log, {:count, 0})

    runner = fn _cmd, args ->
      [{:count, n}] = :ets.lookup(call_log, :count)
      :ets.insert(call_log, {:count, n + 1})

      case List.first(args) do
        "image" ->
          case Enum.at(args, 1) do
            "pull" -> {"Pulled", 0}
            "inspect" -> {Jason.encode!(%{"Digest" => "sha256:pulled"}), 0}
          end
      end
    end

    assert {:ok, "sha256:pulled"} = ImageResolver.pull_and_resolve("img:tag", cmd_runner: runner)
    [{:count, n}] = :ets.lookup(call_log, :count)
    assert n == 2
    :ets.delete(call_log)
  end

  test "pull_and_resolve/2 returns error when pull fails" do
    runner = fn _cmd, _args -> {"pull failed", 1} end
    assert {:error, msg} = ImageResolver.pull_and_resolve("img:tag", cmd_runner: runner)
    assert msg =~ "pull exited 1"
  end
end
