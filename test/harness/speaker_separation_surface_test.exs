defmodule Raxol.Harness.SpeakerSeparationSurfaceTest do
  @moduledoc """
  Byte-level pins for the speaker-separation ruling (option A,
  `docs/proposals/in-flight/harness-speaker-separation.md` + V's margin
  ruling: the chevron is the ONLY entity that enters the 1-cell margin):

    * **The tagline is dead.** The strings `[assistant]`/`[user]` never
      appear anywhere in the emitted bytes of a mixed transcript.
    * **The dialogue pair (V's outer-contour amendment).** An expanded
      `:message` block seals with its speaker's sigil flush-left in the
      margin column (column 0, the outer contour) and text at the content
      indent (column 2): user turns echo the composer's `❯`, assistant
      turns carry the mirrored `❮`. Wrapped lines hang-align under the
      text with the composer's own two-space continuation convention.
      Machinery keeps the plain 1-column margin.
    * **One sigil source per speaker.** `unicode: :none` capability
      degrades the pair TOGETHER (`>` / `<`) through the same
      `model.sigil`/`model.reply_sigil` the composer and seal seam share
      -- echo, prompt, and reply can never drift or mix tiers.
    * **Channel discipline.** The chevron is bold (structure channel)
      through the ViewText SGR path, zero color at full prominence; a
      turns-behind echo's chevron carries the block's OWN resolved fade
      colour (single-fg rule), never staying anchor-bright.
    * **Blank-line rhythm.** Exactly one blank row separates the user
      echo from the assistant's bare prose -- the load-bearing turn
      separator now that the tagline is gone.

  Same harness discipline as `charged_minimum_surface_test.exs`: the REAL
  `InlineAuthority` through a `StringIO` device, read back through the
  `SealOracle` replay emulator.
  """

  use ExUnit.Case, async: true

  alias Raxol.Harness.Surface
  alias Raxol.Harness.Test.SealOracle
  alias Raxol.Terminal.Emulator

  @width 60
  @rows 20
  @footer_rows 6
  @region_top @rows - @footer_rows

  # Long enough to wrap past the 58-column content width exactly once.
  @user_prompt "why does the settle step double-debit the ledger when the run resumes after a crash?"
  @assistant_answer "The fold consulted the seal frontier after it ran."

  # -- harness helpers (charged-minimum conventions) ----------------------

  defp raw(device) do
    {_in, out} = StringIO.contents(device)
    out
  end

  defp new_model(events, opts \\ []) do
    {:ok, device} = StringIO.open("")

    defaults = [
      device: device,
      width: @width,
      rows: @rows,
      footer_rows: @footer_rows,
      mode: :inline_log
    ]

    model = Surface.new(events, Keyword.merge(defaults, opts))
    {model, device}
  end

  defp drive_to_completion(model) do
    case Surface.advance(model) do
      {model, :done} -> model
      {model, :ok} -> drive_to_completion(model)
    end
  end

  defp screen_rows(device) do
    device
    |> raw()
    |> SealOracle.replay(width: @width, height: @rows)
    |> Emulator.get_screen_buffer()
    |> Map.get(:cells)
    |> Enum.map(&row_text/1)
  end

  defp history_rows(device), do: device |> screen_rows() |> Enum.take(@region_top)

  defp row_text(row_cells) do
    row_cells |> Enum.map_join("", &(&1.char || " ")) |> String.trim_trailing()
  end

  # One turn: a role-carrying user message echo + an assistant reply.
  # Payloads use STRING keys -- the live-seam wire shape -- so this suite
  # also exercises the BlockBuilder payload adaptation (`role`
  # passthrough), not just Block's atom-keyed extraction.
  defp mixed_turn_events do
    [
      %{
        id: 1,
        turn_id: "t1",
        ts: 1,
        family: :loop,
        type: :turn_started,
        tier: :durable,
        payload: %{"prompt" => @user_prompt}
      },
      message_item(2, "t1", "i1", @user_prompt, "user"),
      message_item(4, "t1", "i2", @assistant_answer, "assistant"),
      %{
        id: 6,
        turn_id: "t1",
        ts: 6,
        family: :loop,
        type: :turn_completed,
        tier: :durable,
        payload: %{"status" => "ok"}
      }
    ]
    |> List.flatten()
  end

  # Two turns: the user-only first turn seals while the SECOND turn is
  # already current (turns_behind = 1 -> prominence 0.8), pinning the
  # chevron's fade-with-its-block behaviour.
  defp two_turn_events do
    [
      %{
        id: 1,
        turn_id: "t1",
        ts: 1,
        family: :loop,
        type: :turn_started,
        tier: :durable,
        payload: %{"prompt" => "first question"}
      },
      message_item(2, "t1", "i1", "first question", "user"),
      %{
        id: 4,
        turn_id: "t1",
        ts: 4,
        family: :loop,
        type: :turn_completed,
        tier: :durable,
        payload: %{"status" => "ok"}
      },
      %{
        id: 5,
        turn_id: "t2",
        ts: 5,
        family: :loop,
        type: :turn_started,
        tier: :durable,
        payload: %{"prompt" => "second question"}
      },
      message_item(6, "t2", "i2", "The second answer.", "assistant"),
      %{
        id: 8,
        turn_id: "t2",
        ts: 8,
        family: :loop,
        type: :turn_completed,
        tier: :durable,
        payload: %{"status" => "ok"}
      }
    ]
    |> List.flatten()
  end

  defp message_item(id, turn_id, item_id, content, role) do
    [
      %{
        id: id,
        turn_id: turn_id,
        ts: id,
        family: :loop,
        type: :item_started,
        tier: :durable,
        payload: %{"item_id" => item_id, "item_type" => "message"}
      },
      %{
        id: id + 1,
        turn_id: turn_id,
        ts: id + 1,
        family: :loop,
        type: :item_completed,
        tier: :durable,
        payload: %{
          "item_id" => item_id,
          "item_type" => "message",
          "role" => role,
          "content" => content
        }
      }
    ]
  end

  # -- 1. the tagline is dead ---------------------------------------------

  describe "1. the tagline sweep" do
    test "the strings [assistant] and [user] never appear in the emitted bytes" do
      {model, device} = new_model(mixed_turn_events())
      _model = drive_to_completion(model)

      bytes = raw(device)
      refute bytes =~ "[assistant]"
      refute bytes =~ "[user]"
    end
  end

  # -- 2. the user echo geometry -------------------------------------------

  describe "2. the dialogue pair (chevrons in the outer contour, text at the content indent)" do
    test "user `❯ text` and assistant `❮ text` at column 0, wraps hang-aligned" do
      {model, device} = new_model(mixed_turn_events())
      _model = drive_to_completion(model)

      history = history_rows(device)

      echo_index = Enum.find_index(history, &String.starts_with?(&1, "❯ "))

      assert echo_index != nil,
             "no chevron-echo row in sealed history: #{inspect(history)}"

      echo_row = Enum.at(history, echo_index)

      # Chevron flush-left IN the margin column (column 0); user text at
      # the composer's draft column (column 2) -- byte-aligned with the
      # live prompt row it echoes.
      assert String.starts_with?(echo_row, "❯ why does the settle step"),
             "echo row must be `❯ <text>` from column 0, " <>
               "got #{inspect(echo_row)}"

      # The prompt wraps once at the 58-col content width: the
      # continuation row hang-aligns under the text with the composer's
      # own two-space convention -- never the single-space margin.
      wrap_row = Enum.at(history, echo_index + 1)

      assert String.starts_with?(wrap_row, "  "),
             "wrapped user line must hang-align to the text column, " <>
               "got #{inspect(wrap_row)}"

      refute String.starts_with?(wrap_row, "   "),
             "hang indent is exactly two cells (text column 2), " <>
               "got #{inspect(wrap_row)}"

      assert wrap_row =~ "crash"

      # Assistant prose: the mirrored reply sigil at column 0, prose at
      # the same content indent as the user's text.
      answer_row = Enum.find(history, &(&1 =~ "seal frontier"))
      assert answer_row != nil

      assert String.starts_with?(answer_row, "❮ The fold"),
             "assistant row must be `❮ <prose>` from column 0, " <>
               "got #{inspect(answer_row)}"

      refute String.contains?(answer_row, "❯")
      refute String.contains?(answer_row, "»")
    end

    test "exactly one blank row between the user echo and the assistant prose (the load-bearing separator)" do
      {model, device} = new_model(mixed_turn_events())
      _model = drive_to_completion(model)

      history = history_rows(device)

      last_user =
        history
        |> Enum.with_index()
        |> Enum.filter(fn {row, _i} -> row =~ "crash" end)
        |> List.last()
        |> elem(1)

      first_assistant =
        Enum.find_index(history, &(&1 =~ "seal frontier"))

      between = Enum.slice(history, (last_user + 1)..(first_assistant - 1))

      assert Enum.count(between, &(&1 == "")) == 1,
             "expected exactly one blank separator row between the echo " <>
               "and the answer, got #{inspect(between)}"
    end
  end

  # -- 3. one sigil source: capability degradation --------------------------

  describe "3. ANSI16 / unicode: :none degradation" do
    test "the pair degrades together: `>` for the echo, `<` for the reply" do
      caps = %Raxol.Terminal.Capabilities{unicode: :none}
      {model, device} = new_model(mixed_turn_events(), capabilities: caps)
      _model = drive_to_completion(model)

      history = history_rows(device)

      assert Enum.any?(history, &String.starts_with?(&1, "> ")),
             "unicode: :none must degrade the echo sigil to '>', " <>
               "got #{inspect(history)}"

      assert Enum.any?(history, &String.starts_with?(&1, "< ")),
             "unicode: :none must degrade the reply sigil to '<', " <>
               "got #{inspect(history)}"

      refute Enum.any?(history, &String.contains?(&1, "❯"))
      refute Enum.any?(history, &String.contains?(&1, "❮"))
    end

    test "all four sigils are width-honest: exactly one display column" do
      for sigil <- ["❯", "❮", ">", "<"] do
        assert Raxol.UI.TextMeasure.display_width(sigil) == 1
      end
    end
  end

  # -- 4. channel discipline: bold, and fade-with-its-block ----------------

  describe "4. the echo chevron's styling" do
    test "bold through the ViewText SGR path, zero color at full prominence" do
      {model, device} = new_model(mixed_turn_events())
      _model = drive_to_completion(model)

      # Both blocks seal within their own (current) turn: prominence
      # 1.0, so each sigil carries bold ONLY -- the achromatic structure
      # channel, byte-identical to the composer's own sigil styling.
      assert raw(device) =~ "\e[1m❯\e[0m why does the settle step"
      assert raw(device) =~ "\e[1m❮\e[0m The fold consulted"
    end

    test "the sigil never fades ahead of its block (single-fg + cadence-independent bytes)" do
      {model, device} = new_model(two_turn_events())
      _model = drive_to_completion(model)

      # t1's user-only block seals while t2 is already the current turn.
      # Two laws pin the sigil BOLD-ONLY here, not faded:
      #
      #   1. single-fg: the sigil fronts a mounted expanded message body,
      #      and that body carries no prominence fade today (BlockBody's
      #      documented T5 scope cut) -- a sigil fading alone would split
      #      one line's block into two salience levels;
      #   2. live/fixture byte parity (the compaction guard's red line):
      #      seal-time grade depends on reveal cadence (flush-at-bracket
      #      seals at 1.0, hold-back-one at 0.8), so a grade-derived
      #      sigil fg would make sealed history cadence-dependent.
      #
      # When the mount path threads prominence into message bodies, the
      # sigil must take the SAME resolved fg in the same change -- this
      # test is the tripwire that forces the two to move together.
      assert raw(device) =~ "\e[1m❯\e[0m first question"
      assert raw(device) =~ "\e[1m❮\e[0m The second answer."

      refute raw(device) =~ ~r/\e\[1;38;2;\d+;\d+;\d+m[❯❮]/,
             "a dialogue sigil must never carry a fade fg its block's " <>
               "body does not carry"
    end
  end
end
