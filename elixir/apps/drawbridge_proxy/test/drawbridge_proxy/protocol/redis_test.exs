defmodule DrawbridgeProxy.Protocol.RedisTest do
  use ExUnit.Case, async: true

  alias DrawbridgeProxy.Protocol.Redis

  describe "detect/1" do
    test "detects PING command" do
      data = "*1\r\n$4\r\nPING\r\n"

      assert {:ok, %{protocol: :redis, details: details}} = Redis.detect(data)
      assert details.command == "PING"
      assert details.args == []
    end

    test "detects SET command with key and value" do
      data = "*3\r\n$3\r\nSET\r\n$5\r\nmykey\r\n$7\r\nmyvalue\r\n"

      assert {:ok, %{protocol: :redis, details: details}} = Redis.detect(data)
      assert details.command == "SET"
      assert details.args == ["mykey", "myvalue"]
    end

    test "detects GET command" do
      data = "*2\r\n$3\r\nGET\r\n$5\r\nmykey\r\n"

      assert {:ok, %{protocol: :redis, details: details}} = Redis.detect(data)
      assert details.command == "GET"
      assert details.args == ["mykey"]
    end

    test "detects AUTH command" do
      data = "*2\r\n$4\r\nAUTH\r\n$8\r\npassword\r\n"

      assert {:ok, %{protocol: :redis, details: details}} = Redis.detect(data)
      assert details.command == "AUTH"
    end

    test "returns :unknown for non-RESP data" do
      assert :unknown = Redis.detect("hello world")
    end

    test "returns :unknown for empty binary" do
      assert :unknown = Redis.detect(<<>>)
    end

    test "returns :unknown for malformed RESP" do
      assert :unknown = Redis.detect("*abc\r\n")
    end
  end
end
