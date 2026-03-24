defmodule DrawbridgeProxy.Protocol.Http2 do
  @moduledoc """
  HTTP/2 frame parser for extracting `:authority` from gRPC HEADERS.

  Uses HPAX for HPACK decoding (handles Huffman encoding, indexed headers, etc.)
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
      decode_headers_and_find_authority(payload)
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

  defp decode_headers_and_find_authority(payload) do
    decode_table = HPAX.new(4096)

    case HPAX.decode(payload, decode_table) do
      {:ok, headers, _updated_table} ->
        require Logger
        Logger.info("[Http2] HPAX decoded headers: #{inspect(headers, limit: 500)}")

        authority =
          Enum.find_value(headers, fn
            {_action, ":authority", value} -> value
            _ -> nil
          end)

        if authority do
          hostname = authority |> String.split(":") |> hd()
          {:ok, hostname}
        else
          {:error, :authority_not_found}
        end

      {:error, reason} ->
        {:error, {:hpack_decode_error, reason}}
    end
  end
end
