defmodule DrawbridgeCli do
  @moduledoc "Escript entry point for the Drawbridge CLI."

  @doc "Start OTP applications needed by the CLI (works outside Mix)."
  def ensure_started do
    Application.ensure_all_started(:drawbridge_core)
    Application.ensure_all_started(:drawbridge_proxy)
  end

  def main(args) do
    # Only split on the first positional arg (the subcommand).
    # Pass everything after it through untouched so subcommand
    # parsers handle their own flags (--local, --tui, etc.)
    {command, rest} = split_subcommand(args)

    case command do
      "setup" -> Mix.Tasks.Drawbridge.Setup.run(rest)
      "up" -> Mix.Tasks.Drawbridge.Up.run(rest)
      "down" -> Mix.Tasks.Drawbridge.Down.run(rest)
      "status" -> Mix.Tasks.Drawbridge.Status.run(rest)
      "pull" -> Mix.Tasks.Drawbridge.Pull.run(rest)
      "lock" -> Mix.Tasks.Drawbridge.Lock.run(rest)
      "init" -> Mix.Tasks.Drawbridge.Init.run(rest)
      "api" -> Mix.Tasks.Drawbridge.Api.run(rest)
      "mcp" -> Mix.Tasks.Drawbridge.Mcp.run(rest)
      "tui" -> Mix.Tasks.Drawbridge.Tui.run(rest)
      "auth" -> Mix.Tasks.Drawbridge.Auth.run(rest)
      "version" -> IO.puts("drawbridge #{version()}")
      _ -> usage()
    end
  end

  defp version do
    Application.spec(:drawbridge_cli, :vsn) |> to_string()
  end

  @doc "Find the nearest drawbridge config file, or halt with error if none found."
  def find_config do
    cond do
      File.exists?("drawbridge.yml") ->
        "drawbridge.yml"

      File.exists?("drawbridge.yaml") ->
        "drawbridge.yaml"

      File.exists?("config/drawbridge.yml") ->
        "config/drawbridge.yml"

      true ->
        IO.puts(:stderr, "error: No drawbridge.yml found. Run \`drawbridge init\` to create one.")
        System.halt(1)
    end
  end

  defp split_subcommand(args) do
    case Enum.split_while(args, &String.starts_with?(&1, "-")) do
      {_flags, [cmd | rest]} -> {cmd, rest}
      {_, []} -> {nil, []}
    end
  end

  defp usage do
    IO.puts("""
    drawbridge — on-demand local dev stack proxy

    Usage:
      drawbridge setup [--domain dev.local]
      drawbridge up [--config path] [--no-dns] [--tui] [--local service ...]
      drawbridge down [--config path] [--keep-dns]
      drawbridge status
      drawbridge pull [service...] [--all]
      drawbridge lock [--update] [--partial] [--config path]
      drawbridge tui [--config path]
      drawbridge init
      drawbridge api [--port 4001] [--config path]
      drawbridge auth [--ghcr] [--ecr] [--config path]
      drawbridge mcp [--config path]
      drawbridge version
    """)
  end
end
