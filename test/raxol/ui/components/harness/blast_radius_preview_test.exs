defmodule Raxol.UI.Components.Harness.BlastRadiusPreviewTest do
  use ExUnit.Case, async: true

  alias Raxol.Core.Events.Event
  alias Raxol.UI.Components.Harness.BlastRadiusPreview

  defp default_context do
    %{theme: Raxol.UI.Theming.Theme.default_theme()}
  end

  defp find_by_id(children, id), do: Enum.find(children, &(&1[:id] == id))

  describe "init/1" do
    test "defaults to an empty blast radius" do
      assert {:ok, state} = BlastRadiusPreview.init(id: :bp1)
      assert state.id == :bp1
      assert state.blast_radius == %{}
      assert state.style == %{}
      assert state.theme == %{}
    end

    test "keeps the provided blast radius as-is" do
      br = %{deletes: ["/tmp/a"], reversible: false}
      assert {:ok, state} = BlastRadiusPreview.init(id: :bp2, blast_radius: br)
      assert state.blast_radius == br
    end
  end

  describe "render/2 — empty blast radius" do
    test "renders a calm placeholder line, no marker" do
      {:ok, state} = BlastRadiusPreview.init(id: :bp_empty)
      rendered = BlastRadiusPreview.render(state, default_context())

      assert rendered.type == :column
      assert [line] = rendered.children
      assert line.content == "No tracked effects."
      assert line.style == %{dim: true}
    end
  end

  describe "render/2 — deletes" do
    test "always renders deletes red and bold, even when reversible" do
      {:ok, state} =
        BlastRadiusPreview.init(
          id: :bp_del,
          blast_radius: %{deletes: ["/tmp/a", "/tmp/b"], reversible: true}
        )

      rendered = BlastRadiusPreview.render(state, default_context())

      header = find_by_id(rendered.children, "bp_del-deletes-header")
      assert header.content == "✗ Delete (2)"
      assert header.fg == :red
      assert header.style == %{bold: true}

      item0 = find_by_id(rendered.children, "bp_del-deletes-0")
      assert item0.content == "  /tmp/a"
      assert item0.fg == :red
      assert item0.style == %{dim: false}

      # No IRREVERSIBLE marker when reversible: true
      refute find_by_id(rendered.children, "bp_del-irreversible")
    end
  end

  describe "render/2 — reversible: false" do
    test "shows the IRREVERSIBLE marker and escalates every group to loud" do
      {:ok, state} =
        BlastRadiusPreview.init(
          id: :bp_irr,
          blast_radius: %{
            deletes: ["/tmp/a"],
            writes: ["/tmp/b"],
            reversible: false
          }
        )

      rendered = BlastRadiusPreview.render(state, default_context())

      marker = find_by_id(rendered.children, "bp_irr-irreversible")
      assert marker.content == "⚠ IRREVERSIBLE: this action cannot be undone"
      assert marker.fg == :red
      assert marker.style == %{bold: true}

      # writes is not always_loud, but reversible: false escalates it anyway
      write_header = find_by_id(rendered.children, "bp_irr-writes-header")
      assert write_header.style == %{bold: true}

      write_item = find_by_id(rendered.children, "bp_irr-writes-0")
      assert write_item.style == %{dim: false}
    end

    test "reversible: true keeps non-delete groups dim" do
      {:ok, state} =
        BlastRadiusPreview.init(
          id: :bp_dim,
          blast_radius: %{commands: ["rm -rf /tmp/x"], reversible: true}
        )

      rendered = BlastRadiusPreview.render(state, default_context())

      header = find_by_id(rendered.children, "bp_dim-commands-header")
      assert header.content == "▲ Run (1)"
      assert header.fg == :yellow
      assert header.style == %{bold: false}

      item = find_by_id(rendered.children, "bp_dim-commands-0")
      assert item.fg == nil
      assert item.style == %{dim: true}
    end

    test "missing :reversible defaults to true (non-delete groups stay dim)" do
      {:ok, state} =
        BlastRadiusPreview.init(
          id: :bp_default,
          blast_radius: %{network: ["api.example.com"]}
        )

      rendered = BlastRadiusPreview.render(state, default_context())

      header = find_by_id(rendered.children, "bp_default-network-header")
      assert header.style == %{bold: false}
    end
  end

  describe "estimate_rows/1" do
    test "is 1 for an empty blast radius (the placeholder line)" do
      assert BlastRadiusPreview.estimate_rows(%{}) == 1
    end

    test "counts header + items with no gap for a single group" do
      assert BlastRadiusPreview.estimate_rows(%{deletes: ["a"]}) == 2
    end

    test "accounts for the marker row and inter-group gaps" do
      br = %{reversible: false, deletes: ["a", "b"], writes: ["c"]}

      # marker(1) + delete header+items(1+2) + write header+items(1+1) + gaps(2) = 8
      assert BlastRadiusPreview.estimate_rows(br) == 8
    end
  end

  describe "handle_event/3" do
    test "passes through all events unchanged (non-interactive)" do
      {:ok, state} =
        BlastRadiusPreview.init(
          id: :bp_evt,
          blast_radius: %{deletes: ["/tmp/a"]}
        )

      event = %Event{type: :key, data: %{key: :enter}}
      assert {^state, []} = BlastRadiusPreview.handle_event(event, state, %{})
    end
  end
end
