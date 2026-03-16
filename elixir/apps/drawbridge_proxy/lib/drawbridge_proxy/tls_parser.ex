defmodule DrawbridgeProxy.TlsParser do
  @moduledoc """
  Parses TLS ClientHello messages to extract the SNI hostname.

  We operate on raw TCP bytes BEFORE the TLS handshake, so we can route
  to the right backend without terminating TLS ourselves. The full
  ClientHello is then forwarded verbatim to the backend.

  Supports TLS 1.0–1.3 ClientHello format. Returns {:error, :incomplete}
  when we need more bytes (caller should buffer and retry).
  """

  # TLS content type 22 = Handshake
  @handshake_content_type 22
  # Handshake type 1 = ClientHello
  @client_hello_type 1
  # Extension type 0 = server_name
  @sni_ext_type 0x0000
  # ServerName type 0 = host_name
  @host_name_type 0

  @spec parse_client_hello(binary()) :: {:ok, String.t()} | {:error, atom()}
  def parse_client_hello(data)

  # Well-formed TLS record header with enough data buffered
  def parse_client_hello(<<
        @handshake_content_type,
        _major,
        _minor,
        rec_length::16,
        rest::binary
      >>)
      when byte_size(rest) >= rec_length do
    <<record::binary-size(rec_length), _::binary>> = rest
    parse_handshake(record)
  end

  # TLS record header present but not enough body yet
  def parse_client_hello(<<@handshake_content_type, _::binary>>), do: {:error, :incomplete}

  # Not a TLS handshake record at all
  def parse_client_hello(_), do: {:error, :not_tls}

  # ---- Handshake layer ----

  defp parse_handshake(<<@client_hello_type, hs_length::24, rest::binary>>)
       when byte_size(rest) >= hs_length do
    <<hello::binary-size(hs_length), _::binary>> = rest
    parse_hello_body(hello)
  end

  defp parse_handshake(<<@client_hello_type, _::24, _::binary>>), do: {:error, :incomplete}
  defp parse_handshake(_), do: {:error, :not_client_hello}

  # ---- ClientHello body ----
  # Layout: client_version(2) + random(32) + session_id_len(1) + session_id(N)
  #         + cipher_suites_len(2) + cipher_suites(N)
  #         + compression_len(1) + compression(N)
  #         + extensions_len(2) + extensions(N)

  defp parse_hello_body(<<
         _client_version::16,
         _random::binary-size(32),
         session_id_len,
         _session_id::binary-size(session_id_len),
         cipher_suites_len::16,
         _cipher_suites::binary-size(cipher_suites_len),
         compression_len,
         _compression::binary-size(compression_len),
         rest::binary
       >>) do
    case rest do
      <<_extensions_len::16, extensions::binary>> -> find_sni(extensions)
      _ -> {:error, :no_extensions}
    end
  end

  defp parse_hello_body(_), do: {:error, :malformed_hello}

  # ---- Extensions ----

  defp find_sni(<<>>), do: {:error, :no_sni}

  defp find_sni(<<@sni_ext_type::16, ext_len::16, ext_data::binary-size(ext_len), rest::binary>>) do
    case parse_sni_ext(ext_data) do
      {:ok, _} = ok -> ok
      _ -> find_sni(rest)
    end
  end

  defp find_sni(<<_type::16, ext_len::16, _data::binary-size(ext_len), rest::binary>>) do
    find_sni(rest)
  end

  defp find_sni(_), do: {:error, :malformed_extensions}

  # SNI extension data: server_name_list_len(2) + entries...
  # Each entry: name_type(1) + name_len(2) + name(N)
  defp parse_sni_ext(<<_list_len::16, @host_name_type, name_len::16, hostname::binary-size(name_len), _::binary>>) do
    if name_len > 0 do
      {:ok, hostname}
    else
      {:error, :empty_hostname}
    end
  end

  defp parse_sni_ext(_), do: {:error, :malformed_sni}
end
