defmodule Raxol.Harness.HarnessAppSlashTest do
  @moduledoc """
  The slash-command inlet, pinned end-to-end at the model fold + view:

    * `/` opens command mode — the popup renders the registry matches on
      top of the layer, the selector yields, the cursor stays parked;
    * Up/Down move the popup selection (clamped), a query change resets it;
    * Tab completes the draft from the selection; Enter executes the
      selection and NEVER submits slash text as a prompt; Escape clears;
    * unknown command → honest refusal notice, draft kept;
    * the executed commands ride the existing dispatch vocabulary
      (palette/panel opens, approval refusals, steer staging, /help seal).
  """
  use ExUnit.Case, async: true

  alias Raxol.Core.Events.Event
  alias Raxol.Harness.HarnessApp.{Model, View}
  alias Raxol.UI.Components.Harness.Composer
  alias Raxol.UI.Harness.CommandRegistry

  defp new_model(opts \\ []) do
    Model.build(Keyword.merge([width: 80, rows: 24], opts))
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

  defp flatten_text(%{type: :text, content: c}) when is_binary(c), do: c

  defp flatten_text(%{} = el) do
    flow = el |> Map.get(:flow_child) |> List.wrap()
    overlays = el |> Map.get(:overlays, []) |> Enum.map(&Map.get(&1, :element))
    children = el |> Map.get(:children, []) |> List.wrap()
    (flow ++ children ++ overlays) |> Enum.map_join(" ", &flatten_text/1)
  end

  defp flatten_text(list) when is_list(list),
    do: Enum.map_join(list, " ", &flatten_text/1)

  defp flatten_text(_), do: ""

  # ── registry ─────────────────────────────────────────────────────────────

  describe "CommandRegistry" do
    test "parse splits name and args; mid-text and multi-line are not slash" do
      assert CommandRegistry.parse("/steer fix the test") ==
               {"steer", "fix the test"}

      assert CommandRegistry.parse("/help") == {"help", ""}
      assert CommandRegistry.parse("/") == {"", ""}
      assert CommandRegistry.parse("say /help") == :not_slash
      assert CommandRegistry.parse("/steer\nline2") == :not_slash
    end

    test "match is a prefix filter; empty query is the full vocabulary" do
      assert length(CommandRegistry.match("")) == length(CommandRegistry.all())
      assert [%{name: "steer"}] = CommandRegistry.match("st")
      assert CommandRegistry.match("zzz") == []
    end

    test "every entry has a description and a runnable form" do
      for entry <- CommandRegistry.all() do
        assert entry.description != ""
        assert entry.args in [:none, :text]

        assert match?({:dispatch, %{type: _}}, entry.run) or
                 entry.run in [:help, :session, :steer, :quit]
      end
    end
  end

  # ── command mode: popup + selector precedence + cursor ──────────────────

  describe "command mode (view)" do
    test "a / draft renders the popup as an overlay: first window of the registry" do
      model = new_model() |> type("/")
      view = View.render(model)

      assert view.type == :absolute_layer
      [%{element: popup} | _] = view.overlays
      text = flatten_text(popup)

      # the 6-row window shows the alphabetical head...
      assert text =~ "/approve"
      assert text =~ "/help"
      assert text =~ "list every command"
      # ... and is honest about being a window (steer sits below it)
      refute text =~ "/steer"
    end

    test "the window follows the selection past the cap" do
      model = new_model() |> type("/")
      count = length(CommandRegistry.match(""))

      model =
        Enum.reduce(1..(count - 1), model, fn _i, acc ->
          {m, []} = press(acc, :down)
          m
        end)

      [%{element: popup} | _] = View.render(model).overlays
      text = flatten_text(popup)

      assert text =~ "/worktracks"
      refute text =~ "/approve"
    end

    test "the popup filters as the query narrows" do
      model = new_model() |> type("/ste")
      [%{element: popup} | _] = View.render(model).overlays
      text = flatten_text(popup)

      assert text =~ "/steer"
      refute text =~ "/help"
    end

    test "the cursor stays parked in the composer while the popup shows" do
      model = new_model() |> type("/he")
      view = View.render(model)

      assert view.type == :absolute_layer
      assert {_row, _col, true} = view.cursor
    end

    test "no popup for a mid-text slash or an empty draft" do
      assert View.render(new_model() |> type("say /help")).type !=
               :absolute_layer

      assert View.render(new_model()).type != :absolute_layer
    end

    test "the popup wins over the approval selector (V's canonical footer)" do
      model =
        new_model(stream_open: true)
        |> Model.fold_batch([
          {:event,
           %{
             id: 1,
             turn_id: "t1",
             ts: 100,
             family: :loop,
             type: :turn_started,
             tier: :durable,
             payload: %{}
           }},
          {:event,
           %{
             id: 2,
             turn_id: "t1",
             ts: 110,
             family: :loop,
             type: :approval_requested,
             tier: :durable,
             payload: %{
               "request_id" => "r1",
               "tool_name" => "edit_file",
               "action" => "edit_file",
               "options" => [
                 %{
                   "option_id" => "a",
                   "name" => "Allow",
                   "kind" => "allow_once"
                 }
               ]
             }
           }}
        ])

      # selector present while idle
      assert flatten_text(View.render(model)) =~ "1 Allow"

      # ... and suppressed the moment a slash draft goes live
      slashed = type(model, "/")
      text = flatten_text(View.render(slashed))
      refute text =~ "1 Allow"
      assert View.render(slashed).type == :absolute_layer
    end
  end

  # ── selection + completion ───────────────────────────────────────────────

  describe "selection and completion" do
    test "Down/Up move the selection, clamped at the ends" do
      model = new_model() |> type("/")
      assert model.slash_selected == 0

      {model, []} = press(model, :up)
      assert model.slash_selected == 0

      {model, []} = press(model, :down)
      assert model.slash_selected == 1

      count = length(CommandRegistry.match(""))

      model =
        Enum.reduce(1..(count + 3), model, fn _i, acc ->
          {m, []} = press(acc, :down)
          m
        end)

      assert model.slash_selected == count - 1
    end

    test "a query change resets the selection" do
      model = new_model() |> type("/")
      {model, []} = press(model, :down)
      assert model.slash_selected == 1

      model = type(model, "h")
      assert model.slash_selected == 0
    end

    test "Tab completes the draft from the selection (text commands park before the args)" do
      model = new_model() |> type("/ste")
      {model, []} = press(model, :tab)
      assert Composer.value(model.composer) == "/steer "

      model = new_model() |> type("/hel")
      {model, []} = press(model, :tab)
      assert Composer.value(model.composer) == "/help"
    end
  end

  # ── execution ────────────────────────────────────────────────────────────

  describe "execution" do
    test "Enter never submits slash text as a prompt" do
      model = new_model() |> type("/help")
      {model, directives} = press(model, :enter)

      assert directives == []
      assert model.pending_submit == nil
    end

    test "/help seals the command list into the transcript and clears the draft" do
      model = new_model() |> type("/help")
      {model, []} = press(model, :enter)

      assert Composer.value(model.composer) == ""

      sealed =
        model.transcript_records
        |> Enum.map(fn {:marker, text} -> text end)
        |> Enum.join("\n")

      assert sealed =~ "slash commands:"

      for entry <- CommandRegistry.all() do
        assert sealed =~ "/" <> entry.name
      end
    end

    test "/palette opens the picker overlay" do
      model = new_model() |> type("/palette")
      {model, []} = press(model, :enter)
      assert match?({:picker, _}, model.overlay)
    end

    test "/memory opens the memory panel" do
      model = new_model() |> type("/memory")
      {model, []} = press(model, :enter)
      assert model.overlay == {:panel, :memory}
    end

    test "Enter runs the SELECTED match on a prefix query" do
      # "/s" matches session + steer (alphabetical); Down selects steer,
      # which refuses without text — proof the selection, not the prefix,
      # was executed.
      model = new_model() |> type("/s")
      {model, []} = press(model, :down)
      {model, []} = press(model, :enter)

      assert model.lane_notice =~ "/steer needs text"
    end

    test "unknown command → honest refusal, draft kept for the fix-up" do
      model = new_model() |> type("/nope")
      {model, []} = press(model, :enter)

      assert model.lane_notice =~ "no such command: /nope"
      assert Composer.value(model.composer) == "/nope"
    end

    test "/steer <text> queues the steer and clears the draft (fixture stub)" do
      model = new_model() |> type("/steer focus the diff")
      {model, []} = press(model, :enter)

      assert model.stub_notice =~ "would steer: focus the diff"
      assert Composer.value(model.composer) == ""
    end

    test "/approve without a live approval refuses honestly" do
      model = new_model() |> type("/approve")
      {model, []} = press(model, :enter)

      assert model.lane_notice =~ "no approval is awaiting an answer"
    end

    test "Escape clears the draft and closes command mode" do
      model = new_model() |> type("/hel")
      {model, []} = press(model, :escape)

      assert Composer.value(model.composer) == ""
      refute Model.slash_active?(model)
    end

    test "Shift+Enter keeps authoring (multi-line leaves command mode)" do
      model = new_model() |> type("/steer long")
      {model, []} = press(model, :enter, [:shift])

      assert Composer.value(model.composer) =~ "\n"
      refute Model.slash_active?(model)
    end
  end
end
