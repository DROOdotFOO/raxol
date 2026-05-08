defmodule Raxol.MCP.ToolDefTest do
  use ExUnit.Case, async: true

  alias Raxol.MCP.ToolDef

  defp valid_opts(extra \\ []) do
    Keyword.merge(
      [
        description: "Does the thing",
        input_schema: %{type: "object", properties: %{}},
        callback: fn _args -> :ok end
      ],
      extra
    )
  end

  describe "new/2" do
    test "returns {:ok, def} with all required fields" do
      assert {:ok, def} = ToolDef.new("my_tool", valid_opts())
      assert def.name == "my_tool"
      assert def.description == "Does the thing"
      assert def.inputSchema == %{type: "object", properties: %{}}
      assert is_function(def.callback, 1)
    end

    test "accepts :inputSchema as well as :input_schema" do
      assert {:ok, %{inputSchema: %{type: "object"}}} =
               ToolDef.new(
                 "t",
                 valid_opts(input_schema: nil) ++
                   [inputSchema: %{type: "object"}]
               )
    end

    test "rejects empty name" do
      assert {:error, errors} = ToolDef.new("", valid_opts())
      assert :missing_name in errors
    end

    test "rejects missing description" do
      opts = valid_opts() |> Keyword.delete(:description)
      assert {:error, errors} = ToolDef.new("t", opts)
      assert :missing_description in errors
    end

    test "rejects missing callback" do
      opts = valid_opts() |> Keyword.delete(:callback)
      assert {:error, errors} = ToolDef.new("t", opts)
      assert :missing_callback in errors
    end

    test "rejects callback with wrong arity" do
      opts = valid_opts(callback: fn -> :ok end)
      assert {:error, errors} = ToolDef.new("t", opts)
      assert :invalid_callback_arity in errors
    end

    test "rejects missing schema" do
      opts = valid_opts() |> Keyword.delete(:input_schema)
      assert {:error, errors} = ToolDef.new("t", opts)
      assert :missing_input_schema in errors
    end

    test "rejects schema without type=object" do
      opts = valid_opts(input_schema: %{type: "array"})
      assert {:error, errors} = ToolDef.new("t", opts)
      assert :invalid_input_schema in errors
    end

    test "accumulates multiple errors" do
      assert {:error, errors} =
               ToolDef.new("", description: "", input_schema: nil)

      assert :missing_name in errors
      assert :missing_description in errors
      assert :missing_callback in errors
      assert :missing_input_schema in errors
    end
  end

  describe "new!/2" do
    test "returns the def on success" do
      assert %{name: "x"} = ToolDef.new!("x", valid_opts())
    end

    test "raises ArgumentError on failure" do
      assert_raise ArgumentError, ~r/invalid tool definition/, fn ->
        ToolDef.new!("", valid_opts())
      end
    end
  end

  describe "validate/1" do
    test "accepts a hand-built map" do
      map = %{
        name: "x",
        description: "y",
        inputSchema: %{type: "object"},
        callback: fn _ -> :ok end
      }

      assert :ok = ToolDef.validate(map)
    end

    test "accepts string-keyed maps too (MCP wire format)" do
      map = %{
        "name" => "x",
        "description" => "y",
        "inputSchema" => %{"type" => "object"},
        :callback => fn _ -> :ok end
      }

      assert :ok = ToolDef.validate(map)
    end

    test "returns errors for malformed maps" do
      assert {:error, errors} = ToolDef.validate(%{name: "x"})
      assert :missing_description in errors
      assert :missing_callback in errors
      assert :missing_input_schema in errors
    end

    test "rejects non-maps" do
      assert {:error, [:missing_name]} = ToolDef.validate("not a map")
    end
  end
end
