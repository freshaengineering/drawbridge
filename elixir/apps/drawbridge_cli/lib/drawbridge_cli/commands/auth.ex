defmodule Mix.Tasks.Drawbridge.Auth do
  @moduledoc "Authenticate to container registries referenced in config."

  if Code.ensure_loaded?(Mix.Task) do
    use Mix.Task
  end

  def run(args) do
    {opts, _, _} =
      OptionParser.parse(args,
        switches: [config: :string, ghcr: :boolean, ecr: :boolean],
        aliases: [c: :config]
      )

    DrawbridgeCli.ensure_started()

    config_path = opts[:config] || DrawbridgeCli.find_config()

    case DrawbridgeCore.Config.load(config_path) do
      {:ok, config} ->
        registries = detect_registries(config)
        explicit? = opts[:ghcr] || opts[:ecr]

        ghcr_results =
          if opts[:ghcr] || (!explicit? && "ghcr.io" in registries),
            do: [auth_ghcr()],
            else: []

        ecr_registries = Enum.filter(registries, &String.contains?(&1, "dkr.ecr"))

        ecr_results =
          if opts[:ecr] || (!explicit? && ecr_registries != []),
            do: Enum.map(ecr_registries, &auth_ecr/1),
            else: []

        results = ghcr_results ++ ecr_results

        if Enum.any?(results, &(&1 == :error)), do: System.halt(1)

      {:error, reason} ->
        IO.puts(:stderr, "error: Failed to load config: #{inspect(reason)}")
        System.halt(1)
    end
  end

  defp detect_registries(config) do
    config.services
    |> Map.values()
    |> Enum.map(& &1.image)
    |> Enum.map(&extract_registry/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  defp extract_registry(image) do
    case String.split(image, "/", parts: 2) do
      [registry, _rest] when byte_size(registry) > 0 ->
        if String.contains?(registry, "."), do: registry, else: nil

      _ ->
        nil
    end
  end

  defp auth_ghcr do
    IO.puts("Authenticating to ghcr.io...")

    run_shell(
      "gh auth token | docker login --username x --password-stdin ghcr.io",
      "ghcr.io"
    )
  end

  # Region sits at index 3: 514443763038.dkr.ecr.us-east-1.amazonaws.com
  defp auth_ecr(registry) do
    region = registry |> String.split(".") |> Enum.at(3, "us-east-1")
    IO.puts("Authenticating to ECR (#{region})...")

    # Auth both docker and Apple Container CLI
    docker_result =
      run_shell(
        "aws ecr get-login-password --region #{region} | docker login --username AWS --password-stdin #{registry}",
        "#{registry} (docker)"
      )

    container_result =
      if System.find_executable("container") do
        run_shell(
          "aws ecr get-login-password --region #{region} | container registry login --username AWS --password-stdin #{registry}",
          "#{registry} (container)"
        )
      else
        :ok
      end

    if docker_result == :ok and container_result == :ok, do: :ok, else: :error
  end

  defp run_shell(cmd, label) do
    case System.cmd("sh", ["-c", cmd], stderr_to_stdout: true) do
      {_, 0} ->
        IO.puts("  ok: #{label}")
        :ok

      {output, code} ->
        IO.puts(:stderr, "  fail: #{label} (exit #{code}): #{String.trim(output)}")
        :error
    end
  end
end
