defmodule DrawbridgeCli do
  @moduledoc "Escript entry point for the Drawbridge CLI."

  def main(args) do
    {_opts, command, _} =
      OptionParser.parse(args,
        switches: [config: :string, all: :boolean, no_dns: :boolean, keep_dns: :boolean],
        aliases: [c: :config]
      )

    case command do
      ["up" | rest] -> Mix.Tasks.Drawbridge.Up.run(rest)
      ["down" | rest] -> Mix.Tasks.Drawbridge.Down.run(rest)
      ["status" | _] -> Mix.Tasks.Drawbridge.Status.run([])
      ["pull" | rest] -> Mix.Tasks.Drawbridge.Pull.run(rest)
      ["init" | _] -> Mix.Tasks.Drawbridge.Init.run([])
      ["tui" | rest] -> Mix.Tasks.Drawbridge.Tui.run(rest)
      ["version" | _] -> IO.puts("drawbridge #{version()}")
      _ -> usage()
    end
  end

  defp version do
    Application.spec(:drawbridge_cli, :vsn) |> to_string()
  end

  defp usage do
    IO.puts("""
    drawbridge — on-demand local dev stack proxy

    Usage:
      drawbridge up [--config path] [--no-dns] [--tui]
      drawbridge down [--config path] [--keep-dns]
      drawbridge status
      drawbridge pull [service...] [--all]
      drawbridge tui [--config path]
      drawbridge init
      drawbridge version
    """)
  end
end
