defmodule Raxol.UI.Harness.InputEvent do
  @moduledoc """
  Canonical input-event normalization for harness components.

  ## The problem

  The terminal driver reaches component `handle_event/3` callbacks through
  THREE incompatible key-event shapes depending on which layer produced the
  event, plus a fourth paste shape. Two harness components (the composer,
  the picker) independently hit this gap and each grew inline defensive
  reshaping. `Raxol.UI.Components.Input.TextInput` also copes with it ad
  hoc (`data[:modifiers] || []`). This module is the single normalizer all
  of them should converge on.

  The three real `%Raxol.Core.Events.Event{type: :key, data: data}` shapes
  for `data` (verified against source, not assumed):

  | Source                                              | `data` shape                                                                          | char keys                  | modifiers                              |
  | ---------------------------------------------------- | -------------------------------------------------------------------------------------- | --------------------------- | --------------------------------------- |
  | `packages/raxol_terminal/.../driver/event_translator.ex` (native termbox NIF) | `%{shift: bool, ctrl: bool, alt: bool, meta: bool, char: binary \\| nil, key: atom \\| nil}` (char/key mutually exclusive; booleans always present) | `char: "a"`, `key: nil`      | boolean fields, no `modifiers` list     |
  | `packages/raxol_terminal/.../ansi/input_parser.ex` (raw ANSI/VT parser)       | `%{key: atom}` plus `char:`/`shift:`/`alt:`/`ctrl:` **only present when true/non-nil** | `key: :char, char: "a"`     | boolean fields, omitted entirely when false; no `modifiers` list |
  | `Raxol.Core.Events.Event.key_event/3` (test/component API)                   | `%{key: atom \\| binary, state: :pressed \\| :released \\| :repeat, modifiers: [atom]}` | bare `key: "a"` (no `:char` field) | `modifiers:` list of atoms (`:ctrl`, `:alt`, `:shift`) |

  Plus the paste shape (identical across the ANSI parser and
  `Event.paste_event/2`): `%Raxol.Core.Events.Event{type: :paste, data: %{text: binary}}`.

  ## The canonical shape

  `normalize/1` reduces all of the above (and bare, unwrapped data maps of
  the same shapes) to one map:

      %{
        kind: :char | :key | :paste | :other,
        char: String.t() | nil,   # the grapheme to insert, when kind == :char
        key: atom() | nil,        # the special key atom, when kind == :key
        text: String.t() | nil,   # the pasted text, when kind == :paste
        mods: %{ctrl: boolean(), alt: boolean(), shift: boolean(), meta: boolean()},
        state: :pressed | :released | :repeat | nil,  # nil == press (see below)
        raw: term()               # the original input, untouched
      }

  Design notes:

    * `char` and `key` are never both non-nil -- `kind` picks one lane.
    * `char` is never sliced or byte-counted. A multi-codepoint grapheme
      (emoji, ZWJ sequences) survives intact; normalize never assumes
      `byte_size(char) == 1` the way some upstream insertion paths do.
      It also is never a control byte or more than one grapheme cluster
      (see "Content validation" below) -- a malformed `char:`/bare `key:`
      field routes the WHOLE event to `kind: :other` instead of lying
      that it's insertable text.
    * `mods` always has all four keys (`ctrl`/`alt`/`shift`/`meta`), each a
      `boolean()`, regardless of which upstream shape was missing which
      fields. `event_translator.ex` emits `meta:` (Cmd/Super); it is a
      shortcut modifier just like ctrl/alt, so Cmd+char is a shortcut, NOT
      insertable text. Shift-only is still `text?/1` (capital letters, etc).
    * `state` carries `Event.key_event/3`'s press/release/repeat lifecycle
      through normalization instead of silently dropping it. Only
      `event_translator.ex`/`Event.key_event/3` have a `:state`-bearing
      shape at all right now -- `input_parser.ex` events (and the bare
      driver `data` map) have no state field, so they normalize to
      `state: nil`, which `text?/1`/`key/1` treat as "press" (nil is NOT
      "unknown, so drop it" -- most driver shapes have no notion of
      release at all, and treating absence as "not a press" would make
      ordinary typing stop inserting text). Only an explicit
      `state: :released` suppresses `text?/1`/`key/1` -- see "Release
      does not insert or dispatch" below.
    * `kind: :other` is the total fallback -- unrecognized event shapes,
      non-map input, mouse/resize/focus events, all land here rather than
      raising. `normalize/1` never crashes.

  ## Content validation

  `char:` (or the bare-binary `key:` fallback) is only accepted as
  insertable text when it is exactly one grapheme cluster AND contains no
  C0 control byte (0x00-0x1F) or DEL (0x7F). A raw control sequence
  smuggled into `char:` (e.g. `%{char: "\\e[2J"}`, `%{key: "enter"}` typo'd
  as a bare multi-grapheme string instead of the atom `:enter`) normalizes
  to `kind: :other`, NOT `kind: :char` -- it is not insertable, and it does
  not silently become a special key either (there is no key atom to
  recover; the caller passed a malformed shape). `text?/1` and
  `printable_char/1` re-check this even on a hand-built `t()` map that
  didn't go through `normalize/1`, so their names stay honest. Pasted
  text (`kind: :paste`) is stripped of C0 control bytes and DEL EXCEPT
  tab/newline/carriage-return, which are legitimate content in a
  multi-line paste.

  ## Release does not insert or dispatch

  `text?/1` and `key/1` only return truthy for `state in [nil, :pressed,
  :repeat]` -- an explicit `state: :released` normalizes the classification
  fields as usual (so `norm.key`/`norm.char` still reflect what was
  released, useful for key-up-triggered UI) but `text?/1` is `false` and
  `key/1` is `nil`, so the documented `cond` below naturally falls through
  to the no-op branch on release instead of double-inserting a character
  or re-dispatching a special key on both press AND release.

  ## Cross-shape agreement: scope

  The cross-shape-agreement guarantee (see
  `Raxol.UI.Harness.InputEventTest`'s "cross-shape agreement" property) is
  real, but it is NOT unconditional -- driven off the REAL
  `EventTranslator.translate/1` and `InputParser.parse/1` functions, not
  synthetic hand-built maps, it only holds over the set that is actually
  representable on BOTH the termbox and raw-ANSI wires:

    * Meta (Cmd/Super) is UNREPRESENTABLE over raw ANSI -- `input_parser.ex`
      never emits `meta: true` for any byte sequence. The agreement
      property therefore only drives ctrl/alt/shift combinations (alone
      or combined) through both real emitters; a translator-shape event
      with `meta: true` has no ANSI counterpart to agree with and is
      exercised only in the single-shape unit tests above.
    * Enter/Tab/Escape/Backspace have NO modifier-carrying ANSI encoding
      (Ctrl+Enter is indistinguishable on the wire from plain Enter) --
      those keys are only agreement-tested unmodified. Shift+Tab
      (backtab) is the one exception: both wires have a dedicated,
      distinguishable encoding for it (termbox's `TB_KEY_BACK_TAB`, ANSI's
      `CSI Z`), so it IS covered.
    * Arrows, Home/End, and F1-F4 support the CSI `"1;<mod>"` modifier
      encoding on the ANSI side and are agreement-tested across the full
      ctrl/alt/shift power set (8 combinations) via real bytes/keycodes.
      F5-F12/Insert/Delete/PageUp/PageDown are agreement-tested unmodified
      only (their ANSI tilde encoding here has no modifier parameter).

  ## The shared shortcut/text-input predicate

  Composer (`lib/raxol/ui/components/harness/composer.ex`) and picker
  (`lib/raxol/ui/components/harness/picker.ex`) both use the pattern below
  instead of hand-rolling a `text_input?/1`-style predicate that reads
  `data[:modifiers] || []` alongside `data[:ctrl]`/`data[:alt]` booleans.
  Note the
  ordering: `shortcut?/1` is checked FIRST, because a shortcut is
  ALSO a `kind: :char` (Ctrl+A) or `kind: :key` (Ctrl+Up) -- routing on
  `text?/1`/`key/1` first would drop char-shortcuts into the no-op branch
  and strip the modifiers off modifier-qualified special keys. The key
  branch passes the WHOLE `norm` (or its `mods`), never the bare atom, so
  Ctrl+Up stays Ctrl+Up rather than collapsing to Up:

      alias Raxol.UI.Harness.InputEvent

      def handle_event(%Event{} = event, state, _context) do
        norm = InputEvent.normalize(event)

        cond do
          norm.kind == :paste ->
            insert(state, norm.text)

          # ctrl/alt/meta held -- a shortcut. Handle it WITH the mods so
          # both Ctrl+A (kind: :char) and Ctrl+Up (kind: :key) reach the
          # shortcut handler; neither is text, neither is a plain nav key.
          InputEvent.shortcut?(norm) ->
            handle_shortcut(state, norm)

          # printable text (shift-only still counts). insert the grapheme.
          InputEvent.text?(norm) ->
            insert(state, InputEvent.printable_char(norm))

          # a plain special key. dispatch WITH the norm so a handler that
          # cares about e.g. Shift+Tab still sees norm.mods.shift.
          InputEvent.key(norm) ->
            dispatch_key(state, norm)

          true ->
            {state, []}
        end
      end

  `text_input.ex`'s `KeyHandler.handle_key/3` dispatch and its
  `data[:modifiers] || []` read are the same class of fix.
  """

  @type mods :: %{
          ctrl: boolean(),
          alt: boolean(),
          shift: boolean(),
          meta: boolean()
        }
  # Single source for the kind vocabulary: the `@type kind` below and the
  # idempotence fast-path guard both derive from it, so a new kind cannot
  # silently regress one without the other.
  @kinds [:char, :key, :paste, :other]
  @type kind :: :char | :key | :paste | :other
  @type key_state :: :pressed | :released | :repeat | nil

  @type t :: %{
          kind: kind(),
          char: String.t() | nil,
          key: atom() | nil,
          text: String.t() | nil,
          mods: mods(),
          state: key_state(),
          raw: term()
        }

  @no_mods %{ctrl: false, alt: false, shift: false, meta: false}
  @live_states [nil, :pressed, :repeat]

  # C0 control range plus DEL. Used both to reject control bytes smuggled
  # into `char:`/bare `key:` (content validation) and to strip them from
  # pasted text (tab/newline/CR excluded there -- see strip_paste_text/1).
  @control_bytes 0x00..0x1F

  @doc """
  Normalizes any of the driver key-event shapes, the paste shape, or
  `Raxol.Core.Events.Event.key_event/3`'s shape (wrapped in an `Event`
  struct OR passed as a bare `data` map) into the canonical form above.

  Total: never raises. Anything unrecognized normalizes to `kind: :other`.

  IDEMPOTENT by contract (the SessionPump's PumpContract §4): the live
  pump normalizes at its boundary, and `HarnessApp.Model.handle_key/2`
  normalizes again for its own Keymap routing -- so a second pass must
  return the input UNCHANGED. Without idempotence, re-normalizing an
  already-normalized map reads `mods` as all-false (extract_mods looks
  for top-level `:ctrl`/`:alt` fields, which the canonical shape nests
  under `:mods`) -- silently un-pressing Ctrl on every live chord,
  breaking the quit protocol -- and buries the original `%Event{}` one
  `:raw` level deeper than component dispatch can find it.
  """
  @spec normalize(term()) :: t()
  # The fast-path matches the CANONICAL mods shape (all four boolean keys),
  # not `mods: %{}` -- an empty-map pattern matches ANY map, which would let
  # a map that merely carries a `kind` and some `mods` field (e.g. a
  # `%{kind: :paste, text: "\e[2J...", mods: %{}}`) short-circuit the
  # normalizer and return verbatim, bypassing paste ANSI/control-byte
  # sanitization and char content validation. Requiring the full canonical
  # mods shape means only genuinely-normalized events (the pump's own
  # sanitized output) take the fast path; anything else -- empty, partial,
  # or malformed mods -- falls through to real normalization.
  def normalize(
        %{kind: kind, mods: %{ctrl: _, alt: _, shift: _, meta: _}} =
          already_normalized
      )
      when kind in @kinds,
      do: already_normalized

  def normalize(
        %Raxol.Core.Events.Event{type: :paste, data: %{text: text}} = raw
      )
      when is_binary(text) do
    paste_result(text, raw)
  end

  def normalize(%Raxol.Core.Events.Event{type: :key, data: data} = raw)
      when is_map(data) do
    key_result(data, raw)
  end

  def normalize(%Raxol.Core.Events.Event{} = raw), do: unclassified(raw)

  def normalize(%{type: :paste, data: %{text: text}} = raw)
      when is_binary(text) do
    paste_result(text, raw)
  end

  def normalize(%{type: :key, data: data} = raw) when is_map(data) do
    key_result(data, raw)
  end

  def normalize(%{text: text} = raw) when is_binary(text) do
    paste_result(text, raw)
  end

  def normalize(data) when is_map(data), do: key_result(data, data)

  def normalize(other), do: unclassified(other)

  @doc """
  Printable text with no ctrl/alt/meta held. Shift-only (capital letters,
  shifted punctuation) is still text -- only ctrl/alt/meta promote a char
  to a shortcut. `meta` is Cmd/Super (macOS Cmd+key); an event with it set
  is a shortcut, not insertable text.

  Also false when `char` fails content validation (control byte, or more
  than one grapheme -- see moduledoc) or `state` is `:released`, even on a
  hand-built map that didn't go through `normalize/1` -- so the name
  "text?" doesn't lie about what's actually safe to insert.
  """
  @spec text?(t()) :: boolean()
  def text?(%{
        kind: :char,
        char: char,
        state: state,
        mods: %{ctrl: ctrl, alt: alt, meta: meta}
      })
      when state in @live_states do
    not (ctrl or alt or meta) and valid_char?(char)
  end

  def text?(_normalized), do: false

  @doc """
  Ctrl, Alt, or Meta (Cmd/Super) is held, regardless of `kind` -- a
  printable char with a modifier (Ctrl+A, Cmd+S) or a special key with a
  modifier (Ctrl+Up) both count. Shift alone is not a shortcut.
  """
  @spec shortcut?(t()) :: boolean()
  def shortcut?(%{mods: %{ctrl: ctrl, alt: alt, meta: meta}}),
    do: ctrl or alt or meta

  def shortcut?(_normalized), do: false

  @doc """
  The grapheme to insert, or `nil` if this normalized event isn't
  insertable text (see `text?/1`). Never truncated to a single codepoint.
  """
  @spec printable_char(t()) :: String.t() | nil
  def printable_char(%{kind: :char, char: char} = normalized) do
    if text?(normalized), do: char, else: nil
  end

  def printable_char(_normalized), do: nil

  @doc """
  The special key atom (`:up`, `:enter`, `:backspace`, ...), or `nil` if
  this normalized event isn't a special key or `state` is `:released`
  (see moduledoc -- release does not (re-)dispatch).
  """
  @spec key(t()) :: atom() | nil
  def key(%{kind: :key, key: key, state: state}) when state in @live_states,
    do: key

  def key(_normalized), do: nil

  # -- private --

  defp key_result(data, raw) do
    mods = extract_mods(data)
    state = extract_state(data)

    cond do
      char = extract_char(data) ->
        %{
          kind: :char,
          char: char,
          key: nil,
          text: nil,
          mods: mods,
          state: state,
          raw: raw
        }

      key = extract_special_key(data) ->
        %{
          kind: :key,
          char: nil,
          key: key,
          text: nil,
          mods: mods,
          state: state,
          raw: raw
        }

      true ->
        unclassified(raw)
    end
  end

  defp extract_mods(data) do
    modifiers =
      case Map.get(data, :modifiers) do
        list when is_list(list) -> list
        _not_a_list -> []
      end

    %{
      ctrl: Map.get(data, :ctrl) == true or :ctrl in modifiers,
      alt: Map.get(data, :alt) == true or :alt in modifiers,
      shift: Map.get(data, :shift) == true or :shift in modifiers,
      meta: Map.get(data, :meta) == true or :meta in modifiers
    }
  end

  # Only Event.key_event/3's shape carries a `:state`; event_translator.ex
  # and input_parser.ex events have no notion of release at all, so they
  # normalize to `nil` ("press" -- see moduledoc).
  defp extract_state(data) do
    case Map.get(data, :state) do
      state when state in [:pressed, :released, :repeat] -> state
      _no_state_field -> nil
    end
  end

  # `char:` wins when present (event_translator.ex, input_parser.ex's
  # `key: :char, char: ...` form). Falls back to a bare binary `key:`
  # (Event.key_event/3's `key: "a"` form, no `:char` field at all).
  # Either way, the candidate must pass `valid_char?/1` -- a control byte
  # or multi-grapheme string returns `nil` here so the caller falls
  # through to `extract_special_key/1` and, finding nothing there either
  # (a raw control sequence or a mis-encoded bare string has no key
  # atom), lands on `kind: :other` rather than lying that it's text.
  defp extract_char(data) do
    case Map.get(data, :char) do
      char when is_binary(char) and char != "" -> as_valid_char(char)
      _no_char_field -> extract_char_from_bare_key(data)
    end
  end

  defp extract_char_from_bare_key(data) do
    case Map.get(data, :key) do
      key when is_binary(key) and key != "" -> as_valid_char(key)
      _no_binary_key -> nil
    end
  end

  defp as_valid_char(char), do: if(valid_char?(char), do: char, else: nil)

  # An atom `key:` other than `nil`/`:char` is a special key across all
  # three shapes (`:up`, `:enter`, `:backspace`, `:unknown`, ...).
  defp extract_special_key(data) do
    case Map.get(data, :key) do
      key when is_atom(key) and key not in [nil, :char] -> key
      _not_a_special_key -> nil
    end
  end

  # Exactly one grapheme cluster, no C0 control byte or DEL. Byte-level
  # scan is safe on multi-byte UTF-8: every continuation/lead byte is
  # >= 0x80, so it never collides with the 0x00-0x1F/0x7F control range
  # being scanned for.
  defp valid_char?(bin) when is_binary(bin) do
    not has_control_byte?(bin) and String.length(bin) == 1
  end

  defp valid_char?(_not_a_binary), do: false

  defp has_control_byte?(bin) do
    Enum.any?(:binary.bin_to_list(bin), fn byte ->
      byte in @control_bytes or byte == 0x7F
    end)
  end

  defp paste_result(text, raw) do
    %{
      kind: :paste,
      char: nil,
      key: nil,
      text: strip_paste_text(text),
      mods: @no_mods,
      state: nil,
      raw: raw
    }
  end

  # Strips C0 control bytes and DEL from pasted text, EXCEPT tab/newline/
  # carriage-return -- legitimate content in a multi-line paste (see
  # moduledoc's "never embed raw ANSI" rule: a pasted ESC/CSI sequence
  # must not survive to be interpreted downstream as terminal control
  # input). Byte-level filter, safe on UTF-8 for the same reason
  # `has_control_byte?/1` is: multi-byte sequence bytes are all >= 0x80.
  defp strip_paste_text(text) do
    keep? = fn byte -> byte not in @control_bytes or byte in [?\t, ?\n, ?\r] end

    text
    |> :binary.bin_to_list()
    |> Enum.filter(fn byte -> keep?.(byte) and byte != 0x7F end)
    |> :erlang.list_to_binary()
  end

  defp unclassified(raw) do
    %{
      kind: :other,
      char: nil,
      key: nil,
      text: nil,
      mods: @no_mods,
      state: nil,
      raw: raw
    }
  end
end
