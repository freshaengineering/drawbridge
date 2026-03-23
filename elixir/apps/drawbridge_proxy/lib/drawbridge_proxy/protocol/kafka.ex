defmodule DrawbridgeProxy.Protocol.Kafka do
  @moduledoc """
  Kafka wire protocol parser.

  Detects Kafka request headers and extracts api_key, api_version,
  correlation_id, and client_id. Maps api_key to a human-readable
  operation name.
  """

  @behaviour DrawbridgeProxy.Protocol

  @api_keys %{
    0 => :produce,
    1 => :fetch,
    2 => :list_offsets,
    3 => :metadata,
    4 => :leader_and_isr,
    5 => :stop_replica,
    6 => :update_metadata,
    7 => :controlled_shutdown,
    8 => :offset_commit,
    9 => :offset_fetch,
    10 => :find_coordinator,
    11 => :join_group,
    12 => :heartbeat,
    13 => :leave_group,
    14 => :sync_group,
    15 => :describe_groups,
    16 => :list_groups,
    17 => :sasl_handshake,
    18 => :api_versions,
    19 => :create_topics,
    20 => :delete_topics
  }

  # Postgres v3.0 startup magic — reject so we don't false-positive on Postgres.
  # Postgres startup: <<len::32, 0x00030000::32, ...>> which overlaps Kafka framing.
  @postgres_version_magic 196_608

  @impl true
  def detect(<<_length::32, @postgres_version_magic::32, _rest::binary>>), do: :unknown

  def detect(
        <<length::32, api_key::16, api_version::16, correlation_id::32, client_id_len::16,
          rest::binary>>
      )
      when length > 0 and api_key >= 0 and api_key <= 74 and api_version >= 0 and
             client_id_len >= 0 do
    # Sanity check: stated length should roughly match available data
    # (length field covers everything after itself)
    expected_min = 2 + 2 + 4 + 2 + client_id_len

    if length >= expected_min and client_id_len <= byte_size(rest) do
      <<client_id::binary-size(client_id_len), _::binary>> = rest
      operation = Map.get(@api_keys, api_key, :unknown)

      {:ok,
       %{
         protocol: :kafka,
         details: %{
           api_key: api_key,
           operation: operation,
           api_version: api_version,
           correlation_id: correlation_id,
           client_id: client_id
         }
       }}
    else
      :unknown
    end
  end

  def detect(_), do: :unknown
end
