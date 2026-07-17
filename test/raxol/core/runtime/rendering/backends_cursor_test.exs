defmodule Raxol.Core.Runtime.Rendering.BackendsCursorTest do
  @moduledoc """
  F0-cursor (harness-tea-migration §5 law 6, §6 Phase 0, §9 risk 2): the TEA
  render pipeline honors a view-declared cursor `{row, col, visible?}`.

  Byte contract pinned here:

    * NO declaration -> byte-identical to the pre-cursor pipeline (regression
      pin), and the fresh ScreenBuffer's cursor fields keep their defaults.
    * visible -> the frame's byte tail is `\\e[?25h` (DECTCEM show) followed
      by the park CUP `\\e[row+1;col+1H` -- the frame ENDS with show+CUP,
      inside the DEC-2026 bracket when one is open (mirrors the
      InlineAuthority park protocol: rows moved the physical cursor, so the
      park is unconditional on every frame kind, keyframe and diff alike).
    * hidden -> the tail is `\\e[?25l` (DECTCEM hide) alone, no CUP.
    * coordinates are 0-based buffer coords, clamped into the grid at the
      emit boundary; the stamped `buffer.cursor_position` ({x, y} order) and
      the emitted CUP always agree.

  The declaration seam: a root-level `:cursor` key on the element map
  returned by `view/1` (see `Backends.declared_cursor/1` for the decision
  record). The Engine wiring test at the bottom proves the seam is real,
  not asserted.
  """
  use ExUnit.Case, async: true

  alias Raxol.Core.Runtime.Rendering.Backends
  alias Raxol.Terminal.{Emulator, Renderer}
  alias Raxol.Test.CrossTerminal.RenderOracle, as: Oracle

  # --- helpers -----------------------------------------------------------

  defp prod_frame(prev, next, force_repaint, cursor \\ nil) do
    renderer = Renderer.new(next, %{}, %{}, true)

    Backends.build_terminal_frame(
      prev,
      next,
      renderer,
      %{force_repaint: force_repaint},
      cursor
    )
  end

  defp apply_to(emulator, bytes) do
    {emu, _} = Emulator.process_input(emulator, bytes)
    emu
  end

  # Captures the bytes and resulting state of a full render_to_terminal call.
  defp render_prod_frame(cells, state, cursor) do
    parent = self()

    output =
      ExUnit.CaptureIO.capture_io(fn ->
        {:ok, new_state} = Backends.render_to_terminal(cells, state, cursor)
        send(parent, {:result, new_state})
      end)

    receive do
      {:result, new_state} -> {output, new_state}
    after
      1000 -> raise "render_to_terminal did not complete"
    end
  end

  defp base_state(w, h, opts \\ []) do
    %{
      width: w,
      height: h,
      buffer: nil,
      sync_output: Keyword.get(opts, :sync_output, false),
      force_repaint: Keyword.get(opts, :force_repaint, true)
    }
  end

  # --- declared_cursor/1: the total extraction ---------------------------

  describe "declared_cursor/1" do
    test "extracts a 2-tuple as visible" do
      assert Backends.declared_cursor(%{cursor: {2, 3}}) == {2, 3, true}
    end

    test "extracts a 3-tuple verbatim" do
      assert Backends.declared_cursor(%{cursor: {2, 3, false}}) == {2, 3, false}
      assert Backends.declared_cursor(%{cursor: {2, 3, true}}) == {2, 3, true}
    end

    test "no :cursor key -> nil" do
      assert Backends.declared_cursor(%{type: :view, children: []}) == nil
    end

    test "malformed declarations -> nil, never a crash" do
      assert Backends.declared_cursor(%{cursor: nil}) == nil
      assert Backends.declared_cursor(%{cursor: {1.5, 2}}) == nil
      assert Backends.declared_cursor(%{cursor: {1, 2, :yes}}) == nil
      assert Backends.declared_cursor(%{cursor: {-1, 2}}) == nil
      assert Backends.declared_cursor(%{cursor: {1, -2}}) == nil
      assert Backends.declared_cursor(%{cursor: "1,2"}) == nil
      assert Backends.declared_cursor(nil) == nil
      assert Backends.declared_cursor(42) == nil
    end
  end

  # --- regression pin: no declaration is byte-identical ------------------

  describe "no declaration (regression pin)" do
    test "diff frame bytes are exactly the pre-cursor emit" do
      prev = Oracle.grid(6, 3, fn _x, _y -> " " end)
      next = Oracle.build(6, 3, [{0, 1, "X"}])
      renderer = Renderer.new(next, %{}, %{}, true)

      expected = "\e[2;1H\e[0m\e[2K" <> Renderer.render_row(renderer, 1)

      assert prod_frame(prev, next, false) == expected
      # explicit nil through the 5-arity is the same bytes
      assert prod_frame(prev, next, false, nil) == expected
      refute prod_frame(prev, next, false) =~ "\e[?25"
    end

    test "unchanged frame still emits zero bytes" do
      buf = Oracle.build(6, 3, [{0, 0, "A"}])
      assert prod_frame(buf, buf, false) == ""
    end

    test "render_to_terminal leaves the buffer cursor fields at defaults" do
      cells = [{0, 0, "A", :white, :black, []}]
      {output, result} = render_prod_frame(cells, base_state(6, 3), nil)

      refute output =~ "\e[?25"
      assert result.buffer.cursor_position == {0, 0}
      assert result.buffer.cursor_visible == true
    end
  end

  # --- visible cursor ----------------------------------------------------

  describe "visible cursor" do
    test "keyframe ends with show+CUP at the declared position" do
      next = Oracle.build(6, 3, [{0, 0, "A"}])
      frame = prod_frame(nil, next, true, {1, 2, true})

      assert String.starts_with?(frame, "\e[2J")
      assert String.ends_with?(frame, "\e[?25h\e[2;3H")
    end

    test "the emulator lands the cursor where a bare CUP would" do
      next = Oracle.build(6, 3, [{0, 0, "A"}])
      frame = prod_frame(nil, next, true, {1, 3, true})

      reference = apply_to(Emulator.new(6, 3), "\e[2;4H")
      mine = apply_to(Emulator.new(6, 3), frame)

      assert Emulator.get_cursor_position(mine) ==
               Emulator.get_cursor_position(reference)

      assert Emulator.cursor_visible?(mine) ==
               Emulator.cursor_visible?(apply_to(Emulator.new(6, 3), "\e[?25h"))
    end

    test "a diff frame re-asserts the park after the changed rows" do
      prev = Oracle.grid(6, 3, fn _x, _y -> " " end)
      next = Oracle.build(6, 3, [{0, 1, "X"}])
      renderer = Renderer.new(next, %{}, %{}, true)

      row_bytes = "\e[2;1H\e[0m\e[2K" <> Renderer.render_row(renderer, 1)

      assert prod_frame(prev, next, false, {2, 0, true}) ==
               row_bytes <> "\e[?25h\e[3;1H"
    end

    test "a zero-row diff still parks the declared cursor" do
      buf = Oracle.build(6, 3, [{0, 0, "A"}])
      assert prod_frame(buf, buf, false, {1, 2, true}) == "\e[?25h\e[2;3H"
    end

    test "a 2-tuple declaration defaults to visible" do
      buf = Oracle.build(6, 3, [{0, 0, "A"}])

      assert prod_frame(
               buf,
               buf,
               false,
               Backends.declared_cursor(%{cursor: {1, 2}})
             ) ==
               "\e[?25h\e[2;3H"
    end

    test "resize-shaped keyframe (fresh blank buffer + force_repaint) re-parks" do
      # engine :update_size swaps in a blank buffer of the new size and sets
      # force_repaint -- the next frame is a keyframe and must end on the park
      blank = Oracle.grid(6, 3, fn _x, _y -> " " end)
      next = Oracle.build(6, 3, [{0, 0, "R"}])

      frame = prod_frame(blank, next, true, {2, 4, true})
      assert String.starts_with?(frame, "\e[2J")
      assert String.ends_with?(frame, "\e[?25h\e[3;5H")
    end
  end

  # --- hidden cursor -----------------------------------------------------

  describe "hidden cursor" do
    test "frame ends with DECTCEM hide, no show, no park CUP" do
      next = Oracle.build(6, 3, [{0, 0, "A"}])
      frame = prod_frame(nil, next, true, {1, 2, false})

      assert String.ends_with?(frame, "\e[?25l")
      refute frame =~ "\e[?25h"
      refute frame =~ "\e[2;3H"
    end

    test "emulator visibility matches a bare DECTCEM hide" do
      next = Oracle.build(6, 3, [{0, 0, "A"}])
      frame = prod_frame(nil, next, true, {1, 2, false})

      assert Emulator.cursor_visible?(apply_to(Emulator.new(6, 3), frame)) ==
               Emulator.cursor_visible?(apply_to(Emulator.new(6, 3), "\e[?25l"))
    end
  end

  # --- clamping ----------------------------------------------------------

  describe "clamping" do
    test "a declaration beyond the grid clamps to the last cell" do
      next = Oracle.build(6, 3, [{0, 0, "A"}])
      frame = prod_frame(nil, next, true, {99, 99, true})

      # 6x3 grid: max row 2 -> CUP row 3, max col 5 -> CUP col 6
      assert String.ends_with?(frame, "\e[?25h\e[3;6H")
    end

    test "stamped buffer cursor and emitted CUP agree after clamping" do
      cells = [{0, 0, "A", :white, :black, []}]

      {output, result} =
        render_prod_frame(cells, base_state(6, 3), {99, 99, true})

      assert String.ends_with?(output, "\e[?25h\e[3;6H")
      # buffer cursor_position is {x, y}
      assert result.buffer.cursor_position == {5, 2}
      assert result.buffer.cursor_visible == true
    end
  end

  # --- buffer stamp ------------------------------------------------------

  describe "buffer stamp" do
    test "visible declaration stamps cursor_position ({x, y}) and visibility" do
      cells = [{0, 0, "A", :white, :black, []}]

      {_output, result} =
        render_prod_frame(cells, base_state(6, 3), {1, 2, true})

      assert result.buffer.cursor_position == {2, 1}
      assert result.buffer.cursor_visible == true
    end

    test "hidden declaration stamps visibility false, position kept" do
      cells = [{0, 0, "A", :white, :black, []}]

      {_output, result} =
        render_prod_frame(cells, base_state(6, 3), {1, 2, false})

      assert result.buffer.cursor_position == {2, 1}
      assert result.buffer.cursor_visible == false
    end
  end

  # --- sync bracket ------------------------------------------------------

  describe "DEC-2026 bracket" do
    test "the park tail sits inside the bracket" do
      cells = [{0, 0, "A", :white, :black, []}]

      {output, _result} =
        render_prod_frame(
          cells,
          base_state(6, 3, sync_output: true),
          {1, 2, true}
        )

      assert String.starts_with?(output, "\e[?2026h")
      assert String.ends_with?(output, "\e[?25h\e[2;3H\e[?2026l")
    end
  end

  # --- the Engine seam: view-root declaration flows to the backend -------

  defmodule CursorApp do
    @moduledoc false
    def view(_model) do
      %{
        type: :view,
        cursor: {1, 2},
        children: [%{type: :text, content: "hi"}]
      }
    end
  end

  defmodule NoCursorApp do
    @moduledoc false
    def view(_model) do
      %{type: :view, children: [%{type: :text, content: "hi"}]}
    end
  end

  defmodule StubDispatcher do
    @moduledoc false
    use GenServer

    def start_link(model), do: GenServer.start_link(__MODULE__, model)

    @impl true
    def init(model), do: {:ok, model}

    @impl true
    def handle_call(:get_render_context, _from, model),
      do: {:reply, {:ok, %{model: model, theme_id: nil}}, model}

    def handle_call(:get_plugin_manager, _from, model),
      do: {:reply, {:error, :no_plugin_manager}, model}

    @impl true
    def handle_cast(_msg, model), do: {:noreply, model}
  end

  describe "Engine wiring" do
    defp render_via_engine(app_module) do
      parent = self()

      output =
        ExUnit.CaptureIO.capture_io(fn ->
          {:ok, dispatcher} = StubDispatcher.start_link(%{})

          {:ok, engine} =
            Raxol.Core.Runtime.Rendering.Engine.start_link(
              name: :"cursor_engine_#{System.unique_integer([:positive])}",
              app_module: app_module,
              dispatcher_pid: dispatcher,
              width: 10,
              height: 4,
              environment: :terminal
            )

          result = GenServer.call(engine, :render_frame_sync)
          GenServer.stop(engine)
          GenServer.stop(dispatcher)
          send(parent, {:engine_result, result})
        end)

      receive do
        {:engine_result, result} -> {result, output}
      after
        2000 -> raise "engine render did not complete"
      end
    end

    test "a view-root :cursor lands as the frame's park tail" do
      {result, output} = render_via_engine(CursorApp)

      assert result == :ok
      assert output =~ "\e[?25h\e[2;3H"
    end

    test "a view without :cursor emits no cursor bytes" do
      {result, output} = render_via_engine(NoCursorApp)

      assert result == :ok
      refute output =~ "\e[?25"
    end
  end
end
