defmodule Raxol.Agent.ActionTest do
  use ExUnit.Case, async: true

  defmodule Adder do
    use Raxol.Agent.Action,
      name: "add",
      description: "Add two numbers",
      schema: [
        input: [
          a: [type: :integer, required: true, description: "First number"],
          b: [type: :integer, required: true, description: "Second number"]
        ],
        output: [
          sum: [type: :integer]
        ]
      ]

    @impl true
    def run(%{a: a, b: b}, _context) do
      {:ok, %{sum: a + b}}
    end
  end

  defmodule Greeter do
    use Raxol.Agent.Action,
      name: "greet",
      description: "Greet someone",
      schema: [
        input: [
          name: [type: :string, required: true],
          greeting: [type: :string, default: "Hello"]
        ]
      ]

    @impl true
    def run(%{name: name, greeting: greeting}, _context) do
      {:ok, %{message: "#{greeting}, #{name}!"}}
    end
  end

  defmodule WithHooks do
    use Raxol.Agent.Action,
      name: "hooked",
      description: "Action with lifecycle hooks",
      schema: [
        input: [value: [type: :integer, required: true]]
      ]

    @impl true
    def before_validate(params) do
      case params do
        %{value: v} when is_binary(v) -> %{params | value: String.to_integer(v)}
        _ -> params
      end
    end

    @impl true
    def run(%{value: value}, _context) do
      {:ok, %{doubled: value * 2}}
    end

    @impl true
    def after_run(output, _context) do
      Map.put(output, :processed, true)
    end
  end

  defmodule WithCommands do
    use Raxol.Agent.Action,
      name: "with_commands",
      description: "Returns commands alongside result",
      schema: [input: [msg: [type: :string, required: true]]]

    @impl true
    def run(%{msg: msg}, _context) do
      cmd = Raxol.Core.Runtime.Directive.schedule(1000, :reminder)
      {:ok, %{sent: msg}, [cmd]}
    end
  end

  defmodule Failing do
    use Raxol.Agent.Action,
      name: "fail",
      description: "Always fails",
      schema: [input: []]

    @impl true
    def run(_params, _context) do
      {:error, :intentional_failure}
    end
  end

  defmodule NoSchema do
    use Raxol.Agent.Action,
      name: "bare",
      description: "No schema at all"

    @impl true
    def run(params, _context) do
      {:ok, params}
    end
  end

  describe "call/2" do
    test "runs action with valid input" do
      assert {:ok, %{sum: 5}} = Adder.call(%{a: 2, b: 3})
    end

    test "applies defaults" do
      assert {:ok, %{message: "Hello, World!"}} = Greeter.call(%{name: "World"})
    end

    test "overrides defaults with explicit values" do
      assert {:ok, %{message: "Hi, World!"}} = Greeter.call(%{name: "World", greeting: "Hi"})
    end

    test "returns validation error on missing required field" do
      assert {:error, errors} = Adder.call(%{a: 1})
      assert {_field, _reason} = List.keyfind(errors, :b, 0)
    end

    test "returns validation error on wrong type" do
      assert {:error, _} = Adder.call(%{a: "not_int", b: 2})
    end

    test "returns error from run/2" do
      assert {:error, :intentional_failure} = Failing.call(%{})
    end

    test "passes through commands from run/2" do
      assert {:ok, %{sent: "hi"}, [%Raxol.Core.Runtime.Directive.Schedule{}]} =
               WithCommands.call(%{msg: "hi"})
    end

    test "works with no schema" do
      assert {:ok, %{foo: "bar"}} = NoSchema.call(%{foo: "bar"})
    end

    test "accepts context parameter" do
      assert {:ok, %{sum: 3}} = Adder.call(%{a: 1, b: 2}, %{user: "test"})
    end
  end

  describe "lifecycle hooks" do
    test "before_validate transforms params" do
      assert {:ok, %{doubled: 10, processed: true}} = WithHooks.call(%{value: "5"})
    end

    test "after_run transforms output" do
      assert {:ok, %{doubled: 8, processed: true}} = WithHooks.call(%{value: 4})
    end
  end

  describe "__action_meta__/0" do
    test "returns action metadata" do
      meta = Adder.__action_meta__()
      assert meta.name == "add"
      assert meta.description == "Add two numbers"
      assert length(meta.input_schema) == 2
      assert length(meta.output_schema) == 1
    end
  end

  describe "to_tool_definition/0" do
    test "generates valid tool definition" do
      tool = Adder.to_tool_definition()
      assert tool["type"] == "function"
      assert tool["function"]["name"] == "add"
      assert tool["function"]["description"] == "Add two numbers"

      props = tool["function"]["parameters"]["properties"]
      assert props["a"]["type"] == "integer"
      assert props["b"]["type"] == "integer"
      assert "a" in tool["function"]["parameters"]["required"]
      assert "b" in tool["function"]["parameters"]["required"]
    end
  end

  describe "output validation" do
    test "validates output against output schema" do
      # Adder has output schema [sum: [type: :integer]]
      # The run/2 returns %{sum: integer}, so it passes
      assert {:ok, %{sum: 7}} = Adder.call(%{a: 3, b: 4})
    end
  end
end
