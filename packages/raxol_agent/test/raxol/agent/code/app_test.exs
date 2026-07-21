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

  describe "interactive approval" do
    test "an approval request sets the pending state and working face" do
      ref = make_ref()
      msg = {:command_result, {:approval_request, ref, self(), "write_file"}}
      {model, []} = App.update(msg, %{new_model() | running?: true})

      assert model.pending_approval.name == "write_file"
      assert model.face_state == :working
    end

    test "'y' allows the pending tool and replies to the waiter" do
      ref = make_ref()
      {model, []} =
        App.update(
          {:command_result, {:approval_request, ref, self(), "bash"}},
          %{new_model() | running?: true}
        )

      {model, []} = App.update(key("y"), model)

      assert model.pending_approval == nil
      assert_receive {:approval_decision, ^ref, :allow}
    end

    test "'n' and Esc both deny the pending tool" do
      for denier <- [key("n"), key(:escape)] do
        ref = make_ref()
        {model, []} =
          App.update(
            {:command_result, {:approval_request, ref, self(), "write_file"}},
            %{new_model() | running?: true}
          )

        {model, []} = App.update(denier, model)
        assert model.pending_approval == nil
        assert_receive {:approval_decision, ^ref, :deny}
      end
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
