defmodule Mix.Tasks.Raxol.CheckDocsCountsTest do
  @moduledoc """
  The count gate in `mix raxol.check_docs`.

  Two numbers had drifted in prose with nothing to contradict them ("23
  widgets" in the roadmap, "15 widgets" before it) because the check derived
  demo and category counts only. These tests pin the two properties that stop
  it recurring: a widget claim is measured against `Raxol.UI.Registry`, and a
  demo claim is still measured against `Raxol.Playground.Catalog` even when the
  word "widget" appears in the sentence.
  """
  use ExUnit.Case, async: true

  alias Mix.Tasks.Raxol.CheckDocs

  defp scan(text) do
    CheckDocs.scan_counts([{"probe.md", text}], CheckDocs.count_sources())
  end

  defp widgets, do: length(Raxol.UI.Registry.list())
  defp demos, do: length(Raxol.Playground.Catalog.list_components())

  describe "widget counts" do
    test "a count the registry does not produce is reported against it" do
      assert [finding] = scan("The framework ships #{widgets() + 7} widgets.")

      assert finding =~ "probe.md:1:"
      assert finding =~ "says #{widgets() + 7} widgets"
      assert finding =~ "Raxol.UI.Registry has #{widgets()}"
    end

    test "the registry's own count passes in every qualified form" do
      assert scan("Raxol has #{widgets()} widgets.") == []
      assert scan("#{widgets()} core widgets.") == []
      assert scan("#{widgets()} first-class widget types.") == []
      assert scan("#{widgets()} registered widget types.") == []
    end

    test "a wrong count is reported wherever it sits in the file" do
      text = "intro\n\nsecond paragraph\n\n#{widgets() + 1} widgets ship."

      assert [finding] = scan(text)
      assert finding =~ "probe.md:5:"
    end
  end

  describe "widgets are not demos" do
    test "a widget-demo count is measured against the catalog" do
      # The whole reason the two checks are separate. If these ever coincide
      # this test proves nothing, so it says so rather than passing quietly.
      refute demos() == widgets()

      assert scan("#{demos()} widget demos across 8 categories") == []

      assert [finding] = scan("#{widgets()} widget demos")
      assert finding =~ "says #{widgets()} demos"
      assert finding =~ "Raxol.Playground.Catalog has #{demos()}"
    end

    test "the catalog count is not accepted as a widget count" do
      assert [finding] = scan("#{demos()} widgets")
      assert finding =~ "Raxol.UI.Registry has #{widgets()}"
    end
  end

  describe "ToolProvider implementations" do
    test "the claim is measured against the registry's MCP types" do
      mcp = length(Raxol.UI.Registry.mcp_types())

      assert scan("#{mcp} Component modules implement `ToolProvider`") == []

      assert [finding] = scan("#{mcp + 2} Component modules implement it")
      assert finding =~ "Raxol.UI.Registry.mcp_types/0 has #{mcp}"
    end
  end
end
