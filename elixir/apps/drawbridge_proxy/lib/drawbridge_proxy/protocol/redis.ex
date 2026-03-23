defmodule DrawbridgeProxy.Protocol.Redis do
  @moduledoc """
  RESP (Redis Serialization Protocol) command parser.

  Detects RESP2 array format (`*N\r\n$M\r\nCOMMAND\r\n...`) and
  extracts the command name.
  """

  @behaviour DrawbridgeProxy.Protocol

  @impl true
  def detect(<<"*", rest::binary>>) do
    case parse_resp_array(rest) do
      {:ok, command, args} ->
        {:ok,
         %{
           protocol: :redis,
           details: %{command: String.upcase(command), args: args}
         }}

      :unknown ->
        :unknown
    end
  end

  def detect(_), do: :unknown

  defp parse_resp_array(data) do
    with {count_str, rest} <- read_line(data),
         {count, ""} <- Integer.parse(count_str),
         true <- count > 0,
         {:ok, elements, _rest} <- read_bulk_strings(rest, count, []) do
      [command | args] = elements
      {:ok, command, args}
    else
      _ -> :unknown
    end
  end

  defp read_bulk_strings(rest, 0, acc), do: {:ok, Enum.reverse(acc), rest}

  defp read_bulk_strings(<<"$", rest::binary>>, remaining, acc) do
    with {len_str, rest2} <- read_line(rest),
         {len, ""} <- Integer.parse(len_str),
         true <- len >= 0,
         <<value::binary-size(len), "\r\n", rest3::binary>> <- rest2 do
      read_bulk_strings(rest3, remaining - 1, [value | acc])
    else
      _ -> :unknown
    end
  end

  defp read_bulk_strings(_, _, _), do: :unknown

  defp read_line(data) do
    case :binary.split(data, "\r\n") do
      [line, rest] -> {line, rest}
      _ -> :error
    end
  end
end
