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

  defp tmp_dir do
    Path.join(
      System.tmp_dir!(),
      "raxol-code-app-#{System.unique_integer([:positive])}"
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
    fetcher =
      Keyword.get(opts, :models_fetcher, fn _opts, _ref, _app -> :ok end)

    new_model(
      executor: ExecutorConfig.new(backend: :openai, model: "gpt-4o"),
      provider_status: {:ready, :openai, :env},
      # A connected provider has a current model (set on connect from the
      # executor); reflected here so the picker cursor has something to land on.
      model: "gpt-4o",
      models_fetcher: fetcher
    )
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
          {:command_result, {:models_list, ref, {:ok, ["gpt-4o-mini", "gpt-4o"]}}},
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
          {:command_result, {:models_list, model.models_ref, {:ok, ["a", "b", "c"]}}},
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
        connected_model(models_fetcher: fn _o, _r, _a -> send(test_pid, :fetched) end)

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
        App.update({:command_result, {:inspection_result, ref, "SNAPSHOT"}}, model)

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

      result = %{tools: [tool], servers: [{:fs, self()}], failed: []}

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

      result = %{tools: [], servers: [], failed: [{:ghost, :enoent}]}

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

      assert_receive {:command_result, {:authorize_request, ref, from, "mcp__fs__write"}}
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
