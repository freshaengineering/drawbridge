defmodule DrawbridgeProxy.Protocol.Http1 do
  @moduledoc """
  HTTP/1.x request line + headers parser.

  Detects GET, POST, PUT, DELETE, PATCH, HEAD, OPTIONS, CONNECT, TRACE
  and extracts method, path, and Host header when present.
  """

  @behaviour DrawbridgeProxy.Protocol

  @methods ~w(GET POST PUT DELETE PATCH HEAD OPTIONS CONNECT TRACE)

  @impl true
  def detect(data) when is_binary(data) do
    case parse_request_line(data) do
      {:ok, method, path, rest} ->
        host = extract_host_header(rest)
        {:ok, %{protocol: :http1, details: %{method: method, path: path, host: host}}}

      :unknown ->
        :unknown
    end
  end

  defp parse_request_line(data) do
    case :binary.split(data, "\r\n") do
      [request_line, rest] ->
        case String.split(request_line, " ", parts: 3) do
          [method, path, "HTTP/1." <> _] when method in @methods ->
            {:ok, method, path, rest}

          _ ->
            :unknown
        end

      _ ->
        :unknown
    end
  end

  defp extract_host_header(headers_blob) do
    headers_blob
    |> :binary.split("\r\n", [:global])
    |> Enum.find_value(nil, fn line ->
      case String.split(line, ":", parts: 2) do
        [key, value] ->
          if String.downcase(String.trim(key)) == "host",
            do: String.trim(value)

        _ ->
          nil
      end
    end)
  end
end
