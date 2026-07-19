defmodule Raxol.Harness.HarnessAppChoiceTest do
  @moduledoc """
  The live-approval ChoicePrompt wired into the harness fold (V's
  selector-and-prompt footer), pinned end-to-end:

    * a live approval mounts the prompt (labels = the block's REAL option
      names); the sealed answer unmounts it;
    * empty-draft Enter → allow, Escape → deny — through the REAL
      approval-answer dispatch (stub notices in fixture mode);
    * typed text: hints yield, Enter = deny + steer(text) (the free-text
      third way), Escape clears first;
    * 'y' inserts into the draft — the old keymap alias never steals a
      typed letter while the prompt owns the input.
  """
  use ExUnit.Case, async: true

  alias Raxol.Core.Events.Event
  alias Raxol.Harness.HarnessApp.Model
  alias Raxol.UI.Components.Harness.ChoicePrompt

  defp ev(id, type, payload) do
    %{
      id: id,
      turn_id: "t1",
      ts: 100 + id,
      family: :loop,
      type: type,
      tier: :durable,
      payload: payload
    }
  end

  defp approval_model do
    Model.build(width: 80, rows: 24, stream_open: true)
    |> Model.fold_batch([
      {:event, ev(1, :turn_started, %{})},
      {:event,
       ev(2, :approval_requested, %{
         "request_id" => "appr-1",
         "tool_name" => "edit_file",
         "action" => "edit_file",
         "path" => "mix.exs",
         "old" => "a\nOLD\n",
         "new" => "a\nNEW\n",
         "diff" => true,
         "options" => [
           %{"option_id" => "ok", "name" => "Allow", "kind" => "allow_once"},
           %{"option_id" => "no", "name" => "Deny", "kind" => "reject_once"}
         ]
       })}
    ])
  end

  defp press(model, key, modifiers \\ []) do
    Model.handle_key(model, Event.key_event(key, :pressed, modifiers))
  end

  defp type(model, text) do
    text
    |> String.graphemes()
    |> Enum.reduce(model, fn char, acc ->
      {m, _cmds} = press(acc, char)
      m
    end)
  end

  test "a live approval mounts the prompt with the block's REAL option names" do
    model = approval_model()

    assert Model.choice_active?(model)
    assert model.choice.confirm_label == "Allow"
    assert model.choice.cancel_label == "Deny"
    assert model.choice.placeholder == "explain what to do instead"
  end

  test "the answered approval unmounts the prompt" do
    model = approval_model()

    sealed =
      Model.fold_batch(model, [
        {:event,
         ev(3, :approval_decided, %{
           "request_id" => "appr-1",
           "decision" => "allow",
           "option_id" => "ok"
         })}
      ])

    refute Model.choice_active?(sealed)
    assert sealed.choice == nil
  end

  test "empty-draft Enter answers ALLOW through the real dispatch (fixture stub)" do
    {model, directives} = approval_model() |> press(:enter)

    assert directives == []
    assert model.stub_notice =~ "would answer the approval"
  end

  test "empty-draft Escape answers DENY through the real dispatch (fixture stub)" do
    {model, directives} = approval_model() |> press(:escape)

    assert directives == []
    assert model.stub_notice =~ "would answer the approval"
  end

  test "typed text + Enter = deny AND steer the explanation (the third way)" do
    model = approval_model() |> type("use a smaller hunk")
    {answered, directives} = press(model, :enter)

    assert directives == []
    # both rails fired in fixture mode: the deny stub is overwritten by
    # the steer stub (last honest notice wins) — assert the steer carried
    # the typed text and the composer came back empty
    assert answered.stub_notice =~ "would steer: use a smaller hunk"
    assert Raxol.UI.Components.Harness.Composer.value(answered.composer) == ""
  end

  test "Escape with a draft clears it first; the second Escape denies" do
    model = approval_model() |> type("half a thought")
    {cleared, []} = press(model, :escape)

    assert ChoicePrompt.value(cleared.choice) == ""
    assert Model.choice_active?(cleared)

    {denied, []} = press(cleared, :escape)
    assert denied.stub_notice =~ "would answer the approval"
  end

  test "'y' inserts into the draft — the keymap alias never steals typed text" do
    model = approval_model() |> type("y")

    assert ChoicePrompt.value(model.choice) == "y"
    assert model.stub_notice == nil
  end

  test "arrows walk the prompt's focus, and Enter fires the focused option" do
    model = approval_model()
    {model, []} = press(model, :up)
    assert model.choice.focus == :cancel

    {denied, []} = press(model, :enter)
    assert denied.stub_notice =~ "would answer the approval"
  end

  test "resize remounts the prompt at the new width, draft preserved" do
    model = approval_model() |> type("keep me")
    resized = Model.resize(model, 100, 30)

    assert Model.choice_active?(resized)
    assert ChoicePrompt.value(resized.choice) == "keep me"
  end
end
