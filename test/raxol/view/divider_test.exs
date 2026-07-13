defmodule Raxol.View.DividerTest do
  @moduledoc """
  A divider is a border's horizontal run: it draws with the same charset, so a
  `:single` divider and a `:single` border match by construction.
  """
  use ExUnit.Case, async: true

  import Raxol.View.Components, only: [divider: 0, divider: 1]

  alias Raxol.UI.BorderRenderer

  test "defaults to box-drawing, matching a :single border's horizontal run" do
    assert %{type: :divider, char: "─"} = divider()
    assert divider().char == BorderRenderer.get_border_chars(:single).horizontal
  end

  test "variant draws the matching border charset" do
    for variant <- [:single, :double, :rounded, :ascii, :none] do
      expected = BorderRenderer.get_border_chars(variant).horizontal
      assert divider(variant: variant).char == expected
    end

    assert divider(variant: :double).char == "═"
    assert divider(variant: :ascii).char == "-"
  end

  test "an unknown variant draws :single, never the blank :none run" do
    # BorderRenderer's catch-all maps anything unrecognised to :none, whose
    # horizontal run is a space -- a typo must not render an invisible divider.
    assert divider(variant: :heavy).char == "─"
    assert divider(variant: :nonsense).char == "─"
  end

  test "an explicit char wins over the variant" do
    assert divider(char: "=").char == "="
    assert divider(char: "=", variant: :double).char == "="
  end
end
