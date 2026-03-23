defmodule DrawbridgeProxy.Protocol.PostgresTest do
  use ExUnit.Case, async: true

  alias DrawbridgeProxy.Protocol.Postgres

  describe "detect/1" do
    test "detects v3.0 startup message with user and database" do
      # Build a real Postgres startup message:
      # length(4) + version(4) + "user\0postgres\0database\0mydb\0\0"
      params = "user\0postgres\0database\0mydb\0\0"
      length = 4 + 4 + byte_size(params)
      data = <<length::32, 196_608::32, params::binary>>

      assert {:ok, %{protocol: :postgres, details: details}} = Postgres.detect(data)
      assert details.user == "postgres"
      assert details.database == "mydb"
    end

    test "detects startup with extra params" do
      params = "user\0admin\0database\0app_dev\0application_name\0psql\0\0"
      length = 4 + 4 + byte_size(params)
      data = <<length::32, 196_608::32, params::binary>>

      assert {:ok, %{protocol: :postgres, details: details}} = Postgres.detect(data)
      assert details.user == "admin"
      assert details.database == "app_dev"
      assert details.params["application_name"] == "psql"
    end

    test "detects SSL request" do
      # SSLRequest: length=8, code=80877103
      data = <<8::32, 80_877_103::32>>

      assert {:ok, %{protocol: :postgres, details: %{ssl_request: true}}} = Postgres.detect(data)
    end

    test "returns :unknown for non-Postgres data" do
      assert :unknown = Postgres.detect("GET / HTTP/1.1\r\n\r\n")
    end

    test "returns :unknown for empty binary" do
      assert :unknown = Postgres.detect(<<>>)
    end

    test "returns :unknown for too-short binary" do
      assert :unknown = Postgres.detect(<<0, 0, 0>>)
    end
  end
end
