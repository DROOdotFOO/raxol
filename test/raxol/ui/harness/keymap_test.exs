defmodule Raxol.UI.Harness.KeymapTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Raxol.Core.Events.Event
  alias Raxol.Terminal.ANSI.InputParser
  alias Raxol.Terminal.Driver.EventTranslator
  alias Raxol.UI.Harness.InputEvent
  alias Raxol.UI.Harness.Keymap

  # -- real-producer helpers (mirrors input_event_test.exs's approach: drive
  # the REAL T27 emitters, never hand-build a translator-/parser-shaped map) --

  @tb_escape 27
  @tb_tab 9

  defp translator_event(key_code, char_code, mod_code \\ 0) do
    {:ok, event} =
      EventTranslator.translate(%{
        type: :key,
        key: key_code,
        char: char_code,
        mod: mod_code
      })

    event
  end

  defp parser_event(binary) do
    [event] = InputParser.parse(binary)
    event
  end

  defp resolve_from(raw_event, context \\ %{}) do
    raw_event |> InputEvent.normalize() |> Keymap.resolve(context)
  end

  # -- 1. table test: each v1 bind, canonical event -> exactly its typed
  # command, driven through the real producers for every shape that can
  # represent it --

  describe "v1 binds -- table over real T27 producers" do
    test "ESC (translator shape) -> :interrupt" do
      assert resolve_from(translator_event(@tb_escape, 0)) ==
               %{type: :interrupt, payload: %{}}
    end

    test "ESC (ANSI parser shape) -> :interrupt" do
      assert resolve_from(parser_event(<<27>>)) ==
               %{type: :interrupt, payload: %{}}
    end

    test "ESC (Event.key_event/3 shape) -> :interrupt" do
      assert resolve_from(Event.key_event(:escape, :pressed, [])) ==
               %{type: :interrupt, payload: %{}}
    end

    test "Tab (translator shape) -> :steer" do
      assert resolve_from(translator_event(@tb_tab, 0)) ==
               %{type: :steer, payload: %{}}
    end

    test "Tab (ANSI parser shape) -> :steer" do
      assert resolve_from(parser_event(<<9>>)) == %{type: :steer, payload: %{}}
    end

    test "Tab (Event.key_event/3 shape) -> :steer" do
      assert resolve_from(Event.key_event(:tab, :pressed, [])) ==
               %{type: :steer, payload: %{}}
    end

    test "'z' (translator shape) -> :fold_toggle, not composing" do
      assert resolve_from(translator_event(0, ?z), %{composing?: false}) ==
               %{type: :fold_toggle, payload: %{block_id: nil}}
    end

    test "'z' (ANSI parser shape) -> :fold_toggle, not composing" do
      assert resolve_from(parser_event("z"), %{composing?: false}) ==
               %{type: :fold_toggle, payload: %{block_id: nil}}
    end

    test "'z' (Event.key_event/3 shape) -> :fold_toggle, carries focused_block_id" do
      assert resolve_from(Event.key_event("z", :pressed, []), %{
               composing?: false,
               focused_block_id: "blk-7"
             }) == %{type: :fold_toggle, payload: %{block_id: "blk-7"}}
    end

    test "'j' (translator shape) -> :jump_next, not composing" do
      assert resolve_from(translator_event(0, ?j), %{composing?: false}) ==
               %{type: :jump_next, payload: %{}}
    end

    test "'j' (ANSI parser shape) -> :jump_next, not composing" do
      assert resolve_from(parser_event("j"), %{composing?: false}) ==
               %{type: :jump_next, payload: %{}}
    end

    test "'k' (translator shape) -> :jump_prev, not composing" do
      assert resolve_from(translator_event(0, ?k), %{composing?: false}) ==
               %{type: :jump_prev, payload: %{}}
    end

    test "'k' (ANSI parser shape) -> :jump_prev, not composing" do
      assert resolve_from(parser_event("k"), %{composing?: false}) ==
               %{type: :jump_prev, payload: %{}}
    end

    test "an unbound key normalizes but resolves to :passthrough" do
      assert resolve_from(Event.key_event("q", :pressed, []), %{
               composing?: false
             }) == :passthrough
    end

    test "an unbound special key resolves to :passthrough" do
      assert resolve_from(Event.key_event(:up, :pressed, []), %{
               composing?: false
             }) == :passthrough
    end
  end

  # -- 2. ESC-during-streaming: the roadmap's named acceptance wording --

  describe "ESC during streaming" do
    test "ESC while streaming?: true still yields :interrupt, immediately, not buffered" do
      assert resolve_from(Event.key_event(:escape, :pressed, []), %{
               streaming?: true,
               composing?: true
             }) == %{type: :interrupt, payload: %{}}
    end

    test "ESC while streaming?: false also yields :interrupt (harmless no-op downstream, never dropped)" do
      assert resolve_from(Event.key_event(:escape, :pressed, []), %{
               streaming?: false
             }) == %{type: :interrupt, payload: %{}}
    end
  end

  # -- 3. composer-focus guard --

  describe "composer-focus guard" do
    test "'j'/'k'/'z' pass through while composing (no stolen keys)" do
      for char <- ["j", "k", "z"] do
        assert resolve_from(Event.key_event(char, :pressed, []), %{
                 composing?: true
               }) == :passthrough
      end
    end

    test "'j'/'k'/'z' resolve to their bind while not composing" do
      assert resolve_from(Event.key_event("j", :pressed, []), %{
               composing?: false
             }) == %{type: :jump_next, payload: %{}}

      assert resolve_from(Event.key_event("k", :pressed, []), %{
               composing?: false
             }) == %{type: :jump_prev, payload: %{}}

      assert resolve_from(Event.key_event("z", :pressed, []), %{
               composing?: false
             }) == %{type: :fold_toggle, payload: %{block_id: nil}}
    end

    test "composing?: unset defaults to the guarded (non-composing) behavior -- callers must opt in explicitly" do
      # Absence of :composing? in context must not accidentally suppress a
      # navigation bind -- Map.get(context, :composing?, false) means
      # "unset == not composing", the safe default for callers (e.g. tests,
      # a palette invocation) that never render a composer at all.
      assert resolve_from(Event.key_event("j", :pressed, []), %{}) ==
               %{type: :jump_next, payload: %{}}
    end

    test "ESC and Tab are the explicit exceptions -- they fire even while composing?: true" do
      assert resolve_from(Event.key_event(:escape, :pressed, []), %{
               composing?: true
             }) == %{type: :interrupt, payload: %{}}

      assert resolve_from(Event.key_event(:tab, :pressed, []), %{
               composing?: true
             }) == %{type: :steer, payload: %{}}
    end

    property "composing?: true always passes through printable characters, except the explicit exceptions" do
      check all(char <- StreamData.string(:alphanumeric, length: 1)) do
        result =
          resolve_from(Event.key_event(char, :pressed, []), %{
            composing?: true
          })

        assert result == :passthrough
      end
    end
  end

  # -- 4. invocation-parity seam (T15's palette) --

  describe "invocation parity" do
    test "command_types/0 is exactly the union binds/0 can ever emit" do
      declared = Keymap.command_types() |> Enum.uniq() |> MapSet.new()

      emitted =
        Keymap.binds()
        |> Enum.map(fn bind ->
          norm = fixture_for(bind)
          context = %{composing?: false, focused_block_id: "any"}

          case Keymap.resolve(norm, context) do
            %{type: type} -> type
            :passthrough -> flunk("bind #{inspect(bind)} did not resolve")
          end
        end)
        |> MapSet.new()

      assert declared == emitted
      assert MapSet.size(declared) == length(Keymap.binds())
    end

    defp fixture_for(%{key: key}),
      do: InputEvent.normalize(Event.key_event(key, :pressed, []))

    defp fixture_for(%{char: char}),
      do: InputEvent.normalize(Event.key_event(char, :pressed, []))
  end

  # -- 5. fail-first RED proof (see commit message / report for the manual
  # red run against a deliberately-broken guard) --
  #
  # The property test above ("composing?: true always passes through...")
  # is the fail-first proof: temporarily inlining `true` in place of
  # `guard_passes?/2`'s `:not_composing` clause (so `z`/`j`/`k` fire
  # unconditionally, reproducing the named prototype bug) reddens this
  # exact property immediately (StreamData shrinks to a single-char
  # counterexample, e.g. "j", within the same run) with no other test
  # touched. Restoring the guard turns it green again. This is the
  # regression this suite exists to prevent.
end
