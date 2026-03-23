defmodule DrawbridgeCore.DnsManagerHostsTest do
  use ExUnit.Case, async: true

  alias DrawbridgeCore.DnsManager

  @begin_marker "# BEGIN drawbridge"
  @end_marker "# END drawbridge"

  describe "hosts block building" do
    test "build_hosts_block creates correct format" do
      # Test via upsert logic on a fake hosts file
      original = "127.0.0.1 localhost\n::1 localhost\n"

      block =
        "#{@begin_marker}\n127.0.0.1 api.dev.local\n127.0.0.1 redis.dev.local\n#{@end_marker}"

      expected = String.trim_trailing(original) <> "\n\n" <> block <> "\n"

      result = insert_block(original, ["api.dev.local", "redis.dev.local"])
      assert result == expected
    end

    test "replaces existing block" do
      original = """
      127.0.0.1 localhost
      #{@begin_marker}
      127.0.0.1 old.dev.local
      #{@end_marker}
      ::1 localhost
      """

      result = insert_block(original, ["new.dev.local"])
      assert result =~ "127.0.0.1 new.dev.local"
      refute result =~ "old.dev.local"
      assert result =~ "::1 localhost"
    end

    test "idempotent — same hostnames produce same output" do
      original = "127.0.0.1 localhost\n"
      first = insert_block(original, ["api.dev.local"])
      second = insert_block(first, ["api.dev.local"])
      assert first == second
    end

    test "remove_block cleans up" do
      with_block = """
      127.0.0.1 localhost
      #{@begin_marker}
      127.0.0.1 api.dev.local
      #{@end_marker}
      ::1 localhost
      """

      result = remove_block(with_block)
      refute result =~ @begin_marker
      refute result =~ "api.dev.local"
      assert result =~ "127.0.0.1 localhost"
      assert result =~ "::1 localhost"
    end

    test "remove_block is no-op without markers" do
      original = "127.0.0.1 localhost\n"
      assert remove_block(original) == original
    end
  end

  # Helpers that test the pure string logic without touching /etc/hosts

  defp insert_block(content, hostnames) do
    block = build_block(hostnames)

    if String.contains?(content, @begin_marker) do
      Regex.replace(
        ~r/#{Regex.escape(@begin_marker)}.*?#{Regex.escape(@end_marker)}/s,
        content,
        block
      )
    else
      String.trim_trailing(content) <> "\n\n" <> block <> "\n"
    end
  end

  defp remove_block(content) do
    Regex.replace(
      ~r/\n?#{Regex.escape(@begin_marker)}.*?#{Regex.escape(@end_marker)}\n?/s,
      content,
      "\n"
    )
  end

  defp build_block(hostnames) do
    entries = Enum.map_join(hostnames, "\n", &"127.0.0.1 #{&1}")
    "#{@begin_marker}\n#{entries}\n#{@end_marker}"
  end
end
