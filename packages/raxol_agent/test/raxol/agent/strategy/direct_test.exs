defmodule Raxol.Agent.Strategy.DirectTest do
  use ExUnit.Case, async: true

  alias Raxol.Agent.Strategy.Direct

  defmodule Increment do
    use Raxol.Agent.Action,
      name: "increment",
      description: "Increment a counter",
      schema: [input: [by: [type: :integer, default: 1]]]

    @impl true
    def run(%{by: by}, _ctx), do: {:ok, %{count: (Map.get(%{}, :count, 0) || 0) + by}}
  end

  defmodule Double do
    use Raxol.Agent.Action,
      name: "double",
      description: "Double the count",
      schema: [input: [count: [type: :integer, required: true]]]

    @impl true
    def run(%{count: c}, _ctx), do: {:ok, %{count: c * 2}}
  end

  defmodule WithCommand do
    use Raxol.Agent.Action,
      name: "with_cmd",
      description: "Returns a command",
      schema: [input: []]

    @impl true
    def run(_params, _ctx) do
      cmd = Raxol.Core.Runtime.Directive.schedule(100, :ping)
      {:ok, %{notified: true}, [cmd]}
    end
  end

  defmodule Failing do
    use Raxol.Agent.Action,
      name: "fail",
      description: "Always fails",
      schema: [input: []]

    @impl true
    def run(_params, _ctx), do: {:error, :kaboom}
  end

  describe "execute/3 with single action" do
    test "merges result into state" do
      state = %{count: 0, name: "test"}
      assert {:ok, new_state} = Direct.execute({Increment, %{by: 5}}, state, %{})
      assert new_state.count == 5
      assert new_state.name == "test"
    end

    test "passes through commands" do
      assert {:ok, state, [cmd]} = Direct.execute({WithCommand, %{}}, %{}, %{})
      assert state.notified == true
      assert %Raxol.Core.Runtime.Directive.Schedule{} = cmd
    end

    test "returns error on failure" do
      assert {:error, :kaboom} = Direct.execute({Failing, %{}}, %{}, %{})
    end
  end

  describe "execute/3 with pipeline" do
    test "runs steps sequentially" do
      steps = [{Increment, %{by: 3}}, {Double, %{}}]
      state = %{count: 0}
      assert {:ok, result, []} = Direct.execute(steps, state, %{})
      assert result.count == 6
    end

    test "short-circuits pipeline on error" do
      steps = [{Increment, %{by: 1}}, {Failing, %{}}, {Double, %{}}]
      assert {:error, :kaboom} = Direct.execute(steps, %{count: 0}, %{})
    end
  end
end
