defmodule Raxol.Agent.Authorization.VerdictTest do
  use ExUnit.Case, async: true

  alias Raxol.Agent.Authorization.Verdict

  test "allow/1 builds an allow verdict" do
    assert %Verdict{action: :allow, writes: %{}} = Verdict.allow()
    assert %Verdict{action: :allow, writes: %{a: 1}} = Verdict.allow(%{a: 1})
  end

  test "ask/2 builds an ask verdict with a prompt and escrowed writes" do
    assert %Verdict{action: :ask, prompt: "ok?", writes: %{a: 1}} = Verdict.ask("ok?", %{a: 1})
  end

  test "deny/1 builds a deny verdict with a reason" do
    assert %Verdict{action: :deny, reason: :nope} = Verdict.deny(:nope)
  end
end
