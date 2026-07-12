if !Raxol.Terminal.TerminalUtils.real_tty?() do
  defmodule Raxol.Terminal.OracleEquivalenceTest do
    use ExUnit.Case
    @moduletag :docker
    @tag skip: "requires a real TTY (self-hosted FATE runner under a PTY)"
    test "oracle equivalence skipped without a TTY" do
      assert true
    end
  end
else
  defmodule Raxol.Terminal.OracleEquivalenceTest do
    @moduledoc """
    checkasm-style equivalence: the termbox2 NIF (the optimized path) must produce
    the same back buffer as the pure `Raxol.Terminal.Termbox.Model` (the reference
    oracle) for the same op stream, including explicit edges (empty, wide CJK,
    attribute saturation, out-of-bounds writes, print clipping, newlines).

    Needs a real terminal (`tb_init` opens the controlling tty), so it runs on the
    self-hosted FATE runners under a pseudo-terminal, not on GitHub-hosted CI.
    """
    use ExUnit.Case

    @moduletag :docker

    alias Raxol.Terminal.Termbox.Model

    @nif :termbox2_nif

    setup do
      assert @nif.tb_init() == 0
      on_exit(fn -> @nif.tb_shutdown() end)

      w = @nif.tb_width()
      h = @nif.tb_height()
      assert is_integer(w) and w > 0
      assert is_integer(h) and h > 0
      %{w: w, h: h}
    end

    test "NIF back buffer matches the reference oracle", %{w: w, h: h} do
      for {name, ops} <- fixtures(w, h) do
        actual = render_nif(ops)
        expected = Model.render(ops, w, h)

        assert length(actual) == length(expected),
               "#{name}: NIF returned #{length(actual)} cells, model #{length(expected)} (#{w}x#{h})"

        assert divergence(actual, expected) == [],
               "#{name}: NIF diverged from reference at #{inspect(Enum.take(divergence(actual, expected), 5))}"
      end
    end

    defp fixtures(w, h) do
      [
        {"empty", []},
        {"single set_cell", [{:set_cell, 0, 0, ?A, 1, 2}]},
        {"multiple set_cells",
         [
           {:set_cell, 0, 0, ?A, 1, 2},
           {:set_cell, 1, 0, ?B, 3, 4},
           {:set_cell, 0, 1, ?C, 5, 6}
         ]},
        {"overwrite same cell", [{:set_cell, 2, 2, ?X, 1, 1}, {:set_cell, 2, 2, ?Y, 2, 2}]},
        {"wide CJK codepoints",
         [{:set_cell, 0, 0, 0x65E5, 3, 4}, {:set_cell, 1, 0, 0x672C, 5, 6}]},
        {"attribute saturation", [{:set_cell, 0, 0, ?Z, 0xFFFFFFFF, 0xFFFFFFFF}]},
        {"out-of-bounds no-ops",
         [
           {:set_cell, -1, 0, ?A, 1, 1},
           {:set_cell, 0, -1, ?B, 1, 1},
           {:set_cell, w, 0, ?C, 1, 1},
           {:set_cell, 0, h, ?D, 1, 1},
           {:set_cell, w + 5, h + 5, ?E, 1, 1}
         ]},
        {"far corner boundary", [{:set_cell, w - 1, h - 1, ?Z, 4, 5}]},
        {"print ASCII run", [{:print, 0, 0, 7, 0, "Hello"}]},
        {"print clips at right edge", [{:print, w - 3, 0, 7, 0, "ABCDE"}]},
        {"print newline", [{:print, 0, 0, 7, 0, "AB\nCD"}]},
        {"print out-of-bounds start", [{:print, w, 0, 7, 0, "zz"}]},
        {"mixed ops",
         [
           {:set_cell, 0, 0, ?*, 1, 1},
           {:print, 1, 0, 2, 3, "xy"},
           {:set_cell, 0, 1, ?#, 4, 5}
         ]}
      ]
    end

    defp render_nif(ops) do
      @nif.tb_clear()

      Enum.each(ops, fn
        {:set_cell, x, y, ch, fg, bg} -> @nif.tb_set_cell(x, y, ch, fg, bg)
        {:print, x, y, fg, bg, str} -> @nif.tb_print(x, y, fg, bg, str)
        :clear -> @nif.tb_clear()
      end)

      @nif.tb_cell_buffer()
    end

    # Row-major indices where the NIF and the reference disagree.
    defp divergence(actual, expected) do
      actual
      |> Enum.zip(expected)
      |> Enum.with_index()
      |> Enum.flat_map(fn {{a, e}, i} -> if a == e, do: [], else: [{i, e, a}] end)
    end
  end
end
