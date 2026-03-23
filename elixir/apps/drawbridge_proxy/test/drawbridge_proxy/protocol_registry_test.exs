defmodule DrawbridgeProxy.ProtocolRegistryTest do
  use ExUnit.Case, async: false

  alias DrawbridgeProxy.ProtocolRegistry

  setup do
    # The registry is already started by the application supervisor.
    # Just clear the ETS table between tests.
    :ets.delete_all_objects(DrawbridgeProxy.ProtocolRegistry)
    :ok
  end

  describe "store/3 and lookup/2" do
    test "stores and retrieves metadata" do
      ref = make_ref()
      meta = %{protocol: :http1, details: %{method: "GET", path: "/"}}

      assert :ok = ProtocolRegistry.store("web", ref, meta)
      assert {:ok, ^meta} = ProtocolRegistry.lookup("web", ref)
    end

    test "returns :not_found for missing entry" do
      assert :not_found = ProtocolRegistry.lookup("nonexistent", make_ref())
    end

    test "overwrites existing entry" do
      ref = make_ref()
      meta1 = %{protocol: :http1, details: %{method: "GET"}}
      meta2 = %{protocol: :http1, details: %{method: "POST"}}

      ProtocolRegistry.store("web", ref, meta1)
      ProtocolRegistry.store("web", ref, meta2)

      assert {:ok, ^meta2} = ProtocolRegistry.lookup("web", ref)
    end
  end

  describe "list_by_service/1" do
    test "lists all connections for a service" do
      ref1 = make_ref()
      ref2 = make_ref()
      meta1 = %{protocol: :http1, details: %{method: "GET"}}
      meta2 = %{protocol: :http1, details: %{method: "POST"}}

      ProtocolRegistry.store("web", ref1, meta1)
      ProtocolRegistry.store("web", ref2, meta2)
      ProtocolRegistry.store("other", make_ref(), %{protocol: :redis, details: %{}})

      results = ProtocolRegistry.list_by_service("web")
      assert length(results) == 2
      refs = Enum.map(results, fn {r, _m, _t} -> r end)
      assert ref1 in refs
      assert ref2 in refs
    end

    test "returns empty list for unknown service" do
      assert [] = ProtocolRegistry.list_by_service("ghost")
    end
  end

  describe "delete/2" do
    test "removes a specific entry" do
      ref = make_ref()
      ProtocolRegistry.store("web", ref, %{protocol: :http1, details: %{}})

      assert :ok = ProtocolRegistry.delete("web", ref)
      assert :not_found = ProtocolRegistry.lookup("web", ref)
    end
  end

  describe "cleanup_older_than/1" do
    test "removes stale entries" do
      ref_old = make_ref()
      ref_new = make_ref()

      # Insert an "old" entry by writing directly to ETS with a fake timestamp
      :ets.insert(
        DrawbridgeProxy.ProtocolRegistry,
        {{"svc", ref_old}, %{protocol: :redis, details: %{}},
         System.monotonic_time(:second) - 1000}
      )

      ProtocolRegistry.store("svc", ref_new, %{protocol: :http1, details: %{}})

      deleted = ProtocolRegistry.cleanup_older_than(500)
      assert deleted >= 1

      assert :not_found = ProtocolRegistry.lookup("svc", ref_old)
      assert {:ok, _} = ProtocolRegistry.lookup("svc", ref_new)
    end
  end
end
