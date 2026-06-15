defmodule Raxol.Agent.Action.PipelineTest do
  use ExUnit.Case, async: true

  alias Raxol.Agent.Action.Pipeline

  defmodule StepA do
    use Raxol.Agent.Action,
      name: "step_a",
      description: "Doubles the value",
      schema: [input: [value: [type: :integer, required: true]]]

    @impl true
    def run(%{value: v}, _ctx), do: {:ok, %{value: v * 2}}
  end

  defmodule StepB do
    use Raxol.Agent.Action,
      name: "step_b",
      description: "Adds 10",
      schema: [input: [value: [type: :integer, required: true]]]

    @impl true
    def run(%{value: v}, _ctx), do: {:ok, %{value: v + 10}}
  end

  defmodule StepWithCommand do
    use Raxol.Agent.Action,
      name: "step_cmd",
      description: "Returns a command",
      schema: [input: [value: [type: :integer, required: true]]]

    @impl true
    def run(%{value: v}, _ctx) do
      cmd = Raxol.Core.Runtime.Directive.schedule(100, :tick)
      {:ok, %{value: v + 1}, [cmd]}
    end
  end

  defmodule FailingStep do
    use Raxol.Agent.Action,
      name: "fail_step",
      description: "Always fails",
      schema: [input: []]

    @impl true
    def run(_params, _ctx), do: {:error, :boom}
  end

  defmodule ContextReader do
    use Raxol.Agent.Action,
      name: "ctx_reader",
      description: "Reads from context",
      schema: [input: []]

    @impl true
    def run(_params, context) do
      {:ok, %{env: Map.get(context, :env, "unknown")}}
    end
  end

  describe "run/3" do
    test "runs actions sequentially, merging results" do
      assert {:ok, result, []} = Pipeline.run([StepA, StepB], %{value: 5})
      # 5 * 2 = 10, then 10 + 10 = 20
      assert result.value == 20
    end

    test "preserves initial params through pipeline" do
      assert {:ok, result, []} = Pipeline.run([StepA], %{value: 3, extra: "kept"})
      assert result.value == 6
      assert result.extra == "kept"
    end

    test "accumulates commands from all steps" do
      assert {:ok, result, commands} =
               Pipeline.run([StepWithCommand, StepWithCommand], %{value: 0})

      assert result.value == 2
      assert length(commands) == 2
    end

    test "short-circuits on error" do
      assert {:error, {FailingStep, :boom}} =
               Pipeline.run([StepA, FailingStep, StepB], %{value: 5})
    end

    test "supports tuple steps with extra params" do
      assert {:ok, result, []} =
               Pipeline.run([{StepA, %{value: 7}}], %{})

      assert result.value == 14
    end

    test "step params override shared state" do
      assert {:ok, result, []} =
               Pipeline.run([StepA, {StepB, %{value: 100}}], %{value: 3})

      # StepA: 3 * 2 = 6, StepB gets value=100 from override, 100 + 10 = 110
      assert result.value == 110
    end

    test "passes context to all actions" do
      assert {:ok, result, []} =
               Pipeline.run([ContextReader], %{}, %{env: "test"})

      assert result.env == "test"
    end

    test "empty pipeline returns initial params" do
      assert {:ok, %{value: 42}, []} = Pipeline.run([], %{value: 42})
    end
  end
end
