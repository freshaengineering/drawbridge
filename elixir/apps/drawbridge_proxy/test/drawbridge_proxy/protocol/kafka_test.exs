defmodule DrawbridgeProxy.Protocol.KafkaTest do
  use ExUnit.Case, async: true

  alias DrawbridgeProxy.Protocol.Kafka

  describe "detect/1" do
    test "detects ApiVersions request (api_key=18)" do
      client_id = "kafka-client"
      client_id_len = byte_size(client_id)
      # header: api_key(2) + api_version(2) + correlation_id(4) + client_id_len(2) + client_id
      header = <<18::16, 0::16, 1::32, client_id_len::16, client_id::binary>>
      length = byte_size(header)
      data = <<length::32, header::binary>>

      assert {:ok, %{protocol: :kafka, details: details}} = Kafka.detect(data)
      assert details.api_key == 18
      assert details.operation == :api_versions
      assert details.api_version == 0
      assert details.correlation_id == 1
      assert details.client_id == "kafka-client"
    end

    test "detects Produce request (api_key=0)" do
      client_id = "producer-1"
      client_id_len = byte_size(client_id)
      header = <<0::16, 3::16, 42::32, client_id_len::16, client_id::binary>>
      length = byte_size(header)
      data = <<length::32, header::binary>>

      assert {:ok, %{protocol: :kafka, details: details}} = Kafka.detect(data)
      assert details.operation == :produce
      assert details.api_version == 3
    end

    test "detects Fetch request (api_key=1)" do
      client_id = "consumer-1"
      client_id_len = byte_size(client_id)
      header = <<1::16, 11::16, 100::32, client_id_len::16, client_id::binary>>
      length = byte_size(header)
      data = <<length::32, header::binary>>

      assert {:ok, %{protocol: :kafka, details: details}} = Kafka.detect(data)
      assert details.operation == :fetch
    end

    test "detects Metadata request (api_key=3)" do
      client_id = "admin"
      client_id_len = byte_size(client_id)
      header = <<3::16, 1::16, 7::32, client_id_len::16, client_id::binary>>
      length = byte_size(header)
      data = <<length::32, header::binary>>

      assert {:ok, %{protocol: :kafka, details: details}} = Kafka.detect(data)
      assert details.operation == :metadata
    end

    test "returns :unknown for non-Kafka data" do
      assert :unknown = Kafka.detect("GET / HTTP/1.1\r\n\r\n")
    end

    test "returns :unknown for empty binary" do
      assert :unknown = Kafka.detect(<<>>)
    end

    test "returns :unknown for too-short binary" do
      assert :unknown = Kafka.detect(<<0, 0, 0, 1>>)
    end
  end
end
