defmodule DrawbridgeCore.ImageResolver do
  @moduledoc """
  Resolves container image references to pullable tags.

  ECR repos don't have `latest` tags — images are tagged `git-<sha>`.
  When a service config omits the tag (no `:` in the image ref), this
  module queries ECR for the most recently pushed tag.

  Images with an explicit tag are passed through unchanged.
  """

  require Logger

  @doc """
  Resolve an image reference. If it's an ECR image without a tag,
  query for the most recently pushed tag. Otherwise return as-is.
  """
  def resolve(image) do
    {registry, repo, tag} = parse_image(image)

    if ecr_registry?(registry) and is_nil(tag) do
      # Check cache first
      cache_key = {:ecr_tag, registry, repo}

      case :persistent_term.get(cache_key, nil) do
        nil ->
          case resolve_ecr_latest(registry, repo) do
            {:ok, resolved_tag} ->
              resolved = "#{registry}/#{repo}:#{resolved_tag}"
              :persistent_term.put(cache_key, resolved)
              Logger.info("[ImageResolver] #{image} → #{resolved}")
              resolved

            {:error, reason} ->
              Logger.error("[ImageResolver] Failed to resolve #{image}: #{reason}")
              image
          end

        cached ->
          Logger.debug("[ImageResolver] #{image} → #{cached} (cached)")
          cached
      end
    else
      image
    end
  end

  @doc "Check if an image needs ECR tag resolution."
  def needs_resolution?(image) do
    {registry, _repo, tag} = parse_image(image)
    ecr_registry?(registry) and is_nil(tag)
  end

  @doc "Resolve all service images in a config in parallel, returning updated config."
  def resolve_config_parallel(%DrawbridgeCore.Config{} = config) do
    to_resolve =
      Enum.filter(config.services, fn {_, svc} -> needs_resolution?(svc.image) end)

    if to_resolve != [] do
      names = Enum.map_join(to_resolve, ", ", fn {name, _} -> name end)

      Logger.info(
        "[ImageResolver] Resolving #{length(to_resolve)} ECR tags in parallel: #{names}"
      )
    end

    # Resolve in parallel with Task.async_stream
    resolved =
      to_resolve
      |> Task.async_stream(
        fn {name, svc} -> {name, resolve(svc.image)} end,
        max_concurrency: 10,
        timeout: 30_000
      )
      |> Enum.reduce(%{}, fn
        {:ok, {name, image}}, acc -> Map.put(acc, name, image)
        {:exit, _reason}, acc -> acc
      end)

    updated_services =
      Map.new(config.services, fn {name, svc} ->
        case Map.fetch(resolved, name) do
          {:ok, image} -> {name, %{svc | image: image}}
          :error -> {name, svc}
        end
      end)

    %{config | services: updated_services}
  end

  # -- Digest resolution (used by lock command) --

  @doc "Resolve an image to its SHA256 digest via `container image inspect`."
  def resolve_digest(image_ref) do
    case System.cmd("container", ["image", "inspect", image_ref, "--format", "json"],
           stderr_to_stdout: true
         ) do
      {output, 0} -> extract_digest(output)
      {output, code} -> {:error, "container inspect exited #{code}: #{String.trim(output)}"}
    end
  end

  @doc "Pull an image and then resolve its digest."
  def pull_and_resolve(image_ref) do
    case System.cmd("container", ["image", "pull", image_ref], stderr_to_stdout: true) do
      {_, 0} -> resolve_digest(image_ref)
      {output, code} -> {:error, "container pull exited #{code}: #{String.trim(output)}"}
    end
  end

  defp extract_digest(json_output) do
    case Jason.decode(json_output) do
      {:ok, [%{"Digest" => digest} | _]} when is_binary(digest) -> {:ok, digest}
      {:ok, %{"Digest" => digest}} when is_binary(digest) -> {:ok, digest}
      {:ok, _} -> {:error, "no digest in inspect output"}
      {:error, reason} -> {:error, "failed to parse inspect JSON: #{inspect(reason)}"}
    end
  end

  # -- Private --

  defp parse_image(image) do
    # Split "registry/repo:tag" or "registry/repo" (no tag)
    {ref, tag} =
      case String.split(image, ":", parts: 2) do
        [ref, tag] -> {ref, tag}
        [ref] -> {ref, nil}
      end

    case String.split(ref, "/", parts: 2) do
      [registry, repo] when byte_size(registry) > 0 ->
        if String.contains?(registry, ".") do
          {registry, repo, tag}
        else
          {"", ref, tag}
        end

      _ ->
        {"", ref, tag}
    end
  end

  defp ecr_registry?(registry), do: String.contains?(registry, "dkr.ecr")

  defp resolve_ecr_latest(registry, repo) do
    region = extract_ecr_region(registry)

    case System.cmd(
           "aws",
           [
             "ecr",
             "describe-images",
             "--repository-name",
             repo,
             "--region",
             region,
             "--query",
             "imageDetails | sort_by(@, &imagePushedAt) | [-1].imageTags[0]",
             "--output",
             "json"
           ],
           stderr_to_stdout: true
         ) do
      {output, 0} ->
        # JSON output: "git-abc123" (with quotes) or "null"
        tag = output |> String.trim() |> String.trim("\"")

        if tag == "" or tag == "null" or tag == "None" do
          {:error, "no tags found for #{repo}"}
        else
          {:ok, tag}
        end

      {output, code} ->
        {:error, "aws ecr failed (exit #{code}): #{String.slice(output, 0, 200)}"}
    end
  end

  defp extract_ecr_region(registry) do
    # 514443763038.dkr.ecr.us-east-1.amazonaws.com → us-east-1
    registry |> String.split(".") |> Enum.at(3, "us-east-1")
  end
end
