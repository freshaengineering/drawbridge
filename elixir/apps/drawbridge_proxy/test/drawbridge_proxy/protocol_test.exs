defmodule DrawbridgeProxy.ProtocolTest do
  use ExUnit.Case, async: true

  alias DrawbridgeProxy.Protocol

  describe "detect_all/1" do
    test "detects HTTP/1.1" do
      assert {:ok, %{protocol: :http1}} =
               Protocol.detect_all("GET / HTTP/1.1\r\nHost: localhost\r\n\r\n")
    end

    test "detects Postgres startup" do
      params = "user\0pg\0\0"
      length = 4 + 4 + byte_size(params)
      data = <<length::32, 196_608::32, params::binary>>
      assert {:ok, %{protocol: :postgres}} = Protocol.detect_all(data)
    end

    test "detects Redis RESP" do
      assert {:ok, %{protocol: :redis}} =
               Protocol.detect_all("*1\r\n$4\r\nPING\r\n")
    end

    test "detects Kafka wire protocol" do
      client_id = "test"
      client_id_len = byte_size(client_id)
      header = <<18::16, 0::16, 1::32, client_id_len::16, client_id::binary>>
      length = byte_size(header)
      data = <<length::32, header::binary>>

      assert {:ok, %{protocol: :kafka}} = Protocol.detect_all(data)
    end

    test "returns :unknown for garbage data" do
      assert :unknown = Protocol.detect_all(<<0xFF, 0xFE, 0xFD, 0xFC, 0xFB>>)
    end

    test "returns :unknown for empty binary" do
      assert :unknown = Protocol.detect_all(<<>>)
    end
  end
end
