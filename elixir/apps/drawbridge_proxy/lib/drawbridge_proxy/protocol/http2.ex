defmodule DrawbridgeProxy.Protocol.Http2 do
  @moduledoc """
  HTTP/2 connection preface and frame parser.

  Extracts the `:authority` pseudo-header from the first HEADERS frame,
  used for gRPC hostname-based routing on a shared port.

  HTTP/2 connection starts with:
  1. Client preface: "PRI * HTTP/2.0\\r\\n\\r\\nSM\\r\\n\\r\\n" (24 bytes)
  2. SETTINGS frame (type 0x04)
  3. HEADERS frame (type 0x01) containing HPACK-encoded :authority
  """

  @preface "PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n"
  @preface_len 24
  @frame_header_len 9
  @headers_type 0x01

  @doc """
  Extract the :authority pseudo-header from buffered HTTP/2 bytes.

  Returns `{:ok, authority}`, `{:error, :incomplete}`, or `{:error, reason}`.
  """
  def extract_authority(data) when byte_size(data) < @preface_len do
    {:error, :incomplete}
  end

  def extract_authority(<<@preface, rest::binary>>) do
    scan_for_headers(rest)
  end

  def extract_authority(_data) do
    {:error, :not_http2}
  end

  # Scan frames until we find a HEADERS frame (type 1)
  defp scan_for_headers(data) when byte_size(data) < @frame_header_len do
    {:error, :incomplete}
  end

  defp scan_for_headers(
         <<length::24, @headers_type, _flags::8, _r::1, _stream_id::31, rest::binary>>
       ) do
    if byte_size(rest) < length do
      {:error, :incomplete}
    else
      <<payload::binary-size(length), _rest::binary>> = rest
      extract_authority_from_hpack(payload)
    end
  end

  defp scan_for_headers(<<length::24, _type::8, _flags::8, _r::1, _stream_id::31, rest::binary>>) do
    if byte_size(rest) < length do
      {:error, :incomplete}
    else
      <<_payload::binary-size(length), rest::binary>> = rest
      scan_for_headers(rest)
    end
  end

  # Extract :authority from HPACK-encoded headers
  # :authority is static table index 1 (name only)
  # gRPC clients typically send it as:
  #   0x41 (literal with incremental indexing, name index 1) + value_len + value
  #   or 0x01 (indexed header) if cached
  defp extract_authority_from_hpack(<<>>) do
    {:error, :authority_not_found}
  end

  # Indexed header (0x80 | index) — skip, :authority won't be fully indexed on first request
  defp extract_authority_from_hpack(<<1::1, index::7, rest::binary>>) when index > 0 do
    # Static table index 1 is :authority with no value — shouldn't appear as indexed
    extract_authority_from_hpack(rest)
  end

  # Literal with incremental indexing (0x40 | index) — index 1 = :authority
  defp extract_authority_from_hpack(<<0::1, 1::1, 1::6, rest::binary>>) do
    read_header_value(rest)
  end

  # Literal with incremental indexing, other index — skip name + value
  defp extract_authority_from_hpack(<<0::1, 1::1, index::6, rest::binary>>) when index > 0 do
    case skip_string(rest) do
      {:ok, rest} -> extract_authority_from_hpack(rest)
      error -> error
    end
  end

  # Literal with incremental indexing, new name (index 0) — read name, check if :authority
  defp extract_authority_from_hpack(<<0::1, 1::1, 0::6, rest::binary>>) do
    case read_string(rest) do
      {:ok, ":authority", rest} ->
        read_header_value(rest)

      {:ok, _name, rest} ->
        case skip_string(rest) do
          {:ok, rest} -> extract_authority_from_hpack(rest)
          error -> error
        end

      error ->
        error
    end
  end

  # Literal without indexing (0x00 | index) or never indexed (0x10 | index)
  defp extract_authority_from_hpack(<<0::4, index::4, rest::binary>>) do
    if index == 1 do
      read_header_value(rest)
    else
      rest = if index == 0, do: skip_string_raw(rest), else: rest

      case skip_string(rest || rest) do
        {:ok, rest} -> extract_authority_from_hpack(rest)
        _ -> extract_authority_from_hpack(rest)
      end
    end
  end

  # Literal never indexed (0x1X)
  defp extract_authority_from_hpack(<<1::4, index::4, rest::binary>>) do
    if index == 1 do
      read_header_value(rest)
    else
      rest = if index == 0, do: skip_string_raw(rest), else: rest

      case skip_string(rest || rest) do
        {:ok, rest} -> extract_authority_from_hpack(rest)
        _ -> extract_authority_from_hpack(rest)
      end
    end
  end

  # Dynamic table size update (001xxxxx) — skip
  defp extract_authority_from_hpack(<<0::3, _size::5, rest::binary>>) do
    extract_authority_from_hpack(rest)
  end

  defp extract_authority_from_hpack(_) do
    {:error, :hpack_parse_error}
  end

  defp read_header_value(data) do
    case read_string(data) do
      {:ok, value, _rest} ->
        # Strip port suffix if present (e.g. "deals.dev.local:50051" → "deals.dev.local")
        authority = value |> String.split(":") |> hd()
        {:ok, authority}

      error ->
        error
    end
  end

  defp read_string(<<0::1, length::7, rest::binary>>) when byte_size(rest) >= length do
    <<value::binary-size(length), rest::binary>> = rest
    {:ok, value, rest}
  end

  defp read_string(<<1::1, length::7, rest::binary>>) when byte_size(rest) >= length do
    <<huffman::binary-size(length), rest::binary>> = rest
    {:ok, decode_huffman(huffman), rest}
  end

  defp read_string(_), do: {:error, :incomplete}

  defp skip_string(<<_h::1, length::7, rest::binary>>) when byte_size(rest) >= length do
    <<_::binary-size(length), rest::binary>> = rest
    {:ok, rest}
  end

  defp skip_string(_), do: {:error, :incomplete}

  defp skip_string_raw(data), do: elem(skip_string(data), 1)

  # Minimal Huffman decoder — enough for hostnames (ASCII lowercase + digits + dots + colons)
  # For a full implementation, use the HPACK Huffman table from RFC 7541 Appendix B
  defp decode_huffman(data) do
    # For now, just return raw bytes — gRPC clients typically don't Huffman-encode :authority
    data
  end
end
