defmodule DrawbridgeProxy.TestHelpers do
  @moduledoc """
  Shared helpers for DrawbridgeProxy tests.
  """

  @doc """
  Builds a minimal TLS 1.2 ClientHello binary with an SNI extension
  for the given hostname.
  """
  def client_hello(hostname) do
    name_len = byte_size(hostname)
    sni_body = <<name_len + 3::16, 0::8, name_len::16>> <> hostname
    sni_ext = <<0x00, 0x00, byte_size(sni_body)::16>> <> sni_body
    extensions = <<byte_size(sni_ext)::16>> <> sni_ext

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
end
