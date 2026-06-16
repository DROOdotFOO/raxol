defmodule Raxol.Agent.Authorization.LabelsTest do
  use ExUnit.Case, async: true

  alias Raxol.Agent.Authorization.Labels

  @monotonic %{access: [:read, :write, :admin], risk: [:low, :medium, :high]}

  describe "merge/3" do
    test "non-monotonic keys take the written value (last-write-wins)" do
      assert Labels.merge(%{a: 1}, %{a: 2, b: 3}) == %{a: 2, b: 3}
    end

    test "monotonic keys keep the most-restrictive value" do
      labels = Labels.merge(%{}, %{access: :write}, @monotonic)
      # A less-restrictive write does not loosen it.
      assert Labels.merge(labels, %{access: :read}, @monotonic) == %{access: :write}
      # A more-restrictive write tightens it.
      assert Labels.merge(labels, %{access: :admin}, @monotonic) == %{access: :admin}
    end

    test "a first write to a monotonic key sets it" do
      assert Labels.merge(%{}, %{risk: :medium}, @monotonic) == %{risk: :medium}
    end

    test "an unranked value is least-restrictive (rank -1)" do
      labels = Labels.merge(%{}, %{access: :unknown}, @monotonic)
      assert Labels.merge(labels, %{access: :read}, @monotonic) == %{access: :read}
    end
  end
end
