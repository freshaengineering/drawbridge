defmodule DrawbridgeProxy.Protocol.Postgres do
  @moduledoc """
  Postgres wire protocol startup message parser.

  Detects protocol version 3.0 startup messages and extracts user/database
  from the key-value pairs.
  """

  @behaviour DrawbridgeProxy.Protocol

  # Protocol version 3.0 = 196608 (0x00030000)
  @version_3_0 196_608

  @impl true
  def detect(<<len::32, @version_3_0::32, rest::binary>>) when len > 8 do
    payload_len = len - 8
    available = byte_size(rest)

    payload =
      if available >= payload_len,
        do: binary_part(rest, 0, payload_len),
        else: rest

    params = parse_params(payload, %{})

    {:ok,
     %{
       protocol: :postgres,
       details: %{
         user: Map.get(params, "user"),
         database: Map.get(params, "database"),
         params: params
       }
     }}
  rescue
    _ -> :unknown
  end

  def detect(<<_len::32, 80_877_103::32, _rest::binary>>) do
    # SSLRequest (80877103) — client wants to upgrade to TLS
    {:ok, %{protocol: :postgres, details: %{ssl_request: true}}}
  end

  def detect(_), do: :unknown

  defp parse_params(<<0, _rest::binary>>, acc), do: acc
  defp parse_params(<<>>, acc), do: acc

  defp parse_params(data, acc) do
    case extract_null_terminated(data) do
      {key, rest} when key != "" ->
        case extract_null_terminated(rest) do
          {value, rest2} -> parse_params(rest2, Map.put(acc, key, value))
          :incomplete -> acc
        end

      _ ->
        acc
    end
  end

  defp extract_null_terminated(data) do
    case :binary.split(data, <<0>>) do
      [str, rest] -> {str, rest}
      _ -> :incomplete
    end
  end
end
