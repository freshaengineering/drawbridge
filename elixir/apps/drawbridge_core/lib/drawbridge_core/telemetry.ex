defmodule DrawbridgeCore.Telemetry do
  @moduledoc """
  Telemetry event definitions and OpenTelemetry span helpers.

  Events emitted:
    - `[:drawbridge, :connection, :start]` — new proxy connection
    - `[:drawbridge, :connection, :stop]`  — proxy connection closed
    - `[:drawbridge, :boot, :start]`       — container boot initiated
    - `[:drawbridge, :boot, :stop]`        — container boot finished
    - `[:drawbridge, :idle_timeout]`       — service idled out

  Call `setup/0` at application start to attach OTel span handlers.
  """

  require OpenTelemetry.Tracer, as: Tracer

  @handler_id "drawbridge-otel-handler"

  @events [
    [:drawbridge, :connection, :start],
    [:drawbridge, :connection, :stop],
    [:drawbridge, :boot, :start],
    [:drawbridge, :boot, :stop],
    [:drawbridge, :idle_timeout]
  ]

  # -- Setup --

  @doc "Attach telemetry handlers that bridge events to OTel spans."
  def setup do
    :telemetry.attach_many(
      @handler_id,
      @events,
      &__MODULE__.handle_event/4,
      %{}
    )

    :ok
  end

  @doc "Detach handlers (useful in tests)."
  def teardown do
    :telemetry.detach(@handler_id)
  end

  # -- Emit helpers --

  def emit_connection_start(service_name, routing_type) do
    :telemetry.execute(
      [:drawbridge, :connection, :start],
      %{system_time: System.system_time()},
      %{service_name: service_name, routing_type: routing_type}
    )
  end

  def emit_connection_stop(service_name, duration_ms, bytes_sent \\ 0, bytes_received \\ 0) do
    :telemetry.execute(
      [:drawbridge, :connection, :stop],
      %{duration_ms: duration_ms, bytes_sent: bytes_sent, bytes_received: bytes_received},
      %{service_name: service_name}
    )
  end

  def emit_boot_start(service_name, image) do
    :telemetry.execute(
      [:drawbridge, :boot, :start],
      %{system_time: System.system_time()},
      %{service_name: service_name, image: image}
    )
  end

  def emit_boot_stop(service_name, duration_ms, success) do
    :telemetry.execute(
      [:drawbridge, :boot, :stop],
      %{duration_ms: duration_ms, success: success},
      %{service_name: service_name}
    )
  end

  def emit_idle_timeout(service_name) do
    :telemetry.execute(
      [:drawbridge, :idle_timeout],
      %{system_time: System.system_time()},
      %{service_name: service_name}
    )
  end

  # -- Handler callbacks --

  @doc false
  def handle_event([:drawbridge, :connection, :start], _measurements, metadata, _config) do
    Tracer.with_span "drawbridge.connection", %{
      attributes: [
        {"drawbridge.service", metadata.service_name},
        {"drawbridge.routing_type", to_string(metadata.routing_type)}
      ]
    } do
      :ok
    end
  end

  def handle_event([:drawbridge, :connection, :stop], measurements, metadata, _config) do
    Tracer.with_span "drawbridge.connection.stop", %{
      attributes: [
        {"drawbridge.service", metadata.service_name},
        {"drawbridge.duration_ms", measurements.duration_ms},
        {"drawbridge.bytes_sent", measurements.bytes_sent},
        {"drawbridge.bytes_received", measurements.bytes_received}
      ]
    } do
      :ok
    end
  end

  def handle_event([:drawbridge, :boot, :start], _measurements, metadata, _config) do
    Tracer.with_span "drawbridge.boot", %{
      attributes: [
        {"drawbridge.service", metadata.service_name},
        {"drawbridge.image", metadata.image}
      ]
    } do
      :ok
    end
  end

  def handle_event([:drawbridge, :boot, :stop], measurements, metadata, _config) do
    Tracer.with_span "drawbridge.boot.stop", %{
      attributes: [
        {"drawbridge.service", metadata.service_name},
        {"drawbridge.duration_ms", measurements.duration_ms},
        {"drawbridge.success", measurements.success}
      ]
    } do
      :ok
    end
  end

  def handle_event([:drawbridge, :idle_timeout], _measurements, metadata, _config) do
    Tracer.with_span "drawbridge.idle_timeout", %{
      attributes: [
        {"drawbridge.service", metadata.service_name}
      ]
    } do
      :ok
    end
  end
end
