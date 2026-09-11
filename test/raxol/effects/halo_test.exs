defmodule Raxol.Effects.HaloTest do
  use ExUnit.Case, async: true

  alias Raxol.Effects.Halo

  @face ["≡··≡"]

  defp rows(opts \\ []),
    do: Halo.field(@face, Keyword.merge([size: {20, 5}], opts))

  defp chars(rows),
    do: rows |> Enum.join() |> String.graphemes() |> MapSet.new()

  describe "field/2" do
    test "returns the requested grid, every row full width" do
      rows = rows(size: {24, 7})

      assert length(rows) == 7
      assert Enum.all?(rows, &(String.length(&1) == 24))
    end

    test "draws the glyph intact and centred" do
      # The whole point of the treatment is that the mark survives it. A field
      # that renders the glyph one cell short, or lets texture land inside it,
      # is the failure this exists to catch.
      rows = rows()
      middle = Enum.at(rows, 2)

      assert String.contains?(middle, "≡··≡")
      assert String.trim(middle) |> String.starts_with?("≡··≡") == false
    end

    test "holds the keep-out clear around the glyph" do
      # Texture pressed against the mark is what the keep-out exists to stop,
      # and it is the thing most likely to break when the hash changes.
      rows = rows(size: {20, 5}, keep_out: {3, 1})
      middle = Enum.at(rows, 2)
      [before, rest] = String.split(middle, "≡··≡", parts: 2)

      assert String.ends_with?(before, "   ")
      assert String.starts_with?(rest, "   ")

      for row <- [Enum.at(rows, 1), Enum.at(rows, 3)] do
        assert String.slice(row, 5, 10) |> String.trim() == ""
      end
    end

    test "texture is drawn from the ramp and nothing else" do
      allowed = MapSet.new([" ", "≡", "·"] ++ Halo.ramp())

      assert MapSet.subset?(chars(rows(size: {40, 11})), allowed)
    end

    test "a custom ramp is the only thing the texture uses" do
      rows = Halo.field(["X"], size: {30, 9}, ramp: ~w(a b))
      assert MapSet.subset?(chars(rows), MapSet.new([" ", "X", "a", "b"]))
    end

    test "is pure in its inputs" do
      assert rows(frame: 12) == rows(frame: 12)
    end

    test "drifts with the frame while the glyph stays put" do
      a = rows(frame: 0)
      b = rows(frame: 9)

      refute a == b
      assert Enum.at(a, 2) |> String.contains?("≡··≡")
      assert Enum.at(b, 2) |> String.contains?("≡··≡")
    end

    test "raising the floor thins the texture" do
      dense = rows(floor: 0.1) |> Enum.join() |> String.replace(" ", "")
      sparse = rows(floor: 0.6) |> Enum.join() |> String.replace(" ", "")

      assert String.length(sparse) < String.length(dense)
    end

    test "a glyph larger than the field is clipped rather than crashing" do
      wide = [String.duplicate("M", 40)]

      assert Halo.field(wide, size: {10, 3}) |> length() == 3
    end

    test "the texture does not stripe at hero-pane widths" do
      # A hash of the form x*A + y*B steps by a constant in x, which comes out
      # as diagonal stripes at twenty columns even though it reads as noise at
      # seventy. Rows that repeat each other are the signature.
      rows = Halo.field([" "], size: {23, 9}, keep_out: {0, 0})

      assert rows |> Enum.uniq() |> length() == length(rows)
    end
  end

  describe "caption/3" do
    test "sets each line beside its row" do
      [first | _] = Halo.caption(@face, ["ONE", "TWO"], size: {20, 5})

      assert first.content =~ "ONE"
    end

    test "keeps every field row when there are fewer captions" do
      rows = Halo.caption(@face, ["ONE"], size: {20, 5})

      assert length(rows) == 5
    end

    test "does not truncate the field to the caption's length" do
      # `Enum.zip` would drop the rows past the last caption, taking the
      # bottom off the halo.
      assert length(Halo.caption(@face, [], size: {20, 5})) == 5
    end
  end
end
