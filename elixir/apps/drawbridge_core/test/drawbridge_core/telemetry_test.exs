defmodule DrawbridgeCore.TelemetryTest do
  use ExUnit.Case, async: false

  alias DrawbridgeCore.Telemetry

  @handler_id "telemetry-test-handler"

  setup do
    test_pid = self()

    handler = fn event, measurements, metadata, _config ->
      send(test_pid, {:telemetry_event, event, measurements, metadata})
    end

    events = [
      [:drawbridge, :connection, :start],
      [:drawbridge, :connection, :stop],
      [:drawbridge, :boot, :start],
      [:drawbridge, :boot, :stop],
      [:drawbridge, :idle_timeout]
    ]

    :telemetry.attach_many(@handler_id, events, handler, %{})

    on_exit(fn -> :telemetry.detach(@handler_id) end)

    :ok
  end

  test "setup/0 attaches handlers without crashing" do
    # Detach first in case Application already attached
    try do
      Telemetry.teardown()
    rescue
      _ -> :ok
    end

    assert :ok = Telemetry.setup()

    # Cleanup so other tests aren't affected
    Telemetry.teardown()
  end

  test "emit_connection_start fires event with correct metadata" do
    Telemetry.emit_connection_start("my-svc", :sni)

    assert_receive {:telemetry_event, [:drawbridge, :connection, :start], measurements, metadata}
    assert metadata.service_name == "my-svc"
    assert metadata.routing_type == :sni
    assert is_integer(measurements.system_time)
  end

  test "emit_connection_stop fires event with duration and byte counts" do
    Telemetry.emit_connection_stop("my-svc", 150, 1024, 2048)

    assert_receive {:telemetry_event, [:drawbridge, :connection, :stop], measurements, metadata}
    assert metadata.service_name == "my-svc"
    assert measurements.duration_ms == 150
    assert measurements.bytes_sent == 1024
    assert measurements.bytes_received == 2048
  end

  test "emit_boot_start fires event with service name and image" do
    Telemetry.emit_boot_start("pg", "postgres:17")

    assert_receive {:telemetry_event, [:drawbridge, :boot, :start], _measurements, metadata}
    assert metadata.service_name == "pg"
    assert metadata.image == "postgres:17"
  end

  test "emit_boot_stop fires event with duration and success flag" do
    Telemetry.emit_boot_stop("pg", 3200, true)

    assert_receive {:telemetry_event, [:drawbridge, :boot, :stop], measurements, metadata}
    assert metadata.service_name == "pg"
    assert measurements.duration_ms == 3200
    assert measurements.success == true
  end

  test "emit_boot_stop fires with success=false on failure" do
    Telemetry.emit_boot_stop("pg", 500, false)

    assert_receive {:telemetry_event, [:drawbridge, :boot, :stop], measurements, _metadata}
    assert measurements.success == false
  end

  test "emit_idle_timeout fires event with service name" do
    Telemetry.emit_idle_timeout("redis")

    assert_receive {:telemetry_event, [:drawbridge, :idle_timeout], _measurements, metadata}
    assert metadata.service_name == "redis"
  end

  test "OTel setup doesn't crash when exporter is :none" do
    # exporter is :none in test.exs — just verify setup is fine
    try do
      Telemetry.teardown()
    rescue
      _ -> :ok
    end

    assert :ok = Telemetry.setup()

    # Emit an event through the OTel handler path — should not blow up
    Telemetry.emit_connection_start("test-svc", :port)

    Telemetry.teardown()
  end
end
