defmodule DrawbridgeProxy.Protocol do
  @moduledoc """
  Behaviour for L7 protocol detection.

  Each parser inspects the first chunk of a client->backend connection and
  extracts protocol metadata without breaking transparent proxying.
  """

  @type metadata :: %{protocol: atom(), details: map()}

  @callback detect(binary()) :: {:ok, metadata()} | :unknown

  @parsers [
    DrawbridgeProxy.Protocol.Http1,
    DrawbridgeProxy.Protocol.Postgres,
    DrawbridgeProxy.Protocol.Redis,
    DrawbridgeProxy.Protocol.Kafka
  ]

  @doc """
  Try each registered parser in order. Returns the first match or `:unknown`.
  """
  @spec detect_all(binary()) :: {:ok, metadata()} | :unknown
  def detect_all(data) when is_binary(data) do
    Enum.find_value(@parsers, :unknown, fn parser ->
      case parser.detect(data) do
        {:ok, _meta} = hit -> hit
        :unknown -> nil
      end
    end)
  end
end
