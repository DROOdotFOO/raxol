defmodule Raxol.Protocols.ProtocolTest do
  use ExUnit.Case, async: true

  alias Raxol.Protocols.{Renderable, Serializable}

  describe "Renderable protocol" do
    test "renders strings" do
      assert Renderable.render("Hello, World!", []) == "Hello, World!"
      metadata = Renderable.render_metadata("Hello, World!")
      assert metadata.width == 13
      assert metadata.height == 1
    end

    test "renders lists" do
      list = ["item1", "item2", "item3"]
      rendered = Renderable.render(list, [])
      assert rendered == "item1\nitem2\nitem3"

      metadata = Renderable.render_metadata(list)
      assert metadata.height == 3
    end

    test "renders maps" do
      map = %{name: "John", age: 30}
      rendered = Renderable.render(map, [])
      assert rendered =~ "age"
      assert rendered =~ "name"
      assert rendered =~ "30"
      assert rendered =~ "John"
    end

    test "renders atoms" do
      assert Renderable.render(:test_atom, []) == "test_atom"
      metadata = Renderable.render_metadata(:test_atom)
      assert metadata.width == 9
    end

    test "renders integers" do
      assert Renderable.render(42, []) == "42"
      metadata = Renderable.render_metadata(42)
      assert metadata.width == 2
    end

    test "renders floats" do
      assert Renderable.render(3.14, []) == "3.14"
      metadata = Renderable.render_metadata(3.14)
      assert metadata.width == 4
    end
  end

  describe "Serializable protocol" do
    test "serializes maps to JSON" do
      map = %{name: "John", age: 30}
      json = Serializable.serialize(map, :json)
      assert json =~ "\"name\""
      assert json =~ "\"John\""
      assert json =~ "\"age\""
      assert json =~ "30"
    end

    test "serializes lists to JSON" do
      list = [1, 2, 3]
      json = Serializable.serialize(list, :json)
      assert json == "[1,2,3]"
    end

    test "serializes strings to JSON" do
      string = "Hello, World!"
      json = Serializable.serialize(string, :json)
      assert json == "\"Hello, World!\""
    end

    test "serializes atoms to JSON" do
      assert Serializable.serialize(nil, :json) == "null"
      assert Serializable.serialize(true, :json) == "true"
      assert Serializable.serialize(false, :json) == "false"
      assert Serializable.serialize(:test, :json) == "\"test\""
    end

    test "serializes to binary format" do
      data = %{test: "data"}
      binary = Serializable.serialize(data, :binary)
      assert is_binary(binary)

      # Can round-trip through :erlang.binary_to_term
      restored = :erlang.binary_to_term(binary)
      assert restored == data
    end

    test "serializable? returns correct values" do
      assert Serializable.serializable?(%{}, :json) == true
      assert Serializable.serializable?(%{}, :binary) == true
      assert Serializable.serializable?(%{}, :unknown) == false

      assert Serializable.serializable?([], :json) == true
      assert Serializable.serializable?("string", :json) == true
    end

    test "returns error for unsupported formats" do
      assert {:error, {:unsupported_format, :unknown}} =
        Serializable.serialize(%{}, :unknown)
    end
  end
end
