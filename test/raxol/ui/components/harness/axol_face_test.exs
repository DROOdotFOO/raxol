defmodule Raxol.UI.Components.Harness.AxolFaceTest do
  use ExUnit.Case, async: true

  alias Raxol.UI.Components.Harness.AxolFace

  defp default_context, do: %{theme: Raxol.UI.Theming.Theme.default_theme()}
  defp face_el(rendered), do: Enum.at(rendered.children, 0)

  describe "glyph/3 (the shared core)" do
    test "every face is exactly four display columns wide" do
      for state <- AxolFace.states(), ascii? <- [false, true], frame <- 0..5 do
        glyph = AxolFace.glyph(state, frame, ascii?)

        assert Raxol.UI.TextMeasure.display_width(glyph) == 4,
               "#{state}/#{ascii?}/#{frame} = #{inspect(glyph)} not 4 cols"
      end
    end

    test "idle at rest is the branded neutral face" do
      assert AxolFace.glyph(:idle, 0) == "≡··≡"
    end

    test "working pulses the pupils across frames" do
      assert AxolFace.glyph(:working, 0) == "≡oo≡"
      assert AxolFace.glyph(:working, 1) == "≡OO≡"
      # wraps
      assert AxolFace.glyph(:working, 2) == "≡oo≡"
    end

    test "done and error are their fixed motifs" do
      assert AxolFace.glyph(:done, 3) == "≡^^≡"
      assert AxolFace.glyph(:error, 7) == "≡xx≡"
    end

    test "ascii fallback uses = gills and ASCII eyes only" do
      for state <- AxolFace.states(), frame <- 0..3 do
        glyph = AxolFace.glyph(state, frame, true)
        assert String.printable?(glyph)

        assert glyph
               |> String.to_charlist()
               |> Enum.all?(&(&1 < 128)),
               "#{state}/#{frame} = #{inspect(glyph)} is not ASCII"
      end

      assert AxolFace.glyph(:idle, 0, true) == "=..="
    end

    test "frame wraps over the cycle length for any non-negative integer" do
      assert AxolFace.glyph(:thinking, 0) == AxolFace.glyph(:thinking, 3)
      assert AxolFace.glyph(:thinking, 1) == AxolFace.glyph(:thinking, 4)
    end
  end

  describe "color/1" do
    test "maps state to a status color" do
      assert AxolFace.color(:idle) == nil
      assert AxolFace.color(:thinking) == :cyan
      assert AxolFace.color(:done) == :green
      assert AxolFace.color(:error) == :red
    end
  end

  describe "init/1" do
    test "defaults to idle, frame 0, unicode" do
      assert {:ok, state} = AxolFace.init(id: :face)
      assert state.state == :idle
      assert state.frame == 0
      assert state.ascii == false
    end
  end

  describe "render/2" do
    test "renders the glyph for the current state and frame with its color" do
      {:ok, state} = AxolFace.init(id: :face, state: :working, frame: 1)
      rendered = AxolFace.render(state, default_context())

      assert face_el(rendered).content == "≡OO≡"
      assert face_el(rendered).fg == :cyan
      assert face_el(rendered).style == %{bold: true}
    end

    test "error face renders red and bold" do
      {:ok, state} = AxolFace.init(id: :face, state: :error)
      rendered = AxolFace.render(state, default_context())

      assert face_el(rendered).content == "≡xx≡"
      assert face_el(rendered).fg == :red
    end

    test "ascii prop swaps the glyph set in place" do
      {:ok, state} = AxolFace.init(id: :face, state: :idle, ascii: true)
      rendered = AxolFace.render(state, default_context())

      assert face_el(rendered).content == "=..="
    end
  end
end
