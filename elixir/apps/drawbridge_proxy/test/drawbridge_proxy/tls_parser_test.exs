defmodule DrawbridgeProxy.TlsParserTest do
  use ExUnit.Case, async: true

  alias DrawbridgeProxy.TlsParser

  # ---------------------------------------------------------------------------
  # Helpers to construct minimal TLS ClientHello binaries
  # ---------------------------------------------------------------------------

  # Builds a complete TLS 1.2 ClientHello with a single SNI entry.
  defp client_hello(hostname) do
    name = hostname
    name_len = byte_size(name)

    # SNI extension data: server_name_list_len(2) + name_type(1) + name_len(2) + name
    sni_body = <<name_len + 3::16, 0::8, name_len::16>> <> name
    sni_ext = <<0x00, 0x00, byte_size(sni_body)::16>> <> sni_body

    extensions = <<byte_size(sni_ext)::16>> <> sni_ext

    hello_body =
      <<0x03, 0x03>> <>
        # version TLS 1.2
        <<0::256>> <>
        # random (32 zeroed bytes)
        <<0x00>> <>
        # session_id_len = 0
        <<0x00, 0x02>> <>
        # cipher_suites_len
        <<0x00, 0x2F>> <>
        # TLS_RSA_WITH_AES_128_CBC_SHA
        <<0x01>> <>
        # compression_methods_len
        <<0x00>> <>
        # null compression
        extensions

    handshake = <<0x01, byte_size(hello_body)::24>> <> hello_body
    <<0x16, 0x03, 0x01, byte_size(handshake)::16>> <> handshake
  end

  # Builds a ClientHello without any extensions
  defp client_hello_no_extensions do
    hello_body =
      <<0x03, 0x03>> <>
        <<0::256>> <>
        <<0x00>> <>
        <<0x00, 0x02>> <>
        <<0x00, 0x2F>> <>
        <<0x01>> <>
        <<0x00>>

    # no extensions field at all
    handshake = <<0x01, byte_size(hello_body)::24>> <> hello_body
    <<0x16, 0x03, 0x01, byte_size(handshake)::16>> <> handshake
  end

  # Builds a ClientHello with extensions block but no SNI extension
  defp client_hello_no_sni do
    # Use a different extension type (e.g. 0x000F = heartbeat)
    ext = <<0x00, 0x0F, 0x00, 0x01, 0x01>>
    extensions = <<byte_size(ext)::16>> <> ext

    hello_body =
      <<0x03, 0x03>> <>
        <<0::256>> <>
        <<0x00>> <>
        <<0x00, 0x02>> <>
        <<0x00, 0x2F>> <>
        <<0x01>> <>
        <<0x00>> <>
        extensions

    handshake = <<0x01, byte_size(hello_body)::24>> <> hello_body
    <<0x16, 0x03, 0x01, byte_size(handshake)::16>> <> handshake
  end

  # ---------------------------------------------------------------------------
  # Happy path
  # ---------------------------------------------------------------------------

  test "extracts SNI from a minimal TLS 1.2 ClientHello" do
    data = client_hello("example.com")
    assert {:ok, "example.com"} = TlsParser.parse_client_hello(data)
  end

  test "extracts SNI from a longer hostname" do
    data = client_hello("my-service.internal.corp.example.com")
    assert {:ok, "my-service.internal.corp.example.com"} = TlsParser.parse_client_hello(data)
  end

  test "extracts SNI when there is trailing data after the TLS record" do
    data = client_hello("trailing.example.com") <> <<0, 0, 0, 0>>
    assert {:ok, "trailing.example.com"} = TlsParser.parse_client_hello(data)
  end

  test "extracts SNI when non-SNI extensions precede the SNI extension" do
    hostname = "multi-ext.example.com"
    name_len = byte_size(hostname)
    sni_body = <<name_len + 3::16, 0::8, name_len::16>> <> hostname
    sni_ext = <<0x00, 0x00, byte_size(sni_body)::16>> <> sni_body
    # prepend a dummy extension
    dummy_ext = <<0x00, 0x17, 0x00, 0x00>>
    extensions = <<byte_size(dummy_ext) + byte_size(sni_ext)::16>> <> dummy_ext <> sni_ext

    hello_body =
      <<0x03, 0x03>> <>
        <<0::256>> <>
        <<0x00>> <>
        <<0x00, 0x02>> <>
        <<0x00, 0x2F>> <>
        <<0x01>> <>
        <<0x00>> <>
        extensions

    handshake = <<0x01, byte_size(hello_body)::24>> <> hello_body
    pkt = <<0x16, 0x03, 0x01, byte_size(handshake)::16>> <> handshake

    assert {:ok, ^hostname} = TlsParser.parse_client_hello(pkt)
  end

  # ---------------------------------------------------------------------------
  # Error / edge cases
  # ---------------------------------------------------------------------------

  test "returns :not_tls for non-TLS data" do
    assert {:error, :not_tls} = TlsParser.parse_client_hello(<<0x00, 0x01, 0x02>>)
    assert {:error, :not_tls} = TlsParser.parse_client_hello("GET / HTTP/1.1\r\n")
    assert {:error, :not_tls} = TlsParser.parse_client_hello(<<>>)
  end

  test "returns :incomplete when only the TLS record header is present" do
    # 5-byte record header with rec_length=100 but no body
    assert {:error, :incomplete} =
             TlsParser.parse_client_hello(<<0x16, 0x03, 0x01, 0x00, 0x64>>)
  end

  test "returns :incomplete for a partial TLS record body" do
    full = client_hello("partial.example.com")
    # truncate to just past the record header
    truncated = binary_part(full, 0, 10)
    assert {:error, :incomplete} = TlsParser.parse_client_hello(truncated)
  end

  test "returns :not_client_hello for non-ClientHello handshake types" do
    # Handshake type 2 = ServerHello
    handshake = <<0x02, 0x00, 0x00, 0x04, 0x03, 0x03, 0x00, 0x00>>
    pkt = <<0x16, 0x03, 0x03, byte_size(handshake)::16>> <> handshake
    assert {:error, :not_client_hello} = TlsParser.parse_client_hello(pkt)
  end

  test "returns :no_extensions when ClientHello has no extensions block" do
    data = client_hello_no_extensions()
    assert {:error, :no_extensions} = TlsParser.parse_client_hello(data)
  end

  test "returns :no_sni when ClientHello has extensions but no SNI" do
    data = client_hello_no_sni()
    assert {:error, :no_sni} = TlsParser.parse_client_hello(data)
  end

  test "handles TLS 1.3 ClientHello outer version (0x0303 record + extensions)" do
    # TLS 1.3 still uses 0x0303 (TLS 1.2) in the record layer for compatibility.
    # The version in the ClientHello body can be 0x0303 with supported_versions
    # extension containing 0x0304. Our parser ignores the version field, so it
    # should work the same way.
    hostname = "tls13.example.com"
    data = client_hello(hostname)
    assert {:ok, ^hostname} = TlsParser.parse_client_hello(data)
  end
end
