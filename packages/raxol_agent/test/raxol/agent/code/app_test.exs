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
    opts =
      opts
      |> Keyword.put_new(:runner, stub_runner())
      |> Keyword.put_new(:sessions_dir, tmp_dir())

    App.init(%{options: opts})
  end

  # `unique_integer` restarts every BEAM run and these dirs outlive the
  # run, so a time component keeps reruns from colliding with leftovers.
  defp tmp_dir do
    Path.join(
      System.tmp_dir!(),
      "raxol-code-app-#{System.os_time(:millisecond)}-" <>
        "#{System.unique_integer([:positive])}"
    )
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

  defp tev(turn_id, id, type, payload, tier \\ :durable),
    do: %{ev(id, type, payload, tier) | turn_id: turn_id}

  defp message_turn(turn_id, answer) do
    [
      tev(turn_id, 1, :turn_started, %{prompt: "ask"}),
      tev(turn_id, 2, :item_started, %{item_id: "i1", item_type: :message}),
      tev(turn_id, 3, :item_completed, %{
        item_id: "i1",
        item_type: :message,
        content: answer
      }),
      tev(turn_id, 4, :turn_completed, %{final: true, usage: %{}})
    ]
  end

  defp send_ev(model, event) do
    {model, []} = App.update({:command_result, {:contract_event, event}}, model)
    model
  end

  defp submit(model, text), do: App.update(key(:enter), %{model | input: text})

  defp config_cwd(files) do
    dir = tmp_dir()

    Enum.each(files, fn {rel, content} ->
      path = Path.join(dir, rel)
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, content)
    end)

    dir
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

      model =
        send_ev(
          model,
          ev(2, :item_completed, %{
            item_id: "i1",
            item_type: :tool_use,
            name: "grep"
          })
        )

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

    test "a mid-session 401 routes back to onboarding, preserving the conversation" do
      model =
        %{
          new_model(provider_status: {:ready, :anthropic, :env})
          | running?: true,
            messages: [%{role: :user, content: "hi"}]
        }

      model = send_ev(model, ev(9, :error, %{reason: {:http_error, 401, ""}}))

      # Routed back to onboarding (setup panel + gate), not the bare error face.
      assert model.provider_status == {:no_key, :anthropic}
      assert model.notice =~ "/login"
      # The conversation survives so /login reconnects and continues.
      assert model.messages == [%{role: :user, content: "hi"}]

      # A further prompt is now gated on reconnect, never starting a turn.
      {gated, []} = submit(model, "again")
      refute gated.running?
    end

    test "the streaming auth-error shape (\"HTTP 403\") also routes back to onboarding" do
      model = %{
        new_model(provider_status: {:ready, :openai, :env})
        | running?: true
      }

      model = send_ev(model, ev(9, :error, %{reason: "HTTP 403"}))
      assert model.provider_status == {:no_key, :openai}
    end

    test "a non-auth error keeps the provider connected" do
      model = %{
        new_model(provider_status: {:ready, :anthropic, :env})
        | running?: true
      }

      model = send_ev(model, ev(9, :error, %{reason: :boom}))
      assert model.provider_status == {:ready, :anthropic, :env}
      assert model.face_state == :error
    end

    test "auth_rejected?/1 recognizes both the structured and streaming shapes" do
      assert App.auth_rejected?({:http_error, 401, ""})
      assert App.auth_rejected?({:http_error, 403, "body"})
      assert App.auth_rejected?("HTTP 401")
      refute App.auth_rejected?({:http_error, 500, ""})
      refute App.auth_rejected?("HTTP 500")
      refute App.auth_rejected?(:boom)
    end

    test "malformed contract events are dropped, not folded" do
      model = new_model()

      bad = %Contract.Event{
        id: -1,
        ts: 0,
        type: :turn_started,
        tier: :durable,
        payload: %{}
      }

      {model2, []} =
        App.update({:command_result, {:contract_event, bad}}, model)

      assert model2.events == []
    end
  end

  alias Raxol.Agent.ExecutorConfig

  defp connected_model(opts \\ []) do
    [
      executor: ExecutorConfig.new(backend: :openai, model: "gpt-4o"),
      provider_status: {:ready, :openai, :env},
      # A connected provider has a current model (set on connect from the
      # executor); reflected here so the picker cursor has something to land on.
      model: "gpt-4o",
      models_fetcher: fn _opts, _ref, _app -> :ok end
    ]
    |> Keyword.merge(opts)
    |> new_model()
  end

  defp slash(model, command),
    do:
      App.update(Event.key_event(:enter, :pressed, []), %{
        model
        | input: command
      })

  describe "/model picker" do
    test "/model with no arg on a connected provider kicks off a fetch" do
      test_pid = self()

      model =
        connected_model(
          models_fetcher: fn opts, ref, _app ->
            send(test_pid, {:fetched, opts, ref})
          end
        )

      {model, []} = slash(model, "/model")

      assert model.models_ref != nil
      assert model.status_line == "fetching models…"
      # opts carry the connected provider so the right endpoint is chosen.
      assert_received {:fetched, opts, ref}
      assert opts[:provider] == :openai
      assert ref == model.models_ref
    end

    test "a model-list result opens a selectable picker, cursor on the current model" do
      model = connected_model()
      {model, []} = slash(model, "/model")
      ref = model.models_ref

      {model, []} =
        App.update(
          {:command_result,
           {:models_list, ref, {:ok, ["gpt-4o-mini", "gpt-4o"]}}},
          model
        )

      assert model.wizard.step == :models

      assert Enum.map(model.wizard.entries, & &1.model) == [
               "gpt-4o-mini",
               "gpt-4o"
             ]

      # cursor lands on the current model_override ("gpt-4o", index 1)
      assert model.wizard.cursor == 1
      assert model.models_ref == nil
    end

    test "arrow keys move and Enter selects a model, closing the picker" do
      model = connected_model()
      {model, []} = slash(model, "/model")

      {model, []} =
        App.update(
          {:command_result,
           {:models_list, model.models_ref, {:ok, ["a", "b", "c"]}}},
          model
        )

      # cursor starts at 0 ("gpt-4o" not in list); down twice -> "c"
      {model, []} = App.update(key(:down), model)
      {model, []} = App.update(key(:down), model)
      {model, []} = App.update(key(:enter), model)

      assert model.model_override == "c"
      assert model.wizard == nil
      assert model.notice =~ "model set to c"
    end

    test "Esc cancels the picker without changing the model" do
      model = connected_model()
      {model, []} = slash(model, "/model")

      {model, []} =
        App.update(
          {:command_result, {:models_list, model.models_ref, {:ok, ["x"]}}},
          model
        )

      {model, []} = App.update(key(:escape), model)
      assert model.wizard == nil
      assert model.model_override == "gpt-4o"
    end

    test "an empty / unsupported / errored list falls back to the usage notice" do
      for result <- [{:ok, []}, :unsupported, {:error, :request_failed}] do
        model = connected_model()
        {model, []} = slash(model, "/model")

        {model, []} =
          App.update(
            {:command_result, {:models_list, model.models_ref, result}},
            model
          )

        assert model.wizard == nil
        assert model.notice =~ "/model <name>"
      end
    end

    test "/model <name> still sets the model directly (no fetch)" do
      test_pid = self()

      model =
        connected_model(
          models_fetcher: fn _o, _r, _a -> send(test_pid, :fetched) end
        )

      {model, []} = slash(model, "/model claude-sonnet-5")

      assert model.model_override == "claude-sonnet-5"
      refute_received :fetched
    end

    test "a stale models_list result (superseded ref) is ignored" do
      model = connected_model()
      {model, []} = slash(model, "/model")

      {model, []} =
        App.update(
          {:command_result, {:models_list, make_ref(), {:ok, ["z"]}}},
          model
        )

      # the stale ref did not open a picker
      assert model.wizard == nil
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
      model =
        App.init(%{
          options: [
            backend_opts: [response: "hello from mock"],
            sessions_dir: tmp_dir()
          ]
        })

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

      # Conversation memory: the turn is now in the message history.
      assert %{role: :user, content: "say hi"} in model.messages

      assert Enum.any?(model.messages, fn m ->
               m.role == :assistant and m.content =~ "hello from mock"
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
        |> send_ev(
          ev(3, :item_completed, %{
            item_id: "i1",
            item_type: :message,
            content: "hello there"
          })
        )
        |> send_ev(ev(4, :turn_completed, %{final: true, usage: %{}}))

      assert model.face_state == :done
      # The projection + Block.render path must not raise.
      assert %{} = App.view(model)
    end
  end

  describe "conversation memory" do
    test "a submitted prompt enters the message history" do
      model = %{new_model() | input: "list files"}
      {model, []} = App.update(key(:enter), model)
      assert %{role: :user, content: "list files"} in model.messages
    end

    test "a completed turn appends the assistant reply and persists it" do
      dir = tmp_dir()
      model = App.init(%{options: [runner: stub_runner(), sessions_dir: dir]})
      model = %{model | input: "hi"}
      {model, []} = App.update(key(:enter), model)

      model =
        model
        |> send_ev(ev(1, :turn_started, %{prompt: "hi"}))
        |> send_ev(
          ev(2, :item_completed, %{
            item_id: "i1",
            item_type: :message,
            content: "done"
          })
        )
        |> send_ev(ev(3, :turn_completed, %{final: true, usage: %{}}))

      assert List.last(model.messages) == %{role: :assistant, content: "done"}
      assert {:ok, saved} = Raxol.Agent.Code.Store.load(dir, model.session_key)
      assert List.last(saved.messages) == %{role: :assistant, content: "done"}
    end
  end

  describe "resume" do
    test "init with a saved session_key reloads its messages" do
      dir = tmp_dir()

      msgs = [
        %{role: :user, content: "earlier"},
        %{role: :assistant, content: "reply"}
      ]

      :ok = Raxol.Agent.Code.Store.save(dir, "sess-x", %{messages: msgs})

      model =
        App.init(%{
          options: [
            runner: stub_runner(),
            sessions_dir: dir,
            session_key: "sess-x"
          ]
        })

      assert model.messages == msgs
      assert model.status_line =~ "resumed 2"
    end

    test "resuming a missing session starts fresh with a notice" do
      model =
        App.init(%{
          options: [
            runner: stub_runner(),
            sessions_dir: tmp_dir(),
            session_key: "nope"
          ]
        })

      assert model.messages == []
      assert model.status_line =~ "not found"
    end

    test "resuming rebuilds the visual transcript from persisted events" do
      dir = tmp_dir()

      # A turn that persists its durable events on completion.
      model = App.init(%{options: [runner: stub_runner(), sessions_dir: dir]})
      {model, []} = App.update(key(:enter), %{model | input: "hi"})

      model =
        model
        |> send_ev(ev(1, :turn_started, %{prompt: "hi"}))
        |> send_ev(ev(2, :item_started, %{item_id: "i1", item_type: :message}))
        |> send_ev(
          ev(3, :item_completed, %{
            item_id: "i1",
            item_type: :message,
            content: "restored answer"
          })
        )
        |> send_ev(ev(4, :turn_completed, %{final: true, usage: %{}}))

      key = model.session_key

      # A fresh app resumes that session id.
      resumed =
        App.init(%{
          options: [runner: stub_runner(), sessions_dir: dir, session_key: key]
        })

      assert resumed.events != []
      blocks = Raxol.Harness.Projection.project(resumed.events).blocks

      assert Enum.any?(
               blocks,
               &(Raxol.UI.Components.Harness.Block.search_text(&1) =~
                   "restored answer")
             )

      # And the resumed model renders.
      assert %{} = App.view(resumed)
    end
  end

  describe "event id stamping" do
    # Contract.pump stamps ids from a fresh per-turn counter, so a second
    # turn's ids collide with the first's; the projection's id recovery
    # drops colliding events, losing every turn after the first from the
    # transcript. The fold re-stamps into one session-monotonic space.
    test "a second turn with restarted producer ids stays in the transcript" do
      model = new_model()

      model =
        Enum.reduce(
          message_turn("t1", "first answer") ++
            message_turn("t2", "second answer"),
          model,
          &send_ev(&2, &1)
        )

      assert Enum.map(model.events, & &1.id) == Enum.to_list(1..8)

      projection = Raxol.Harness.Projection.project(model.events)
      assert projection.diagnostics == []

      texts =
        Enum.map(
          projection.blocks,
          &Raxol.UI.Components.Harness.Block.search_text/1
        )

      assert Enum.any?(texts, &(&1 =~ "first answer"))
      assert Enum.any?(texts, &(&1 =~ "second answer"))
    end

    test "resumed events renumber into the dense session space" do
      dir = tmp_dir()

      # A stored log with colliding per-turn producer ids, as sessions
      # persisted before the fold re-stamped ids.
      stored =
        [
          {"t1", 1, "turn_started", %{"prompt" => "one"}},
          {"t1", 2, "item_started",
           %{"item_id" => "i1", "item_type" => "message"}},
          {"t1", 3, "item_completed",
           %{"item_id" => "i1", "item_type" => "message", "content" => "a"}},
          {"t1", 4, "turn_completed", %{"final" => true}},
          {"t2", 1, "turn_started", %{"prompt" => "two"}},
          {"t2", 2, "item_started",
           %{"item_id" => "i1", "item_type" => "message"}},
          {"t2", 3, "item_completed",
           %{"item_id" => "i1", "item_type" => "message", "content" => "b"}},
          {"t2", 4, "turn_completed", %{"final" => true}}
        ]
        |> Enum.map(fn {turn, id, type, payload} ->
          %{
            "id" => id,
            "turn_id" => turn,
            "ts" => id,
            "family" => "loop",
            "type" => type,
            "tier" => "durable",
            "payload" => payload
          }
        end)

      :ok =
        Raxol.Agent.Code.Store.save(dir, "sess-renum", %{
          messages: [],
          events: stored
        })

      model = new_model(sessions_dir: dir, session_key: "sess-renum")

      assert Enum.map(model.events, & &1.id) == Enum.to_list(1..8)
      assert model.next_event_id == 9

      projection = Raxol.Harness.Projection.project(model.events)
      assert projection.diagnostics == []
      refute projection.damaged
    end

    test "/clear resets the id counter with the session" do
      model =
        Enum.reduce(
          message_turn("t1", "answer"),
          new_model(),
          &send_ev(&2, &1)
        )

      assert model.next_event_id == 5

      {cleared, []} = submit(model, "/clear")
      assert cleared.next_event_id == 1
      assert cleared.events == []
    end
  end

  describe "durable journal" do
    alias Raxol.Agent.Journal.FileStore

    defp journal_model(extra \\ []) do
      base = tmp_dir()
      {new_model([journal_opts: [base_dir: base]] ++ extra), base}
    end

    defp journal_records(model, base) do
      close_journal!(model)
      {:ok, records} = FileStore.read_records(model.session_key, base_dir: base)
      records
    end

    defp close_journal!(%{journal: nil}), do: :ok
    defp close_journal!(%{journal: journal}), do: FileStore.close(journal)

    test "durable events land in the journal as they fold" do
      {model, base} = journal_model()

      model =
        Enum.reduce(message_turn("t1", "answer"), model, &send_ev(&2, &1))

      records = journal_records(model, base)

      assert Enum.map(records, & &1["id"]) == [1, 2, 3, 4]

      assert Enum.map(records, & &1["type"]) == [
               "turn_started",
               "item_started",
               "item_completed",
               "turn_completed"
             ]

      assert Enum.all?(records, &(&1["session_id"] == model.session_key))
    end

    test "ephemeral events are never journaled" do
      {model, base} = journal_model()

      model =
        model
        |> send_ev(tev("t1", 1, :turn_started, %{prompt: "hi"}))
        |> send_ev(
          tev(
            "t1",
            2,
            :item_delta,
            %{item_id: "i1", chunk: "partial"},
            :ephemeral
          )
        )
        |> send_ev(tev("t1", 3, :turn_completed, %{final: true, usage: %{}}))

      records = journal_records(model, base)

      assert Enum.map(records, & &1["type"]) == [
               "turn_started",
               "turn_completed"
             ]
    end

    test "the journal spans turns with session-monotonic offsets" do
      {model, base} = journal_model()

      model =
        Enum.reduce(
          message_turn("t1", "one") ++ message_turn("t2", "two"),
          model,
          &send_ev(&2, &1)
        )

      records = journal_records(model, base)
      assert Enum.map(records, & &1["id"]) == Enum.to_list(1..8)
    end

    test "/clear closes the journal and the next turn opens a fresh one" do
      {model, base} = journal_model()

      model =
        Enum.reduce(message_turn("t1", "one"), model, &send_ev(&2, &1))

      old_key = model.session_key
      old_writer = model.journal.writer

      {cleared, []} = submit(model, "/clear")
      assert cleared.journal == nil
      refute Process.alive?(old_writer)

      cleared =
        Enum.reduce(message_turn("t1", "two"), cleared, &send_ev(&2, &1))

      refute cleared.session_key == old_key
      records = journal_records(cleared, base)
      assert Enum.map(records, & &1["id"]) == [1, 2, 3, 4]
    end

    test "a failing journal degrades to a status warning, never blocks the fold" do
      base = tmp_dir()
      # The base dir path is occupied by a regular file, so the session
      # layout cannot be created and every open fails.
      File.mkdir_p!(Path.dirname(base))
      File.write!(base, "not a dir")

      model = new_model(journal_opts: [base_dir: base])

      model =
        Enum.reduce(message_turn("t1", "answer"), model, &send_ev(&2, &1))

      assert model.journal == nil
      assert length(model.events) == 4
      assert model.status_line =~ "journal unavailable"
    end

    test "ctrl+c closes the journal" do
      {model, _base} = journal_model()

      model =
        Enum.reduce(message_turn("t1", "one"), model, &send_ev(&2, &1))

      writer = model.journal.writer
      {_model, commands} = App.update(key("c", [:ctrl]), model)
      assert commands != []
      refute Process.alive?(writer)
    end
  end

  describe "/resume" do
    test "/resume <id> switches sessions in place, persisting the departing one" do
      dir = tmp_dir()

      first = new_model(sessions_dir: dir)
      {first, []} = submit(first, "ask one")

      first =
        Enum.reduce(message_turn("t1", "first answer"), first, &send_ev(&2, &1))

      first_key = first.session_key

      # A second session in the same store.
      second = new_model(sessions_dir: dir)
      {second, []} = submit(second, "ask two")

      second =
        Enum.reduce(
          message_turn("t2", "second answer"),
          second,
          &send_ev(&2, &1)
        )

      {switched, []} = submit(second, "/resume #{first_key}")

      assert switched.session_key == first_key
      assert switched.notice =~ "resumed #{first_key}"

      assert Enum.map(switched.messages, & &1.content) == [
               "ask one",
               "first answer"
             ]

      # The departing session was persisted before switching.
      {:ok, saved} =
        Raxol.Agent.Code.Store.load(dir, second.session_key)

      assert Enum.map(saved.messages, & &1.content) == [
               "ask two",
               "second answer"
             ]
    end

    test "/resume with an unknown id notices without switching" do
      model = new_model()
      {after_cmd, []} = submit(model, "/resume sess-does-not-exist")
      assert after_cmd.session_key == model.session_key
      assert after_cmd.notice =~ "not found"
    end

    test "/resume with no arg opens a picker; Enter resumes the selection" do
      dir = tmp_dir()

      other = new_model(sessions_dir: dir)
      {other, []} = submit(other, "ask other")

      other =
        Enum.reduce(message_turn("t1", "other answer"), other, &send_ev(&2, &1))

      test_pid = self()

      model =
        new_model(
          sessions_dir: dir,
          sessions_fetcher: fn dir, ref, _app ->
            send(test_pid, {:listed, dir, ref})
          end
        )

      {model, []} = submit(model, "/resume")
      assert model.sessions_ref != nil
      assert_received {:listed, ^dir, ref}
      assert ref == model.sessions_ref

      {model, []} =
        App.update(
          {:command_result,
           {:sessions_list, ref, Raxol.Agent.Code.Store.list(dir)}},
          model
        )

      assert model.wizard.step == :sessions
      assert model.sessions_ref == nil

      {model, []} = App.update(key(:enter), model)

      assert model.session_key == other.session_key
      assert model.wizard == nil

      assert Enum.map(model.messages, & &1.content) == [
               "ask other",
               "other answer"
             ]
    end

    test "an empty store notices instead of opening the picker" do
      model = new_model()
      {model, []} = submit(model, "/resume")

      {model, []} =
        App.update(
          {:command_result, {:sessions_list, model.sessions_ref, []}},
          model
        )

      assert model.wizard == nil
      assert model.notice =~ "no saved sessions"
    end
  end

  describe "/fork" do
    test "forks to a fresh key that records its parent, keeping both files" do
      dir = tmp_dir()
      model = new_model(sessions_dir: dir)
      {model, []} = submit(model, "ask")

      model =
        Enum.reduce(message_turn("t1", "the answer"), model, &send_ev(&2, &1))

      parent_key = model.session_key
      {forked, []} = submit(model, "/fork side quest")

      assert forked.session_key != parent_key
      assert forked.parent == parent_key
      assert forked.title == "side quest"
      assert forked.notice =~ "forked to #{forked.session_key}"

      # Both files exist; the fork carries the full conversation + parent.
      {:ok, original} = Raxol.Agent.Code.Store.load(dir, parent_key)
      {:ok, fork} = Raxol.Agent.Code.Store.load(dir, forked.session_key)

      assert original.parent == nil
      assert fork.parent == parent_key
      assert fork.messages == original.messages
      assert length(fork.events) == 4
    end

    test "an empty session has nothing to fork" do
      {model, []} = submit(new_model(), "/fork")
      assert model.notice =~ "nothing to fork"
    end
  end

  describe "/export /transcript /copy /find /logout" do
    defp answered_model(opts \\ []) do
      model = new_model(opts)
      {model, []} = submit(model, "ask")

      Enum.reduce(
        message_turn("t1", "the special answer"),
        model,
        &send_ev(&2, &1)
      )
    end

    test "/export writes the transcript beside the work" do
      cwd = tmp_dir()
      File.mkdir_p!(cwd)
      model = answered_model(cwd: cwd)

      {model, []} = submit(model, "/export")

      assert model.notice =~ "exported to"
      path = Path.join(cwd, "#{model.session_key}.txt")
      assert File.exists?(path)
      content = File.read!(path)
      assert content =~ "> ask"
      assert content =~ "the special answer"
    end

    test "/export honors a given path relative to the cwd" do
      cwd = tmp_dir()
      File.mkdir_p!(cwd)
      model = answered_model(cwd: cwd)

      {_model, []} = submit(model, "/export session.log")
      assert File.read!(Path.join(cwd, "session.log")) =~ "the special answer"
    end

    test "/transcript writes a temp file and hints at a pager" do
      model = answered_model()
      {model, []} = submit(model, "/transcript")

      assert model.notice =~ "PAGER"

      path =
        Path.join(System.tmp_dir!(), "#{model.session_key}-transcript.txt")

      assert File.read!(path) =~ "the special answer"
    end

    test "/copy pushes the last reply through the clipboard seam" do
      test_pid = self()

      model =
        answered_model(
          clipboard: fn text ->
            send(test_pid, {:copied, text})
            :ok
          end
        )

      {model, []} = submit(model, "/copy")

      assert model.notice =~ "copied last reply"
      assert_received {:copied, "the special answer"}
    end

    test "/copy with no assistant reply notices" do
      {model, []} = submit(new_model(), "/copy")
      assert model.notice =~ "no assistant reply"
    end

    test "/find reports matching blocks and misses honestly" do
      model = answered_model()

      {model, []} = submit(model, "/find special")
      assert model.notice =~ "1 match(es) for \"special\""
      assert model.notice =~ "[message]"

      {model, []} = submit(model, "/find zzz-not-there")
      assert model.notice =~ "no matches"

      {model, []} = submit(model, "/find")
      assert model.notice =~ "usage: /find"
    end

    test "/logout disconnects the provider and reopens the setup panel" do
      model = connected_model()
      {model, []} = submit(model, "/logout")

      assert model.executor == nil
      assert model.provider_status == :no_provider
      assert model.wizard.step == :browse
      assert model.notice =~ "logged out"
    end

    test "/logout <provider> removes the credential through the seam" do
      test_pid = self()

      model =
        connected_model(
          credential_remover: fn provider ->
            send(test_pid, {:removed, provider})
            {:ok, :openai}
          end
        )

      {model, []} = submit(model, "/logout openai")

      assert_received {:removed, "openai"}
      assert model.notice =~ "removed stored credential for openai"
      # The removed provider was the connected one — disconnected too.
      assert model.executor == nil
    end
  end

  describe "/rename and enriched /sessions" do
    test "/rename titles the session and persists it" do
      model = new_model()
      {model, []} = submit(model, "/rename fix the auth bug")

      assert model.title == "fix the auth bug"
      assert model.notice =~ "renamed"

      {:ok, saved} =
        Raxol.Agent.Code.Store.load(model.sessions_dir, model.session_key)

      assert saved.title == "fix the auth bug"
    end

    test "/rename without a title shows usage" do
      {model, []} = submit(new_model(), "/rename")
      assert model.notice =~ "usage: /rename"
    end

    test "a resumed session keeps its title" do
      dir = tmp_dir()
      model = new_model(sessions_dir: dir)
      {model, []} = submit(model, "/rename keep me")

      resumed =
        new_model(sessions_dir: dir, session_key: model.session_key)

      assert resumed.title == "keep me"
    end

    test "/sessions lists title, age, and cwd" do
      dir = tmp_dir()
      model = new_model(sessions_dir: dir)
      {model, []} = submit(model, "/rename my title")
      {model, []} = submit(model, "/sessions")

      assert model.notice =~ ~s("my title")
      assert model.notice =~ "msgs"
      assert model.notice =~ "just now"
    end
  end

  describe "/rewind" do
    defp run_turn(model, turn_id, prompt, answer) do
      {model, []} = submit(model, prompt)
      Enum.reduce(message_turn(turn_id, answer), model, &send_ev(&2, &1))
    end

    test "drops the last turn from transcript, conversation, store, and marks the journal" do
      base = tmp_dir()
      model = new_model(journal_opts: [base_dir: base])

      model =
        model
        |> run_turn("t1", "ask one", "first answer")
        |> run_turn("t2", "ask two", "second answer")

      assert length(model.messages) == 4

      {model, []} = submit(model, "/rewind")

      assert model.notice =~ "rewound"
      assert Enum.map(model.events, & &1.turn_id) |> Enum.uniq() == ["t1"]

      assert model.messages == [
               %{role: :user, content: "ask one"},
               %{role: :assistant, content: "first answer"}
             ]

      # The store persisted the truncated state.
      {:ok, saved} =
        Raxol.Agent.Code.Store.load(model.sessions_dir, model.session_key)

      assert length(saved.events) == 4

      # The append-only journal keeps the turn plus a rewind marker.
      close_journal!(model)

      {:ok, records} =
        Raxol.Agent.Journal.FileStore.read_records(
          model.session_key,
          base_dir: base
        )

      assert List.last(records)["type"] == "rewind"

      assert get_in(List.last(records), ["payload", "dropped_turn"]) ==
               "t2"
    end

    test "with no turns there is nothing to rewind" do
      {model, []} = submit(new_model(), "/rewind")
      assert model.notice =~ "nothing to rewind"
    end

    test "refuses while a turn is running" do
      model = %{new_model() | running?: false}
      {model, []} = submit(model, "ask")
      assert model.running?

      # Slash input is swallowed mid-turn, so call the command through the
      # dispatch used when the turn has just ended but running? was stale.
      {rewound, []} =
        App.update(
          key(:enter),
          %{model | running?: true, input: "/rewind"}
        )

      # Mid-turn enter is swallowed entirely (input preserved).
      assert rewound.input == "/rewind"
    end
  end

  describe "slash commands" do
    test "/help shows a notice and does not start a turn" do
      {model, []} = submit(new_model(), "/help")
      assert model.notice =~ "/clear"
      assert model.running? == false
    end

    test "/model sets the override" do
      {model, []} = submit(new_model(), "/model gpt-4o")
      assert model.model_override == "gpt-4o"
      assert model.notice =~ "gpt-4o"
    end

    test "/plan toggles plan mode" do
      {model, []} = submit(new_model(), "/plan")
      assert model.plan_mode == true
    end

    test "/clear starts a fresh session" do
      model = %{new_model() | messages: [%{role: :user, content: "x"}]}
      previous_key = model.session_key
      {model, []} = submit(model, "/clear")
      assert model.messages == []
      assert model.session_key != previous_key
    end

    test "/context reports stats" do
      {model, []} = submit(new_model(), "/context")
      assert model.notice =~ "messages: 0"
    end

    test "an unknown command reports itself" do
      {model, []} = submit(new_model(), "/frobnicate")
      assert model.notice =~ "unknown command"
    end

    test "/inspect fetches the snapshot off the app process" do
      test_pid = self()

      model =
        new_model(
          inspection_fetcher: fn cwd, dir, ref, app ->
            send(test_pid, {:inspect_spawned, cwd, dir, ref, app})
          end
        )

      {model, []} = submit(model, "/inspect")

      assert_received {:inspect_spawned, cwd, dir, ref, app}
      assert cwd == model.cwd
      assert dir == model.sessions_dir
      assert model.inspection_ref == ref
      assert app == self()

      {model, []} =
        App.update(
          {:command_result, {:inspection_result, ref, "SNAPSHOT"}},
          model
        )

      assert model.notice == "SNAPSHOT"
      assert model.inspection_ref == nil
    end

    test "a stale /inspect result is ignored" do
      model = %{new_model() | inspection_ref: make_ref()}

      {model2, []} =
        App.update(
          {:command_result, {:inspection_result, make_ref(), "STALE"}},
          model
        )

      assert model2.notice != "STALE"
    end

    test "the default /inspect fetcher delivers the full snapshot" do
      ref = make_ref()
      model = new_model()

      App.default_inspection_fetcher(model.cwd, model.sessions_dir, ref, self())

      assert_receive {:command_result, {:inspection_result, ^ref, text}}, 10_000
      assert text =~ "inspecting: #{model.cwd}"
      assert text =~ "providers (op CLI:"
      assert text =~ "sessions: #{model.sessions_dir}"
    end

    test "/usage folds token totals across provider vocabularies" do
      model =
        new_model()
        |> send_ev(
          ev(1, :turn_completed, %{
            final: true,
            usage: %{"input_tokens" => 100, "output_tokens" => 20}
          })
        )
        |> send_ev(
          ev(2, :turn_completed, %{
            final: true,
            usage: %{prompt_tokens: 50, completion_tokens: 5}
          })
        )

      {model, []} = submit(model, "/usage")
      assert model.notice =~ "turns: 2"
      assert model.notice =~ "input tokens: 150"
      assert model.notice =~ "output tokens: 25"
      assert model.notice =~ "RAXOL_COST_PER_MTOK_IN"
    end

    test "/usage shows an estimated cost when rates are configured" do
      System.put_env("RAXOL_COST_PER_MTOK_IN", "1.0")
      System.put_env("RAXOL_COST_PER_MTOK_OUT", "2.0")

      on_exit(fn ->
        System.delete_env("RAXOL_COST_PER_MTOK_IN")
        System.delete_env("RAXOL_COST_PER_MTOK_OUT")
      end)

      model =
        send_ev(
          new_model(),
          ev(1, :turn_completed, %{
            final: true,
            usage: %{input_tokens: 1_000_000, output_tokens: 500_000}
          })
        )

      {model, []} = submit(model, "/usage")
      assert model.notice =~ "est. cost: $2.0000"
    end

    test "mcp servers bridge into the toolset asynchronously" do
      dir =
        config_cwd(%{
          ".mcp.json" =>
            Jason.encode!(%{
              "mcpServers" => %{"fs" => %{"command" => "npx", "args" => []}}
            })
        })

      test_pid = self()

      model =
        new_model(
          cwd: dir,
          mcp_loader: fn servers, ref, app ->
            send(test_pid, {:mcp_spawned, servers, ref, app})
          end
        )

      # Armed at init, fired on the first update (the dispatcher process).
      {model, []} = App.update(key("x"), model)

      assert_received {:mcp_spawned, servers, ref, app}
      assert [%{name: "fs"}] = servers
      assert app == self()
      assert model.mcp_status == :loading

      tool = %Raxol.Agent.Action.Dynamic{
        name: "mcp__fs__read",
        invoke: fn _params, _context -> {:ok, %{}} end,
        sensitive: false
      }

      result = %{tools: [tool], connected: [:fs], failed: [], janitor: nil}

      {model, []} =
        App.update({:command_result, {:mcp_loaded, ref, result}}, model)

      assert tool in model.actions
      assert model.mcp_status.connected == [:fs]
      assert model.status_line =~ "mcp: 1 tools from 1 servers"

      {model, []} = submit(model, "/mcp")
      assert model.notice =~ "● fs"
    end

    test "a failed mcp server shows in the status line and /mcp" do
      dir =
        config_cwd(%{
          ".mcp.json" =>
            Jason.encode!(%{
              "mcpServers" => %{"ghost" => %{"command" => "nope"}}
            })
        })

      model =
        new_model(cwd: dir, mcp_loader: fn _servers, _ref, _app -> :ok end)

      {model, []} = App.update(key("x"), model)
      ref = model.mcp_ref

      result = %{
        tools: [],
        connected: [],
        failed: [{:ghost, :enoent}],
        janitor: nil
      }

      {model, []} =
        App.update({:command_result, {:mcp_loaded, ref, result}}, model)

      assert model.status_line =~ "failed: ghost"
      {model, []} = submit(model, "/mcp")
      assert model.notice =~ "✗ ghost"
    end

    test "the tool authorizer gates a sensitive Dynamic MCP tool" do
      auth = App.tool_authorizer(self())

      tool = %Raxol.Agent.Action.Dynamic{
        name: "mcp__fs__write",
        invoke: fn _params, _context -> :ok end,
        sensitive: true
      }

      task = Task.async(fn -> auth.(tool, %{}, %{}) end)

      assert_receive {:command_result,
                      {:authorize_request, ref, from, "mcp__fs__write"}}

      send(from, {:authorize_decision, ref, {:deny, :test_denied}})
      assert Task.await(task) == {:deny, :test_denied}
    end

    test "a read-only Dynamic tool runs without an approval round-trip" do
      auth = App.tool_authorizer(self())

      tool = %Raxol.Agent.Action.Dynamic{
        name: "mcp__fs__read",
        invoke: fn _params, _context -> :ok end,
        sensitive: false
      }

      assert auth.(tool, %{}, %{}) == :ok
      refute_received {:command_result, _}
    end

    test "/context includes token totals" do
      model =
        send_ev(
          new_model(),
          ev(1, :turn_completed, %{
            final: true,
            usage: %{input_tokens: 10, output_tokens: 3}
          })
        )

      {model, []} = submit(model, "/context")
      assert model.notice =~ "tokens: 10 in / 3 out"
    end
  end

  describe "delegation + config (Phase 5)" do
    test "init loads .raxol/hooks.json and .mcp.json from cwd" do
      dir =
        config_cwd(%{
          ".raxol/hooks.json" => Jason.encode!(%{"stop" => ["true"]}),
          ".mcp.json" =>
            Jason.encode!(%{
              "mcpServers" => %{"fs" => %{"command" => "npx", "args" => []}}
            })
        })

      model =
        App.init(%{
          options: [runner: stub_runner(), sessions_dir: tmp_dir(), cwd: dir]
        })

      assert model.hooks.stop == ["true"]
      assert [%{name: "fs"}] = model.mcp_servers
      assert model.status_line =~ "hooks"
      assert model.status_line =~ "MCP"
    end

    test "a turn's run context carries the toolset, sub-agent config, and hooks" do
      parent = self()

      runner = fn _sid, _prompt, opts, _app ->
        send(parent, {:opts, opts})
        spawn(fn -> Process.sleep(60_000) end)
      end

      dir =
        config_cwd(%{
          ".raxol/hooks.json" =>
            Jason.encode!(%{
              "pre_tool_use" => [%{"match" => "*", "command" => "true"}]
            })
        })

      model =
        App.init(%{
          options: [runner: runner, sessions_dir: tmp_dir(), cwd: dir]
        })

      {_model, []} = App.update(key(:enter), %{model | input: "go"})

      assert_receive {:opts, opts}
      context = Keyword.fetch!(opts, :context)
      assert Map.has_key?(context, :subagent)
      assert context.tool_call_hooks == [Raxol.Agent.Code.Hooks]

      names =
        Enum.map(Keyword.fetch!(opts, :actions), & &1.__action_meta__().name)

      assert "task" in names
    end

    test "/hooks and /mcp report the loaded configuration" do
      dir =
        config_cwd(%{
          ".raxol/hooks.json" => Jason.encode!(%{"stop" => ["true"]}),
          ".mcp.json" =>
            Jason.encode!(%{
              "mcpServers" => %{"fs" => %{"command" => "npx", "args" => []}}
            })
        })

      model =
        App.init(%{
          options: [runner: stub_runner(), sessions_dir: tmp_dir(), cwd: dir]
        })

      {model, []} = submit(model, "/hooks")
      assert model.notice =~ "stop: 1"

      {model, []} = submit(model, "/mcp")
      assert model.notice =~ "fs"
    end
  end
end
