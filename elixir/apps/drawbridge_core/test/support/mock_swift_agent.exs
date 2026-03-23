# Mock Swift agent that speaks the same JSON-over-stdin/stdout protocol
# as the real DrawbridgeAgent CommandServer.
#
# Used by JsonBridgeTest. Run via: elixir mock_swift_agent.exs
#
# Does NOT depend on Jason — uses :json from OTP 27+ for decode, manual
# string building for encode (to keep it dependency-free).

IO.puts("[CommandServer] Ready. Accepting JSON commands on stdin.")

defmodule MockAgent do
  def loop do
    case IO.gets("") do
      :eof ->
        :ok

      {:error, _} ->
        :ok

      line ->
        line = String.trim(line)
        if line != "", do: handle(line)
        loop()
    end
  end

  defp handle(line) do
    case safe_decode(line) do
      {:ok, map} when is_map(map) ->
        cmd = Map.get(map, "cmd", "")
        id = Map.get(map, "id")
        response = dispatch(cmd, map, id)
        IO.puts(response)

      _ ->
        IO.puts(~s({"ok":false,"error":"parse error","code":"parse_error"}))
    end
  end

  # OTP 27 ships :json module; fall back to a naive regex-based approach otherwise
  defp safe_decode(str) do
    try do
      {:ok, :json.decode(str)}
    rescue
      _ -> :error
    end
  end

  defp dispatch("health", _req, id), do: ok_json(id, ~s("pong"))
  defp dispatch("list", _req, id), do: ok_json(id, "[]")

  defp dispatch("status", _req, id), do: ok_json(id, ~s("stopped"))

  defp dispatch("start", req, id) do
    name = Map.get(req, "name", "unknown")
    image = Map.get(req, "image", "unknown")
    ok_json(id, ~s({"image":"#{image}","name":"#{name}","state":"booting"}))
  end

  defp dispatch("stop", _req, id), do: ok_json(id, "true")

  defp dispatch("pull", req, id) do
    image = Map.get(req, "image", "")
    if image == "__crash__", do: System.halt(1)
    ok_json(id, "true")
  end

  defp dispatch("image_inspect", _req, id), do: ok_json(id, ~s("{}"))

  defp dispatch(cmd, _req, id) do
    err_json(id, "unknown cmd '#{cmd}'", "unknown_command")
  end

  defp ok_json(nil, data), do: ~s({"ok":true,"data":#{data}})
  defp ok_json(id, data), do: ~s({"id":"#{id}","ok":true,"data":#{data}})

  defp err_json(nil, msg, code), do: ~s({"ok":false,"error":"#{msg}","code":"#{code}"})

  defp err_json(id, msg, code),
    do: ~s({"id":"#{id}","ok":false,"error":"#{msg}","code":"#{code}"})
end

MockAgent.loop()
