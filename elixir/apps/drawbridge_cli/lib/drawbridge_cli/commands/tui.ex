defmodule Mix.Tasks.Drawbridge.Tui do
  @moduledoc "Launch the Drawbridge TUI dashboard."
  @shortdoc "Start Drawbridge with TUI dashboard"

  use Mix.Task

  @impl Mix.Task
  def run(args) do
    {opts, _, _} =
      OptionParser.parse(args,
        switches: [config: :string, no_dns: :boolean],
        aliases: [c: :config]
      )

    # Delegate to `up --tui` so boot logic stays in one place
    tui_args = ["--tui" | args_from_opts(opts)]
    Mix.Tasks.Drawbridge.Up.run(tui_args)
  end

  defp args_from_opts(opts) do
    Enum.flat_map(opts, fn
      {:config, path} -> ["--config", path]
      {:no_dns, true} -> ["--no-dns"]
      _ -> []
    end)
  end
end
