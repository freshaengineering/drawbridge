defmodule DrawbridgeProxy.Protocol.Http1Test do
  use ExUnit.Case, async: true

  alias DrawbridgeProxy.Protocol.Http1

  describe "detect/1" do
    test "detects GET request with Host header" do
      data = "GET /api/v1/users HTTP/1.1\r\nHost: api.example.com\r\nAccept: */*\r\n\r\n"

      assert {:ok, %{protocol: :http1, details: details}} = Http1.detect(data)
      assert details.method == "GET"
      assert details.path == "/api/v1/users"
      assert details.host == "api.example.com"
    end

    test "detects POST request" do
      data =
        "POST /graphql HTTP/1.1\r\nHost: api.b2c.dev.local\r\nContent-Type: application/json\r\n\r\n{}"

      assert {:ok, %{protocol: :http1, details: details}} = Http1.detect(data)
      assert details.method == "POST"
      assert details.path == "/graphql"
      assert details.host == "api.b2c.dev.local"
    end

    test "detects PUT request" do
      data = "PUT /resource/1 HTTP/1.1\r\nHost: localhost\r\n\r\n"

      assert {:ok, %{protocol: :http1, details: %{method: "PUT", path: "/resource/1"}}} =
               Http1.detect(data)
    end

    test "detects DELETE request" do
      data = "DELETE /items/42 HTTP/1.1\r\nHost: localhost\r\n\r\n"

      assert {:ok, %{protocol: :http1, details: %{method: "DELETE"}}} = Http1.detect(data)
    end

    test "handles missing Host header" do
      data = "GET / HTTP/1.1\r\nAccept: text/html\r\n\r\n"

      assert {:ok, %{protocol: :http1, details: %{host: nil}}} = Http1.detect(data)
    end

    test "handles HTTP/1.0" do
      data = "GET / HTTP/1.0\r\n\r\n"

      assert {:ok, %{protocol: :http1, details: %{method: "GET"}}} = Http1.detect(data)
    end

    test "returns :unknown for non-HTTP data" do
      assert :unknown = Http1.detect(<<0, 1, 2, 3, 4>>)
    end

    test "returns :unknown for empty binary" do
      assert :unknown = Http1.detect(<<>>)
    end

    test "returns :unknown for HTTP/2 preface" do
      assert :unknown = Http1.detect("PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n")
    end
  end
end
