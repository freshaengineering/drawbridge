defmodule DrawbridgeCore.Config.Service do
  @enforce_keys [:name, :image, :hostname, :ports]
  defstruct [
    :name,
    :image,
    :hostname,
    :ports,
    :idle_timeout,
    :boot_timeout,
    :health_check,
    :depends_on,
    env: %{},
    tls_backend: false,
    protocol: nil
  ]
end

defmodule DrawbridgeCore.Config do
  @enforce_keys [:domain, :services]
  defstruct [
    :domain,
    :idle_timeout,
    :max_containers,
    :services
  ]

  @doc "Load and parse a drawbridge.yml file."
  def load(path) do
    with {:ok, raw} <- YamlElixir.read_from_file(path),
         {:ok, config} <- parse(raw) do
      {:ok, config}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Load and parse a drawbridge.yml file, raising on error."
  def load!(path) do
    case load(path) do
      {:ok, config} -> config
      {:error, reason} -> raise "Failed to load drawbridge config: #{inspect(reason)}"
    end
  end

  # -- Private --

  defp parse(raw) do
    global_idle = raw["idle_timeout"] || 300

    with {:ok, services} <- parse_services(raw["services"] || %{}, global_idle),
         :ok <- validate_no_duplicate_hostnames(services),
         :ok <- validate_no_duplicate_host_ports(services) do
      {:ok,
       %__MODULE__{
         domain: raw["domain"] || "localhost",
         idle_timeout: global_idle,
         max_containers: raw["max_containers"] || 8,
         services: services
       }}
    end
  end

  defp parse_services(services_map, global_idle) do
    services_map
    |> Enum.reduce_while({:ok, %{}}, fn {name, svc_raw}, {:ok, acc} ->
      case parse_service(name, svc_raw, global_idle) do
        {:ok, svc} -> {:cont, {:ok, Map.put(acc, name, svc)}}
        {:error, _} = err -> {:halt, err}
      end
    end)
  end

  defp parse_service(name, raw, global_idle) do
    with {:ok, ports} <- parse_ports(raw["ports"] || []) do
      {:ok,
       %DrawbridgeCore.Config.Service{
         name: name,
         image: raw["image"],
         hostname: raw["hostname"],
         ports: ports,
         env: stringify_keys(raw["env"] || %{}),
         idle_timeout: raw["idle_timeout"] || global_idle,
         boot_timeout: raw["boot_timeout"] || 30,
         health_check: raw["health_check"],
         tls_backend: raw["tls_backend"] || false,
         depends_on: raw["depends_on"] || [],
         protocol: parse_protocol_hint(raw["protocol"])
       }}
    end
  end

  defp parse_ports(port_strings) do
    port_strings
    |> Enum.reduce_while({:ok, []}, fn entry, {:ok, acc} ->
      case parse_port_entry(entry) do
        {:ok, tuple} -> {:cont, {:ok, acc ++ [tuple]}}
        {:error, _} = err -> {:halt, err}
      end
    end)
  end

  defp parse_port_entry(entry) when is_binary(entry) do
    case String.split(entry, ":") do
      [host_str, container_str] ->
        with {:ok, host_port} <- parse_port_number(host_str),
             {:ok, container_port} <- parse_port_number(container_str) do
          {:ok, {host_port, container_port}}
        end

      _ ->
        {:error, "invalid port format: #{entry}, expected host:container"}
    end
  end

  defp parse_port_entry(entry) when is_integer(entry) do
    with {:ok, port} <- parse_port_number(entry) do
      {:ok, {port, port}}
    end
  end

  defp parse_port_number(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {n, ""} -> validate_port_range(n)
      _ -> {:error, "invalid port number: #{value}"}
    end
  end

  defp parse_port_number(value) when is_integer(value), do: validate_port_range(value)

  defp validate_port_range(port) when port >= 1 and port <= 65535, do: {:ok, port}
  defp validate_port_range(port), do: {:error, "port #{port} out of range (1-65535)"}

  defp validate_no_duplicate_hostnames(services) do
    hostnames = Enum.map(services, fn {_, svc} -> svc.hostname end) |> Enum.reject(&is_nil/1)
    duplicates = hostnames -- Enum.uniq(hostnames)

    case duplicates do
      [] -> :ok
      dupes -> {:error, "duplicate hostnames: #{Enum.join(dupes, ", ")}"}
    end
  end

  defp validate_no_duplicate_host_ports(services) do
    host_ports =
      services
      |> Enum.flat_map(fn {_, svc} -> Enum.map(svc.ports, fn {hp, _} -> hp end) end)

    duplicates = host_ports -- Enum.uniq(host_ports)

    case duplicates do
      [] -> :ok
      dupes -> {:error, "duplicate host ports: #{Enum.join(dupes, ", ")}"}
    end
  end

  @known_protocols ~w(http1 http2 postgres redis kafka grpc tls)a

  defp parse_protocol_hint(nil), do: nil

  defp parse_protocol_hint(value) when is_binary(value) do
    atom = String.to_existing_atom(value)
    if atom in @known_protocols, do: atom, else: nil
  rescue
    ArgumentError -> nil
  end

  defp parse_protocol_hint(value) when is_atom(value) do
    if value in @known_protocols, do: value, else: nil
  end

  defp stringify_keys(map) when is_map(map) do
    Map.new(map, fn {k, v} -> {to_string(k), to_string(v)} end)
  end
end
