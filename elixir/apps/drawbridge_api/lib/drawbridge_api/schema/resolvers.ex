defmodule DrawbridgeApi.Schema.Resolvers do
  @moduledoc false

  alias DrawbridgeCore.ServiceManager

  def list_services(_parent, _args, _resolution) do
    services =
      ServiceManager.list_services()
      |> Enum.map(&format_service/1)

    {:ok, services}
  end

  def get_service(_parent, %{name: name}, _resolution) do
    case ServiceManager.get_state(name) do
      {:error, :service_not_found} -> {:ok, nil}
      info -> {:ok, format_service(info)}
    end
  end

  def boot_service(_parent, %{name: name}, _resolution) do
    case ServiceManager.request_connection(name) do
      {:ok, _endpoint} ->
        case ServiceManager.get_state(name) do
          {:error, reason} -> {:error, inspect(reason)}
          info -> {:ok, format_service(info)}
        end

      {:error, reason} ->
        {:error, inspect(reason)}
    end
  end

  def stop_service(_parent, %{name: name}, _resolution) do
    case ServiceManager.stop_service(name) do
      :ok ->
        case ServiceManager.get_state(name) do
          {:error, reason} -> {:error, inspect(reason)}
          info -> {:ok, format_service(info)}
        end

      {:error, reason} ->
        {:error, inspect(reason)}
    end
  end

  def schema_sdl(_parent, _args, _resolution) do
    {:ok, Absinthe.Schema.to_sdl(DrawbridgeApi.Schema)}
  end

  def setup_prompt(_parent, _args, _resolution) do
    {:ok, DrawbridgeApi.SetupPrompt.render()}
  end

  defp format_service(info) do
    %{
      name: info.name,
      state: info.state,
      hostname: info.hostname,
      image: info.image,
      ports:
        Enum.map(info.ports, fn {host, container} -> %{host: host, container: container} end),
      connections: info.connections,
      uptime: info.uptime,
      ip: info.ip,
      depends_on: info.depends_on
    }
  end
end
