defmodule Raxol.UI.ColorIntentTest do
  @moduledoc """
  Struct-shape coverage for `Raxol.UI.ColorIntent`. Resolution behavior
  lives in `Raxol.UI.ColorResolverTest` -- this file only pins the default
  field values §3.1 specifies.
  """

  use ExUnit.Case, async: true

  alias Raxol.UI.ColorIntent

  test "defaults match the design doc's §3.1 struct" do
    intent = %ColorIntent{}

    assert intent.h == nil
    assert intent.c == 0.0
    assert intent.tier == nil
    assert intent.prominence == nil
    assert intent.role == nil
    assert intent.floor == :none
  end

  test "fixed/1 wraps a literal color in the escape-hatch convention" do
    assert ColorIntent.fixed(:white) == {:fixed, :white}
    assert ColorIntent.fixed("#ffffff") == {:fixed, "#ffffff"}
  end

  test "fixed?/1 recognizes only the {:fixed, _} shape" do
    assert ColorIntent.fixed?({:fixed, :white})
    refute ColorIntent.fixed?(:white)
    refute ColorIntent.fixed?(%ColorIntent{})
    refute ColorIntent.fixed?(nil)
  end
end
