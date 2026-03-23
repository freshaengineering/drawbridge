defmodule DrawbridgeCore.ImageResolver do
  @moduledoc """
  Resolves OCI image tags to SHA256 digests via the `container` CLI.
  """

  @doc """
  Resolve a single image reference to its digest.

  Returns `{:ok, "sha256:..."}` or `{:error, reason}`.
  Pass `cmd_runner: fn(cmd, args) -> {output, exit_code} end` to stub for tests.
  """
  def resolve(image_ref, opts \\ []) do
    runner = Keyword.get(opts, :cmd_runner, &default_cmd/2)

    case runner.("container", ["image", "inspect", image_ref, "--format", "json"]) do
      {output, 0} ->
        extract_digest(output)

      {output, code} ->
        {:error, "container inspect exited #{code}: #{String.trim(output)}"}
    end
  end

  @doc """
  Resolve all service images to digests.

  Returns `%{service_name => %{tag: image, digest: sha}}`.
  Skips services that fail resolution (logs a warning).
  """
  def resolve_all(services, opts \\ []) do
    services
    |> Enum.reduce(%{}, fn {name, svc}, acc ->
      case resolve(svc.image, opts) do
        {:ok, digest} ->
          Map.put(acc, name, %{tag: svc.image, digest: digest})

        {:error, reason} ->
          IO.warn("Failed to resolve #{name} (#{svc.image}): #{reason}")
          acc
      end
    end)
  end

  @doc """
  Pull an image and then resolve its digest.
  """
  def pull_and_resolve(image_ref, opts \\ []) do
    runner = Keyword.get(opts, :cmd_runner, &default_cmd/2)

    case runner.("container", ["image", "pull", image_ref]) do
      {_, 0} -> resolve(image_ref, opts)
      {output, code} -> {:error, "container pull exited #{code}: #{String.trim(output)}"}
    end
  end

  defp extract_digest(json_output) do
    case Jason.decode(json_output) do
      {:ok, [first | _]} -> extract_from_map(first)
      {:ok, %{} = map} -> extract_from_map(map)
      {:error, reason} -> {:error, "failed to parse inspect JSON: #{inspect(reason)}"}
    end
  end

  defp extract_from_map(%{"Digest" => digest}) when is_binary(digest), do: {:ok, digest}

  defp extract_from_map(%{"RepoDigests" => [digest_ref | _]}) do
    case String.split(digest_ref, "@") do
      [_, digest] -> {:ok, digest}
      _ -> {:error, "unexpected RepoDigests format: #{digest_ref}"}
    end
  end

  defp extract_from_map(other),
    do: {:error, "no digest found in inspect output: #{inspect(other)}"}

  defp default_cmd(cmd, args) do
    System.cmd(cmd, args, stderr_to_stdout: true)
  end
end
