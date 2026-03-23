defmodule DrawbridgeCore.Orchestrator do
  @moduledoc """
  Boots/stops all services from a loaded config.

  Called by `drawbridge up` / `drawbridge down` CLI commands.
  """

  @doc "Start ServiceManagers for all configured services."
  def start(%DrawbridgeCore.Config{} = config, opts \\ []) do
    config = maybe_overlay_lockfile(config, opts)

    Enum.each(config.services, fn {_name, service} ->
      case DrawbridgeCore.ServiceManager.start_service(service) do
        {:ok, _pid} -> :ok
        {:error, {:already_started, _pid}} -> :ok
        {:error, reason} -> raise "Failed to start service #{service.name}: #{inspect(reason)}"
      end
    end)

    :ok
  end

  defp maybe_overlay_lockfile(config, opts) do
    case Keyword.get(opts, :config_path) do
      nil -> config
      config_path -> DrawbridgeCore.Lockfile.load_and_overlay(config, config_path)
    end
  end

  @doc "Stop all running containers and their service managers."
  def stop_all do
    DrawbridgeCore.ServiceRegistry.list_services()
    |> Enum.each(fn {meta, pid} ->
      name = Map.get(meta, :name) || inspect(pid)

      try do
        DrawbridgeCore.ServiceManager.stop_service(name)
        DynamicSupervisor.terminate_child(DrawbridgeCore.ServiceSupervisor, pid)
      catch
        :exit, _ -> :ok
      end
    end)

    :ok
  end
end
