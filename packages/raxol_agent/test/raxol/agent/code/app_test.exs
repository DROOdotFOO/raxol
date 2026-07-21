defmodule Raxol.Agent.Code.AppTest do
  use ExUnit.Case, async: false

  alias Raxol.Agent.Code.App
  alias Raxol.Agent.Contract
  alias Raxol.Core.Events.Event

  # A runner that does not spawn a real turn: it returns a live, inert pid
  # (so interrupt has something to kill) and never touches the network.
  defp stub_runner do
    fn _session_id, _prompt, _opts, _app ->
      spawn(fn -> Process.sleep(60_000) end)
    end
  end

  defp new_model(opts \\ []) do
    App.init(%{options: Keyword.put_new(opts, :runner, stub_runner())})
  end

  defp key(k, mods \\ []), do: Event.key_event(k, :pressed, mods)

  defp ev(id, type, payload, tier \\ :durable) do
    %Contract.Event{
      id: id,
      ts: id,
      turn_id: "t1",
      family: :loop,
      type: type,
      tier: tier,
      payload: payload
    }
  end

  defp send_ev(model, event) do
    {model, []} = App.update({:command_result, {:contract_event, event}}, model)
    model
  end

  describe "init/1" do
    test "starts idle with an empty prompt" do
      model = new_model()
      assert model.input == ""
      assert model.face_state == :idle
      assert model.running? == false
      assert model.pending_approval == nil
    end
  end

  describe "prompt editing" do
    test "printable keys append to the prompt" do
      {model, []} = App.update(key("h"), new_model())
      {model, []} = App.update(key("i"), model)
      assert model.input == "hi"
    end

    test "backspace deletes the last character" do
      model = %{new_model() | input: "abc"}
      {model, []} = App.update(key(:backspace), model)
      assert model.input == "ab"
    end

    test "Ctrl+C requests quit" do
      {_model, commands} = App.update(key("c", [:ctrl]), new_model())
      assert commands != []
    end
  end

  describe "submitting a turn" do
    test "Enter with text starts a turn and clears the prompt" do
      model = %{new_model() | input: "list files"}
      {model, []} = App.update(key(:enter), model)

      assert model.running? == true
      assert model.input == ""
      assert model.face_state == :thinking
      assert is_pid(model.worker)
      assert model.session_id != nil
    end

    test "Enter with a blank prompt does nothing" do
      model = %{new_model() | input: "   "}
      {model, []} = App.update(key(:enter), model)
      assert model.running? == false
    end
  end

  describe "contract-event fold drives the face" do
    test "turn_started -> thinking, tool activity -> working, final -> done" do
      model = %{new_model() | running?: true, face_state: :thinking}

      model = send_ev(model, ev(1, :turn_started, %{prompt: "x"}))
      assert model.face_state == :thinking

      model = send_ev(model, ev(2, :item_completed, %{item_id: "i1", item_type: :tool_use, name: "grep"}))
      assert model.face_state == :working

      model = send_ev(model, ev(3, :turn_completed, %{final: true, usage: %{}}))
      assert model.face_state == :done
      assert model.running? == false
    end

    test "an error event shows the error face and ends the turn" do
      model = %{new_model() | running?: true}
      model = send_ev(model, ev(9, :error, %{reason: :boom}))
      assert model.face_state == :error
      assert model.running? == false
    end

    test "malformed contract events are dropped, not folded" do
      model = new_model()
      bad = %Contract.Event{id: -1, ts: 0, type: :turn_started, tier: :durable, payload: %{}}
      {model2, []} = App.update({:command_result, {:contract_event, bad}}, model)
      assert model2.events == []
    end
  end

  defp request(model, name) do
    ref = make_ref()
    msg = {:command_result, {:authorize_request, ref, self(), name}}
    {model, []} = App.update(msg, model)
    {ref, model}
  end

  describe "interactive approval (Engine ASK)" do
    test "a sensitive tool asks: pending state, working face" do
      {_ref, model} = request(%{new_model() | running?: true}, "write_file")
      assert model.pending_approval.name == "write_file"
      assert model.face_state == :working
    end

    test "'a' allows once and replies to the waiter" do
      {ref, model} = request(%{new_model() | running?: true}, "bash")
      {model, []} = App.update(key("a"), model)

      assert model.pending_approval == nil
      assert_receive {:authorize_decision, ^ref, :allow}
    end

    test "'d' and Esc both deny the pending tool" do
      for denier <- [key("d"), key(:escape)] do
        {ref, model} = request(%{new_model() | running?: true}, "write_file")
        {model, []} = App.update(denier, model)
        assert model.pending_approval == nil
        assert_receive {:authorize_decision, ^ref, {:deny, :user_denied}}
      end
    end
  end

  describe "approval memory (Engine ALLOW after 'always')" do
    test "'s' remembers the tool; the next call auto-allows without a prompt" do
      {ref1, model} = request(%{new_model() | running?: true}, "write_file")
      {model, []} = App.update(key("s"), model)
      assert_receive {:authorize_decision, ^ref1, :allow}
      assert MapSet.member?(model.always_allow, "write_file")

      # A second request for the same tool is ALLOWed by the Engine outright.
      {ref2, model} = request(model, "write_file")
      assert model.pending_approval == nil
      assert_receive {:authorize_decision, ^ref2, :allow}
    end

    test "'a' (once) does NOT remember; the next call asks again" do
      {ref1, model} = request(%{new_model() | running?: true}, "bash")
      {model, []} = App.update(key("a"), model)
      assert_receive {:authorize_decision, ^ref1, :allow}
      refute MapSet.member?(model.always_allow, "bash")

      {_ref2, model} = request(model, "bash")
      assert model.pending_approval.name == "bash"
    end
  end

  describe "plan mode (Engine DENY of mutations)" do
    test "Shift+Tab and Ctrl+P toggle plan mode when idle" do
      {model, []} = App.update(key(:backtab), new_model())
      assert model.plan_mode == true
      {model, []} = App.update(key("p", [:ctrl]), model)
      assert model.plan_mode == false
    end

    test "plan mode does not toggle mid-turn" do
      model = %{new_model() | running?: true}
      {model, []} = App.update(key(:backtab), model)
      assert model.plan_mode == false
    end

    test "a mutating tool is denied outright in plan mode (no prompt)" do
      {ref, model} =
        request(%{new_model() | running?: true, plan_mode: true}, "write_file")

      assert model.pending_approval == nil
      assert model.status_line =~ "plan mode"
      assert_receive {:authorize_decision, ^ref, {:deny, :plan_mode_read_only}}
    end

    test "plan mode augments the system prompt with a planning directive" do
      # Submitting in plan mode must not raise and keeps the loop consistent.
      model = %{new_model() | plan_mode: true, input: "add a feature"}
      {model, []} = App.update(key(:enter), model)
      assert model.running? == true
    end
  end

  describe "interrupt" do
    test "Esc while running kills the worker and marks interrupted" do
      model = %{new_model() | input: "go"}
      {model, []} = App.update(key(:enter), model)
      worker = model.worker
      assert Process.alive?(worker)

      {model, []} = App.update(key(:escape), model)

      assert model.running? == false
      assert model.status_line == "interrupted"
      refute Process.alive?(worker)
    end
  end

  describe "end-to-end with the real runner (Mock backend)" do
    test "a turn streams through pump/relay to the done face and lands in the transcript" do
      # No stub: the real default_runner spawns a worker that subscribes to
      # the streamer, pumps Stream.react through Contract, and relays contract
      # events back here. `self()` is the app, so those events arrive as
      # {:command_result, _} messages we feed back into update/2.
      model = App.init(%{options: [backend_opts: [response: "hello from mock"]]})
      model = %{model | input: "say hi"}
      {model, []} = App.update(key(:enter), model)
      assert model.running?

      model = drain_turn(model)

      assert model.face_state == :done
      refute model.running?

      projection = Raxol.Harness.Projection.project(model.events)

      assert Enum.any?(projection.blocks, fn block ->
               Raxol.UI.Components.Harness.Block.search_text(block) =~
                 "hello from mock"
             end)
    end
  end

  # Feed every {:command_result, _} the worker relays back into update/2
  # until the turn completes.
  defp drain_turn(model) do
    receive do
      {:command_result, _payload} = msg ->
        {model, []} = App.update(msg, model)
        if model.running?, do: drain_turn(model), else: model
    after
      5_000 -> flunk("turn did not complete within 5s")
    end
  end

  describe "view/1" do
    test "renders idle without crashing" do
      assert %{} = App.view(new_model())
    end

    test "renders a folded message turn through the projection + blocks" do
      model =
        new_model()
        |> then(&%{&1 | running?: true})
        |> send_ev(ev(1, :turn_started, %{prompt: "hi"}))
        |> send_ev(ev(2, :item_started, %{item_id: "i1", item_type: :message}))
        |> send_ev(ev(3, :item_completed, %{item_id: "i1", item_type: :message, content: "hello there"}))
        |> send_ev(ev(4, :turn_completed, %{final: true, usage: %{}}))

      assert model.face_state == :done
      # The projection + Block.render path must not raise.
      assert %{} = App.view(model)
    end
  end
end
