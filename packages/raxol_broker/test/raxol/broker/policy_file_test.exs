defmodule Raxol.Broker.PolicyFileTest do
  use ExUnit.Case, async: true

  alias Raxol.Broker.PolicyFile

  @max_file_size 16 * 1024

  setup do
    directory =
      Path.join(
        System.tmp_dir!(),
        "broker-policy-#{System.unique_integer([:positive, :monotonic])}"
      )

    File.mkdir_p!(directory)
    on_exit(fn -> File.rm_rf!(directory) end)

    %{directory: directory}
  end

  test "loads the generated policy syntax", %{directory: directory} do
    path = write_policy(directory, valid_policy_source())

    assert {:ok, policy} = PolicyFile.load(path)
    assert Decimal.equal?(policy[:max_notional_per_order], Decimal.new("1000"))
    assert Decimal.equal?(policy[:daily_notional_cap], Decimal.new("5000"))
    assert policy[:max_position_weight] == :unset
    assert policy[:order_types] == [:limit]
    assert policy[:options] == false
    assert policy[:after_hours_market] == false
    assert policy[:llm_ask_above] == :unset
    assert policy[:ask_timeout] == 30_000
  end

  test "reports every missing key with that key", %{directory: directory} do
    for key <- Keyword.keys(source_values()) do
      source = source_values() |> Keyword.delete(key) |> policy_source()
      path = write_policy(directory, source, "missing-#{key}.exs")

      assert {:error, {:missing_key, ^key}} = PolicyFile.load(path)
    end
  end

  test "rejects duplicate and unknown keys distinctly", %{directory: directory} do
    duplicate_source =
      policy_source(source_values() ++ [max_notional_per_order: ~s|Decimal.new("1")|])

    duplicate_path = write_policy(directory, duplicate_source, "duplicate.exs")

    assert {:error, {:invalid_policy, {:duplicate_key, :max_notional_per_order}}} =
             PolicyFile.load(duplicate_path)

    unknown_source = policy_source(source_values() ++ [market: "false"])
    unknown_path = write_policy(directory, unknown_source, "unknown.exs")

    assert {:error, {:invalid_policy, {:unknown_key, :market}}} =
             PolicyFile.load(unknown_path)
  end

  test "rejects non-keyword policy data as validation errors", %{directory: directory} do
    path = write_policy(directory, "false")

    assert {:error, {:invalid_policy, :not_a_keyword_list}} = PolicyFile.load(path)
    assert {:error, {:invalid_policy, :not_a_keyword_list}} = PolicyFile.validate(%{})
  end

  test "rejects unset required caps with their keys" do
    for key <- [:max_notional_per_order, :daily_notional_cap] do
      assert {:error, {:unset, ^key}} =
               valid_policy()
               |> Keyword.put(key, :unset)
               |> PolicyFile.validate()
    end
  end

  test "rejects zero, negative, and non-finite required caps with their keys" do
    invalid_values = [
      Decimal.new("0"),
      Decimal.new("-1"),
      Decimal.new("NaN"),
      Decimal.new("Infinity"),
      Decimal.new("-Infinity")
    ]

    for key <- [:max_notional_per_order, :daily_notional_cap],
        value <- invalid_values do
      assert {:error, {:invalid_value, ^key, ^value}} =
               valid_policy()
               |> Keyword.put(key, value)
               |> PolicyFile.validate()
    end
  end

  test "loads exact Decimal.new calls and validates their values", %{directory: directory} do
    negative_path =
      write_policy(
        directory,
        valid_policy_source(max_notional_per_order: ~s|Decimal.new("-1")|),
        "negative.exs"
      )

    assert {:error, {:invalid_value, :max_notional_per_order, negative}} =
             PolicyFile.load(negative_path)

    assert Decimal.equal?(negative, Decimal.new("-1"))

    non_finite_path =
      write_policy(
        directory,
        valid_policy_source(daily_notional_cap: ~s|Decimal.new("NaN")|),
        "non-finite.exs"
      )

    assert {:error, {:invalid_value, :daily_notional_cap, %Decimal{coef: :NaN}}} =
             PolicyFile.load(non_finite_path)
  end

  test "validates the optional decimal ranges" do
    assert {:ok, _policy} =
             valid_policy()
             |> Keyword.put(:max_position_weight, Decimal.new("1"))
             |> Keyword.put(:llm_ask_above, Decimal.new("0.01"))
             |> PolicyFile.validate()

    assert {:ok, _policy} = PolicyFile.validate(valid_policy())

    invalid_values = [
      {:max_position_weight, Decimal.new("0")},
      {:max_position_weight, Decimal.new("-0.1")},
      {:max_position_weight, Decimal.new("1.01")},
      {:max_position_weight, Decimal.new("NaN")},
      {:llm_ask_above, Decimal.new("0")},
      {:llm_ask_above, Decimal.new("-1")},
      {:llm_ask_above, Decimal.new("Infinity")}
    ]

    for {key, value} <- invalid_values do
      assert {:error, {:invalid_value, ^key, ^value}} =
               valid_policy()
               |> Keyword.put(key, value)
               |> PolicyFile.validate()
    end
  end

  test "rejects wrong types for every schema value" do
    invalid_values = [
      max_notional_per_order: "1000",
      daily_notional_cap: 5000,
      max_position_weight: 1,
      order_types: :limit,
      options: :unset,
      after_hours_market: 0,
      llm_ask_above: "10",
      ask_timeout: Decimal.new("30")
    ]

    for {key, value} <- invalid_values do
      assert {:error, {:invalid_value, ^key, ^value}} =
               valid_policy()
               |> Keyword.put(key, value)
               |> PolicyFile.validate()
    end
  end

  test "validates order types", %{directory: directory} do
    assert {:ok, _policy} =
             valid_policy()
             |> Keyword.put(:order_types, [:market, :limit])
             |> PolicyFile.validate()

    for value <- [[], [:unset], [:market, :market], :limit] do
      assert {:error, {:invalid_value, :order_types, ^value}} =
               valid_policy()
               |> Keyword.put(:order_types, value)
               |> PolicyFile.validate()
    end

    path =
      write_policy(
        directory,
        valid_policy_source(order_types: "[:limit, :unset]"),
        "invalid-order-type.exs"
      )

    assert {:error, {:invalid_value, :order_types, [:limit, :unset]}} =
             PolicyFile.load(path)
  end

  test "validates the timeout" do
    assert {:ok, _policy} =
             valid_policy()
             |> Keyword.put(:ask_timeout, 1)
             |> PolicyFile.validate()

    for value <- [0, -1, :unset, 1.0] do
      assert {:error, {:invalid_value, :ask_timeout, ^value}} =
               valid_policy()
               |> Keyword.put(:ask_timeout, value)
               |> PolicyFile.validate()
    end
  end

  test "distinguishes missing files and read failures", %{directory: directory} do
    missing_path = Path.join(directory, "missing.exs")

    assert {:error, {:missing_file, ^missing_path}} = PolicyFile.load(missing_path)
    assert {:error, {:read_failed, ^directory, :eisdir}} = PolicyFile.load(directory)
  end

  test "rejects malformed source as a parse error", %{directory: directory} do
    path = write_policy(directory, "[max_notional_per_order:")

    assert {:error, {:parse_error, ^path, _reason}} = PolicyFile.load(path)
  end

  test "parses with existing atoms only", %{directory: directory} do
    atom_name = "raxol_policy_untrusted_#{System.unique_integer([:positive, :monotonic])}"

    path =
      write_policy(
        directory,
        valid_policy_source(order_types: "[:#{atom_name}]"),
        "new-atom.exs"
      )

    assert {:error, {:parse_error, ^path, _reason}} = PolicyFile.load(path)
    assert_raise ArgumentError, fn -> String.to_existing_atom(atom_name) end
  end

  test "rejects calls, assignments, operators, aliases, and blocks", %{directory: directory} do
    expressions = [
      "File.cwd!()",
      "options = true",
      "1 + 1",
      "Kernel.inspect(\"value\")",
      "Decimal.parse(\"1\")",
      "Decimal.new(1)",
      "Decimal.new(\"1\", \"2\")",
      "Elixir.Decimal.new(\"1\")",
      "(true; false)",
      "%{}"
    ]

    for {expression, index} <- Enum.with_index(expressions) do
      path =
        write_policy(
          directory,
          valid_policy_source(options: expression),
          "unsupported-#{index}.exs"
        )

      assert {:error, {:unsupported_expression, _quoted}} = PolicyFile.load(path)
    end
  end

  test "rejects malformed Decimal.new values without raising", %{directory: directory} do
    path =
      write_policy(
        directory,
        valid_policy_source(max_notional_per_order: ~s|Decimal.new("not a decimal")|),
        "malformed-decimal.exs"
      )

    assert {:error, {:unsupported_expression, _quoted}} = PolicyFile.load(path)
  end

  test "rejects throw and exit without a control-flow escape", %{directory: directory} do
    for {expression, filename} <- [{"throw(:unset)", "throw.exs"}, {"exit(:unset)", "exit.exs"}] do
      path = write_policy(directory, valid_policy_source(options: expression), filename)

      assert {:error, {:unsupported_expression, _quoted}} = PolicyFile.load(path)
    end
  end

  test "rejects side effects without executing them", %{directory: directory} do
    marker = Path.join(directory, "side-effect")

    source =
      valid_policy_source() <>
        ~s|File.write!(#{inspect(marker)}, "policy source was executed")\n|

    path = write_policy(directory, source, "side-effect.exs")

    assert {:error, {:unsupported_expression, _quoted}} = PolicyFile.load(path)
    refute File.exists?(marker)
  end

  test "rejects oversized files before parsing", %{directory: directory} do
    oversized_size = @max_file_size + 1
    path = write_policy(directory, String.duplicate(" ", oversized_size), "oversized.exs")

    assert {:error, {:file_too_large, ^path, ^oversized_size, @max_file_size}} =
             PolicyFile.load(path)
  end

  defp valid_policy(overrides \\ []) do
    Keyword.merge(
      [
        max_notional_per_order: Decimal.new("1000"),
        daily_notional_cap: Decimal.new("5000"),
        max_position_weight: :unset,
        order_types: [:limit],
        options: false,
        after_hours_market: false,
        llm_ask_above: :unset,
        ask_timeout: 30_000
      ],
      overrides
    )
  end

  defp valid_policy_source(overrides \\ []) do
    source_values()
    |> Keyword.merge(overrides)
    |> policy_source()
  end

  defp source_values do
    [
      max_notional_per_order: ~s|Decimal.new("1000")|,
      daily_notional_cap: ~s|Decimal.new("5000")|,
      max_position_weight: ":unset",
      order_types: "[:limit]",
      options: "false",
      after_hours_market: "false",
      llm_ask_above: ":unset",
      ask_timeout: "30_000"
    ]
  end

  defp policy_source(values) do
    body = Enum.map_join(values, ",\n", fn {key, value} -> "  #{key}: #{value}" end)
    "[\n#{body}\n]\n"
  end

  defp write_policy(directory, source, filename \\ "broker.policy.exs") do
    path = Path.join(directory, filename)
    File.write!(path, source)
    path
  end
end
