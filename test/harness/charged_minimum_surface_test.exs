defmodule Raxol.Harness.ChargedMinimumSurfaceTest do
  @moduledoc """
  Byte-level pins for V's charged-minimum ruling on the assembled
  harness (`docs/proposals/in-flight/harness-visual-doctrine.md` §1.2
  "charged minimum", §4.2/§4.3 chassis channels), driving the REAL
  `InlineAuthority` through a `StringIO` device and reading the screen
  back through the `SealOracle` replay harness -- the same discipline as
  `t13a_surface_test.exs`.

  ## What this suite pins (each claim = a named test)

    * **The strip is a grown instrument.** Hidden on the boot frame and
      on the idle post-completion frame (no `Input: — | Stage: — | ...`
      voids); present while a turn is live; forced visible by a stall
      alert regardless of idleness (the safety override).
    * **The chevron sigil.** The composer row is prefixed with a
      flush-left `❯ ` -- the ONE thing on screen exempt from the margin
      -- bold via the ViewText SGR path; `unicode: :none` capability
      falls back to `>`; both sigils measure exactly one display column.
    * **The margins.** Sealed history lines and footer content carry a
      1-column left margin (content width shrinks BEFORE truncation);
      exactly one blank row separates consecutive sealed blocks; the
      first sealed line of a session opens without one.
    * **No hint line.** The removed first-focus hint never renders.
  """

  use ExUnit.Case, async: true

  alias Raxol.Harness.Surface
  alias Raxol.Harness.Test.SealOracle
  alias Raxol.Terminal.Emulator
  alias Raxol.UI.TextMeasure

  @width 60
  @rows 20
  @footer_rows 6
  @region_top @rows - @footer_rows

  # -- shared harness helpers (t13a conventions) -------------------------

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

  defp advance_times(model, 0), do: model

  defp advance_times(model, n) do
    {model, _status} = Surface.advance(model)
    advance_times(model, n - 1)
  end

  defp screen_rows(device) do
    device
    |> raw()
    |> SealOracle.replay(width: @width, height: @rows)
    |> Emulator.get_screen_buffer()
    |> Map.get(:cells)
    |> Enum.map(&row_text/1)
  end

  defp footer_rows(device), do: device |> screen_rows() |> Enum.drop(@region_top)
  defp history_rows(device), do: device |> screen_rows() |> Enum.take(@region_top)

  defp row_text(row_cells) do
    row_cells |> Enum.map_join("", &(&1.char || " ")) |> String.trim_trailing()
  end

  # A minimal one-turn, N-message-block event list (the live-seam wire
  # shape `advance/2` consumes).
  defp turn_events(contents) do
    items =
      contents
      |> Enum.with_index(1)
      |> Enum.flat_map(fn {content, i} ->
        [
          %{
            id: i * 2,
            turn_id: "t1",
            ts: i * 2,
            family: :loop,
            type: :item_started,
            tier: :durable,
            payload: %{"item_id" => "i#{i}", "item_type" => "message"}
          },
          %{
            id: i * 2 + 1,
            turn_id: "t1",
            ts: i * 2 + 1,
            family: :loop,
            type: :item_completed,
            tier: :durable,
            payload: %{
              "item_id" => "i#{i}",
              "item_type" => "message",
              "content" => content
            }
          }
        ]
      end)

    last_id = length(contents) * 2 + 2

    [
      %{
        id: 1,
        turn_id: "t1",
        ts: 1,
        family: :loop,
        type: :turn_started,
        tier: :durable,
        payload: %{"prompt" => "hi"}
      }
    ] ++
      items ++
      [
        %{
          id: last_id,
          turn_id: "t1",
          ts: last_id,
          family: :loop,
          type: :turn_completed,
          tier: :durable,
          payload: %{"status" => "ok"}
        }
      ]
  end

  # -- 1. the strip is a grown instrument --------------------------------

  describe "1. strip visibility (grown instrument, doctrine §1.2)" do
    test "the boot frame renders NO status strip -- no labelled voids" do
      {_model, device} = new_model([])
      footer = footer_rows(device)

      refute Enum.any?(footer, &String.contains?(&1, "Input:")),
             "boot footer must not carry the em-dash strip, got #{inspect(footer)}"

      refute Enum.any?(footer, &String.contains?(&1, "—"))
    end

    test "the strip appears while a turn is live and yields after completion" do
      events = turn_events(["Hello!"])
      {model, device} = new_model(events)

      # Mid-turn (turn_started + item_started revealed): live turn.
      model = advance_times(model, 2)

      assert Enum.any?(footer_rows(device), &String.contains?(&1, "thinking")),
             "the strip must be present during a live turn"

      # Post-completion idle frame: the strip yields to silence.
      _model = drive_to_completion(model)

      refute Enum.any?(footer_rows(device), &String.contains?(&1, "thinking")),
             "the strip must yield once the turn has completed"
    end

    test "a stall alert forces the strip visible even on an idle frame" do
      {model, device} = new_model([])

      _model =
        Surface.put_stall_verdict(model, %{
          class: :stalled,
          evidence: %{summary: "no output for 90s"}
        })

      assert Enum.any?(footer_rows(device), &String.contains?(&1, "ALERT:")),
             "a stall alert must never be hidden by the idle-frame gate"
    end
  end

  # -- 2. the chevron sigil ----------------------------------------------

  describe "2. the chevron prompt sigil (the one flush-left thing)" do
    test "the boot composer row starts with the chevron at column 0, bold" do
      {_model, device} = new_model([])

      chevron_row = Enum.find(footer_rows(device), &String.starts_with?(&1, "❯"))
      assert chevron_row != nil, "no flush-left chevron row on the boot frame"

      # Bold through the one ViewText SGR path -- the raw bytes carry the
      # bold SGR immediately around the sigil.
      assert raw(device) =~ "\e[1m❯\e[0m"
    end

    test "unicode: :none capability falls back to a plain '>'" do
      caps = %Raxol.Terminal.Capabilities{unicode: :none}
      {_model, device} = new_model([], capabilities: caps)

      footer = footer_rows(device)
      assert Enum.any?(footer, &String.starts_with?(&1, ">"))
      refute Enum.any?(footer, &String.contains?(&1, "❯"))
    end

    test "both sigils are width-honest: exactly one display column" do
      assert TextMeasure.display_width("❯") == 1
      assert TextMeasure.display_width(">") == 1
    end

    test "the removed first-focus hint never renders" do
      {_model, device} = new_model([])
      refute raw(device) =~ "paste multiline"
    end
  end

  # -- 3. margins ----------------------------------------------------------

  describe "3. the 1-column margin (chevron exempt)" do
    test "sealed dialogue rows carry their outer-contour sigil; blocks are separated by one blank row" do
      events = turn_events(["first block body", "second block body"])
      {model, device} = new_model(events)
      _model = drive_to_completion(model)

      history = history_rows(device)

      first = Enum.find_index(history, &String.contains?(&1, "first block body"))
      second = Enum.find_index(history, &String.contains?(&1, "second block body"))
      assert first != nil and second != nil

      # This fixture is assistant-message-only: under V's outer-contour
      # amendment every expanded message row is fronted by its speaker's
      # sigil at column 0 (`❮` here), content at the 2-cell indent. The
      # full dialogue-pair geometry (user `❯`, hang indents, machinery
      # margin) is pinned in speaker_separation_surface_test.exs; the
      # machinery margin itself in unread_divider_surface_test.exs.
      for row <- history, row != "" do
        assert String.starts_with?(row, "❮ ") or String.starts_with?(row, " "),
               "sealed history row must open with its dialogue sigil or " <>
                 "the left margin: #{inspect(row)}"
      end

      assert String.starts_with?(Enum.at(history, first), "❮ first block body")

      # The very first sealed line opens WITHOUT a leading blank row...
      assert history |> Enum.take_while(&(&1 == "")) == [],
             "history must not open with a separator blank"

      # ...and exactly one blank row sits between the two blocks.
      between = Enum.slice(history, (first + 1)..(second - 1))

      assert Enum.count(between, &(&1 == "")) == 1,
             "expected exactly one blank separator row between blocks, " <>
               "got #{inspect(between)}"
    end

    test "footer content is margined while the chevron row stays flush left" do
      events = turn_events(["Hello!"])
      {model, device} = new_model(events)
      # Mid-turn: strip visible AND composer present.
      _model = advance_times(model, 2)

      footer = footer_rows(device)

      strip_row = Enum.find(footer, &String.contains?(&1, "thinking"))
      assert strip_row != nil
      assert String.starts_with?(strip_row, " "), "strip row must be margined"

      assert Enum.any?(footer, &String.starts_with?(&1, "❯")),
             "chevron row must stay flush left"
    end
  end
end
