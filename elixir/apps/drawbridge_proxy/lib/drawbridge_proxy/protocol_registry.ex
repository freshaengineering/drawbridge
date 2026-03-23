defmodule DrawbridgeProxy.ProtocolRegistry do
  @moduledoc """
  ETS-backed store for protocol metadata detected on active connections.

  Keyed by `{service_name, connection_ref}`. Stores metadata + timestamp
  for introspection by the TUI, API, or agents.
  """

  use GenServer

  @table __MODULE__

  # -- Public API --

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Store protocol metadata for a connection."
  @spec store(String.t(), reference(), DrawbridgeProxy.Protocol.metadata()) :: :ok
  def store(service_name, connection_ref, metadata) do
    :ets.insert(
      @table,
      {{service_name, connection_ref}, metadata, System.monotonic_time(:second)}
    )

    :ok
  end

  @doc "Look up metadata for a specific connection."
  @spec lookup(String.t(), reference()) :: {:ok, DrawbridgeProxy.Protocol.metadata()} | :not_found
  def lookup(service_name, connection_ref) do
    case :ets.lookup(@table, {service_name, connection_ref}) do
      [{_key, metadata, _ts}] -> {:ok, metadata}
      [] -> :not_found
    end
  end

  @doc "List all connections + metadata for a given service."
  @spec list_by_service(String.t()) :: [
          {reference(), DrawbridgeProxy.Protocol.metadata(), integer()}
        ]
  def list_by_service(service_name) do
    :ets.match_object(@table, {{service_name, :_}, :_, :_})
    |> Enum.map(fn {{_svc, ref}, meta, ts} -> {ref, meta, ts} end)
  end

  @doc "Remove entries older than `max_age_seconds` (monotonic)."
  @spec cleanup_older_than(integer()) :: non_neg_integer()
  def cleanup_older_than(max_age_seconds) do
    cutoff = System.monotonic_time(:second) - max_age_seconds

    :ets.select_delete(@table, [
      {{:_, :_, :"$1"}, [{:<, :"$1", cutoff}], [true]}
    ])
  end

  @doc "Remove a specific connection entry."
  @spec delete(String.t(), reference()) :: :ok
  def delete(service_name, connection_ref) do
    :ets.delete(@table, {service_name, connection_ref})
    :ok
  end

  # -- GenServer --

  @impl true
  def init(_opts) do
    table = :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
    {:ok, %{table: table}}
  end
end
