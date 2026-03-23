defmodule DrawbridgeApi.SchemaTest do
  use ExUnit.Case, async: true

  describe "schema_sdl query" do
    test "returns the schema as SDL string" do
      query = "{ schemaSdl }"
      assert {:ok, %{data: %{"schemaSdl" => sdl}}} = Absinthe.run(query, DrawbridgeApi.Schema)
      assert is_binary(sdl)
      assert sdl =~ "type Service"
      assert sdl =~ "enum ServiceState"
      assert sdl =~ "type PortMapping"
      assert sdl =~ "bootService"
      assert sdl =~ "stopService"
    end
  end

  describe "setup_prompt query" do
    test "returns a non-empty markdown string" do
      query = "{ setupPrompt }"

      assert {:ok, %{data: %{"setupPrompt" => prompt}}} =
               Absinthe.run(query, DrawbridgeApi.Schema)

      assert is_binary(prompt)
      assert prompt =~ "drawbridge.yml"
      assert prompt =~ "MCP"
    end
  end

  describe "services query" do
    test "returns empty list when no services are registered" do
      query = "{ services { name state } }"
      assert {:ok, %{data: %{"services" => services}}} = Absinthe.run(query, DrawbridgeApi.Schema)
      assert is_list(services)
    end
  end

  describe "service query" do
    test "returns nil for unknown service" do
      query = ~s|{ service(name: "nonexistent") { name state } }|

      assert {:ok, %{data: %{"service" => nil}}} =
               Absinthe.run(query, DrawbridgeApi.Schema)
    end
  end

  describe "introspection" do
    test "schema has expected query fields" do
      query = """
      {
        __schema {
          queryType {
            fields {
              name
            }
          }
        }
      }
      """

      assert {:ok, %{data: data}} = Absinthe.run(query, DrawbridgeApi.Schema)
      field_names = Enum.map(data["__schema"]["queryType"]["fields"], & &1["name"])
      assert "services" in field_names
      assert "service" in field_names
      assert "setupPrompt" in field_names
      assert "schemaSdl" in field_names
    end

    test "schema has expected mutation fields" do
      query = """
      {
        __schema {
          mutationType {
            fields {
              name
            }
          }
        }
      }
      """

      assert {:ok, %{data: data}} = Absinthe.run(query, DrawbridgeApi.Schema)
      field_names = Enum.map(data["__schema"]["mutationType"]["fields"], & &1["name"])
      assert "bootService" in field_names
      assert "stopService" in field_names
    end
  end
end
