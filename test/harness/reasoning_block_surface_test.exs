defmodule Raxol.Harness.ReasoningBlockSurfaceTest do
  @moduledoc """
  Surface-level pins for the sealed reasoning (∴) block's transcript
  presentation (V's addendum to the reasoning-persistence unit):

    1. **Blank-row rhythm.** A sealed reasoning block participates in the
       one-blank-row-between-blocks vertical rhythm like every other
       transcript block — a blank row above it and a blank row below it
       (the `block_separator/1` law, not a reasoning special-case).
    2. **Peekable compact register.** It seals as the folded
       `∴ reasoning · N lines` one-line register, ahead of the answer.

  Low prominence (dim, machinery register) is pinned at the Block level
  in `Raxol.UI.Components.Harness.BlockTest` ("the folded reasoning line
  is DIM"); here we pin the transcript rhythm the driver imposes around
  it.

  Harness conventions mirror `Raxol.Harness.SpeakerSeparationSurfaceTest`
  (StringIO device -> SealOracle replay -> Emulator screen read).
  """

  use ExUnit.Case, async: true

  alias Raxol.Harness.Surface
  alias Raxol.Harness.Test.SealOracle
  alias Raxol.Terminal.Emulator

  @width 60
  @rows 20
  @footer_rows 6
  @region_top @rows - @footer_rows

  @user_prompt "do the task"
  @reasoning "plan the approach carefully"
  @assistant_answer "here is the result"

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

  defp history_rows(device),
    do: device |> screen_rows() |> Enum.take(@region_top)

  defp row_text(row_cells) do
    row_cells |> Enum.map_join("", &(&1.char || " ")) |> String.trim_trailing()
  end

  defp item(id, turn_id, item_id, item_type, content, extra \\ %{}) do
    [
      %{
        id: id,
        turn_id: turn_id,
        ts: id,
        family: :loop,
        type: :item_started,
        tier: :durable,
        payload: %{"item_id" => item_id, "item_type" => item_type}
      },
      %{
        id: id + 1,
        turn_id: turn_id,
        ts: id + 1,
        family: :loop,
        type: :item_completed,
        tier: :durable,
        payload:
          Map.merge(
            %{
              "item_id" => item_id,
              "item_type" => item_type,
              "content" => content
            },
            extra
          )
      }
    ]
  end

  # A realistic think→answer turn (the ACP projected shape): user echo,
  # then a sealed reasoning block, then the assistant answer.
  defp think_answer_events do
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
      item(2, "t1", "i1", "message", @user_prompt, %{"role" => "user"}),
      item(4, "t1", "i2", "reasoning", @reasoning),
      item(6, "t1", "i3", "message", @assistant_answer, %{"role" => "assistant"}),
      %{
        id: 8,
        turn_id: "t1",
        ts: 8,
        family: :loop,
        type: :turn_completed,
        tier: :durable,
        payload: %{"final" => true, "status" => "ok"}
      }
    ]
    |> List.flatten()
  end

  test "reasoning seals as the folded `∴ reasoning · N lines` register" do
    {model, device} = new_model(think_answer_events())
    _model = drive_to_completion(model)

    history = history_rows(device)

    assert Enum.any?(history, &(&1 =~ "∴ reasoning · 1 line")),
           "no folded ∴ reasoning register in history: #{inspect(history)}"
  end

  test "the reasoning block gets the one-blank-row rhythm above AND below it" do
    {model, device} = new_model(think_answer_events())
    _model = drive_to_completion(model)

    history = history_rows(device)

    reasoning_index = Enum.find_index(history, &(&1 =~ "∴ reasoning"))
    assert reasoning_index != nil, "no reasoning row: #{inspect(history)}"

    # Blank row ABOVE the reasoning block (its separator from the user echo).
    assert Enum.at(history, reasoning_index - 1) == "",
           "expected a blank row above the reasoning block, got " <>
             inspect(Enum.slice(history, max(reasoning_index - 2, 0), 3))

    # Exactly one blank row BELOW it, before the assistant answer (the
    # assistant block's own separator) — same rhythm every block gets.
    assistant_index = Enum.find_index(history, &(&1 =~ "here is the result"))
    assert assistant_index != nil and assistant_index > reasoning_index

    between = Enum.slice(history, (reasoning_index + 1)..(assistant_index - 1))

    assert Enum.count(between, &(&1 == "")) == 1,
           "expected exactly one blank separator row between the reasoning " <>
             "block and the answer, got #{inspect(between)}"
  end
end
