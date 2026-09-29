defmodule Raxol.Core.Utils.ValidationTest do
  use ExUnit.Case, async: true

  alias Raxol.Core.Utils.Validation

  describe "validate_dimension/2" do
    test "returns positive integer as-is" do
      assert Validation.validate_dimension(80, 0) == 80
      assert Validation.validate_dimension(1, 0) == 1
      assert Validation.validate_dimension(9999, 0) == 9999
    end

    test "returns default for zero" do
      assert Validation.validate_dimension(0, 80) == 80
    end

    test "returns default for negative integer" do
      assert Validation.validate_dimension(-1, 80) == 80
      assert Validation.validate_dimension(-100, 24) == 24
    end

    test "returns default for float" do
      assert Validation.validate_dimension(3.5, 80) == 80
    end

    test "returns default for non-integer types" do
      assert Validation.validate_dimension("80", 80) == 80
      assert Validation.validate_dimension(nil, 80) == 80
      assert Validation.validate_dimension(:foo, 80) == 80
      assert Validation.validate_dimension([80], 80) == 80
    end
  end

  describe "clamp_terminal_size/2" do
    alias Raxol.Core.Defaults

    test "a size within the ceiling is unchanged, up to each axis and the cell budget" do
      assert Validation.clamp_terminal_size(80, 24) == {80, 24}
      assert Validation.clamp_terminal_size(1024, 1024) == {1024, 1024}
      assert Validation.clamp_terminal_size(Defaults.max_terminal_width(), 256) == {4096, 256}
      assert Validation.clamp_terminal_size(256, Defaults.max_terminal_height()) == {256, 4096}
    end

    test "an axis past its ceiling is capped" do
      assert Validation.clamp_terminal_size(4097, 24) == {4096, 24}
      assert Validation.clamp_terminal_size(80, 4097) == {80, 4096}
    end

    test "the height gives way so width * height stays within the cell ceiling" do
      assert Validation.clamp_terminal_size(1025, 1024) == {1025, 1023}
      assert Validation.clamp_terminal_size(4096, 257) == {4096, 256}

      for {w, h} <- [{100_000, 100_000}, {4_294_967_295, 4_294_967_295}, {3000, 3000}] do
        {cw, ch} = Validation.clamp_terminal_size(w, h)
        assert cw <= Defaults.max_terminal_width()
        assert ch <= Defaults.max_terminal_height()
        assert cw * ch <= Defaults.max_terminal_cells()
      end

      assert Validation.clamp_terminal_size(100_000, 100_000) == {4096, 256}
    end

    test "only the upper bound is applied" do
      assert Validation.clamp_terminal_size(0, 0) == {0, 0}
      assert Validation.clamp_terminal_size(-5, 30) == {-5, 30}
      assert Validation.clamp_terminal_size(nil, 30) == {nil, 30}
    end
  end

  describe "validate_terminal_size/2" do
    test "accepts a size up to the ceiling" do
      assert Validation.validate_terminal_size(1, 1) == :ok
      assert Validation.validate_terminal_size(4096, 256) == :ok
      assert Validation.validate_terminal_size(1024, 1024) == :ok
    end

    test "refuses a size past an axis or the cell ceiling" do
      assert Validation.validate_terminal_size(100_000, 40) ==
               {:error, :dimensions_too_large}

      assert Validation.validate_terminal_size(120, 4097) ==
               {:error, :dimensions_too_large}

      assert Validation.validate_terminal_size(1025, 1024) ==
               {:error, :dimensions_too_large}
    end

    test "refuses a non-positive or non-integer size" do
      for {w, h} <- [{0, 24}, {80, -1}, {80.0, 24}, {"80", 24}, {nil, nil}] do
        assert Validation.validate_terminal_size(w, h) ==
                 {:error, :invalid_dimensions}
      end
    end
  end

  describe "validate_coordinates/2" do
    test "accepts zero coordinates" do
      assert Validation.validate_coordinates(0, 0) == {:ok, {0, 0}}
    end

    test "accepts positive coordinates" do
      assert Validation.validate_coordinates(10, 20) == {:ok, {10, 20}}
      assert Validation.validate_coordinates(1, 1) == {:ok, {1, 1}}
    end

    test "rejects negative x" do
      assert Validation.validate_coordinates(-1, 0) == {:error, :invalid_coordinates}
    end

    test "rejects negative y" do
      assert Validation.validate_coordinates(0, -1) == {:error, :invalid_coordinates}
    end

    test "rejects both negative" do
      assert Validation.validate_coordinates(-5, -10) == {:error, :invalid_coordinates}
    end

    test "rejects floats" do
      assert Validation.validate_coordinates(1.5, 2) == {:error, :invalid_coordinates}
      assert Validation.validate_coordinates(1, 2.5) == {:error, :invalid_coordinates}
    end

    test "rejects non-numeric types" do
      assert Validation.validate_coordinates("1", 2) == {:error, :invalid_coordinates}
      assert Validation.validate_coordinates(1, nil) == {:error, :invalid_coordinates}
      assert Validation.validate_coordinates(:a, :b) == {:error, :invalid_coordinates}
    end
  end

  describe "validate_config/2" do
    test "accepts map with all required keys" do
      config = %{width: 80, height: 24, title: "test"}
      assert Validation.validate_config(config, [:width, :height]) == {:ok, config}
    end

    test "accepts map with extra keys beyond required" do
      config = %{width: 80, height: 24, color: :red}
      assert Validation.validate_config(config, [:width]) == {:ok, config}
    end

    test "accepts empty required keys list" do
      config = %{anything: true}
      assert Validation.validate_config(config, []) == {:ok, config}
    end

    test "accepts empty map with empty required keys" do
      assert Validation.validate_config(%{}, []) == {:ok, %{}}
    end

    test "returns missing keys when some are absent" do
      config = %{width: 80}

      assert Validation.validate_config(config, [:width, :height, :title]) ==
               {:error, {:missing_keys, [:height, :title]}}
    end

    test "returns all keys as missing for empty map" do
      assert Validation.validate_config(%{}, [:a, :b]) ==
               {:error, {:missing_keys, [:a, :b]}}
    end

    test "rejects non-map config" do
      assert Validation.validate_config("not a map", [:key]) == {:error, :invalid_config}
      assert Validation.validate_config(nil, [:key]) == {:error, :invalid_config}
      assert Validation.validate_config([key: 1], [:key]) == {:error, :invalid_config}
    end

    test "works with string keys when required keys are atoms" do
      config = %{"width" => 80}

      assert Validation.validate_config(config, [:width]) ==
               {:error, {:missing_keys, [:width]}}
    end
  end

  describe "validate_bounds/3" do
    test "accepts value at lower bound" do
      assert Validation.validate_bounds(0, 0, 100) == {:ok, 0}
    end

    test "accepts value at upper bound" do
      assert Validation.validate_bounds(100, 0, 100) == {:ok, 100}
    end

    test "accepts value within bounds" do
      assert Validation.validate_bounds(50, 0, 100) == {:ok, 50}
    end

    test "accepts float within integer bounds" do
      assert Validation.validate_bounds(3.14, 0, 10) == {:ok, 3.14}
    end

    test "accepts negative ranges" do
      assert Validation.validate_bounds(-5, -10, -1) == {:ok, -5}
    end

    test "accepts when min equals max and value matches" do
      assert Validation.validate_bounds(5, 5, 5) == {:ok, 5}
    end

    test "rejects value below lower bound" do
      assert Validation.validate_bounds(-1, 0, 100) == {:error, :out_of_bounds}
    end

    test "rejects value above upper bound" do
      assert Validation.validate_bounds(101, 0, 100) == {:error, :out_of_bounds}
    end

    test "rejects non-numeric value" do
      assert Validation.validate_bounds("50", 0, 100) == {:error, :out_of_bounds}
      assert Validation.validate_bounds(nil, 0, 100) == {:error, :out_of_bounds}
    end
  end

  describe "validate_list_types/2" do
    test "validates list of atoms" do
      assert Validation.validate_list_types([:a, :b, :c], :atom) == {:ok, [:a, :b, :c]}
    end

    test "validates list of strings" do
      assert Validation.validate_list_types(["a", "b"], :string) == {:ok, ["a", "b"]}
    end

    test "validates list of integers" do
      assert Validation.validate_list_types([1, 2, 3], :integer) == {:ok, [1, 2, 3]}
    end

    test "validates list of numbers including floats" do
      assert Validation.validate_list_types([1, 2.5, 3], :number) == {:ok, [1, 2.5, 3]}
    end

    test "validates list of maps" do
      maps = [%{a: 1}, %{b: 2}]
      assert Validation.validate_list_types(maps, :map) == {:ok, maps}
    end

    test "accepts empty list for any type" do
      assert Validation.validate_list_types([], :atom) == {:ok, []}
      assert Validation.validate_list_types([], :string) == {:ok, []}
      assert Validation.validate_list_types([], :integer) == {:ok, []}
      assert Validation.validate_list_types([], :number) == {:ok, []}
      assert Validation.validate_list_types([], :map) == {:ok, []}
    end

    test "rejects list with mixed types when expecting atoms" do
      assert Validation.validate_list_types([:a, "b"], :atom) == {:error, :invalid_types}
    end

    test "rejects list with wrong type" do
      assert Validation.validate_list_types(["a", "b"], :integer) == {:error, :invalid_types}
      assert Validation.validate_list_types([1, 2], :string) == {:error, :invalid_types}
      assert Validation.validate_list_types([1, 2], :atom) == {:error, :invalid_types}
    end

    test "integer type rejects floats" do
      assert Validation.validate_list_types([1, 2.5], :integer) == {:error, :invalid_types}
    end

    test "number type accepts both integers and floats" do
      assert Validation.validate_list_types([1, 2.5, 3], :number) == {:ok, [1, 2.5, 3]}
    end

    test "rejects unknown type specifier" do
      assert Validation.validate_list_types([1, 2], :unknown) == {:error, :invalid_types}
    end

    test "rejects non-list input" do
      assert Validation.validate_list_types("not a list", :atom) == {:error, :invalid_types}
      assert Validation.validate_list_types(nil, :atom) == {:error, :invalid_types}
      assert Validation.validate_list_types(42, :integer) == {:error, :invalid_types}
    end
  end

  describe "validate_string/1 (no pattern)" do
    test "accepts non-empty string" do
      assert Validation.validate_string("hello") == {:ok, "hello"}
    end

    test "accepts single character" do
      assert Validation.validate_string("a") == {:ok, "a"}
    end

    test "accepts string with whitespace" do
      assert Validation.validate_string("  ") == {:ok, "  "}
    end

    test "accepts unicode string" do
      assert Validation.validate_string("cafe\u0301") == {:ok, "cafe\u0301"}
    end

    test "rejects empty string" do
      assert Validation.validate_string("") == {:error, :invalid_string}
    end

    test "rejects non-binary types" do
      assert Validation.validate_string(nil) == {:error, :invalid_string}
      assert Validation.validate_string(123) == {:error, :invalid_string}
      assert Validation.validate_string(:atom) == {:error, :invalid_string}
      assert Validation.validate_string(~c"charlist") == {:error, :invalid_string}
    end
  end

  describe "validate_string/2 (with pattern)" do
    test "accepts string matching pattern" do
      assert Validation.validate_string("abc123", ~r/^[a-z0-9]+$/) == {:ok, "abc123"}
    end

    test "rejects string not matching pattern" do
      assert Validation.validate_string("ABC", ~r/^[a-z]+$/) == {:error, :invalid_string}
    end

    test "accepts string matching email-like pattern" do
      assert Validation.validate_string("user@example.com", ~r/@/) ==
               {:ok, "user@example.com"}
    end

    test "rejects empty string even with permissive pattern" do
      assert Validation.validate_string("", ~r/.*/) == {:error, :invalid_string}
    end

    test "nil pattern behaves as no-pattern validation" do
      assert Validation.validate_string("hello", nil) == {:ok, "hello"}
    end

    test "rejects non-binary with pattern" do
      assert Validation.validate_string(123, ~r/\d+/) == {:error, :invalid_string}
    end
  end

  describe "validate_enum/2" do
    test "accepts value in allowed list of atoms" do
      assert Validation.validate_enum(:red, [:red, :green, :blue]) == {:ok, :red}
    end

    test "accepts value in allowed list of strings" do
      assert Validation.validate_enum("yes", ["yes", "no"]) == {:ok, "yes"}
    end

    test "accepts value in allowed list of integers" do
      assert Validation.validate_enum(1, [1, 2, 3]) == {:ok, 1}
    end

    test "accepts value in mixed-type allowed list" do
      assert Validation.validate_enum(:a, [:a, "b", 3]) == {:ok, :a}
    end

    test "rejects value not in allowed list" do
      assert Validation.validate_enum(:yellow, [:red, :green, :blue]) ==
               {:error, :invalid_option}
    end

    test "rejects nil when not in allowed list" do
      assert Validation.validate_enum(nil, [:a, :b]) == {:error, :invalid_option}
    end

    test "accepts nil when explicitly in allowed list" do
      assert Validation.validate_enum(nil, [nil, :a, :b]) == {:ok, nil}
    end

    test "rejects any value when allowed list is empty" do
      assert Validation.validate_enum(:a, []) == {:error, :invalid_option}
    end

    test "rejects when allowed is not a list" do
      assert Validation.validate_enum(:a, :not_a_list) == {:error, :invalid_option}
      assert Validation.validate_enum(:a, nil) == {:error, :invalid_option}
    end
  end
end
