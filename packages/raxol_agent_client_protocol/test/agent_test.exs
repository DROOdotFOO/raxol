# Tests for Raxol.AgentClientProtocol.Agent -- the ergonomic `use`-based
# behaviour + library-mode start helpers for the agent side of ACP. Not a
# port of any upstream f1729 test file (f1729 has no equivalent ergonomic
# layer). Two tiers:
#
#   1. Pure unit tests of the generated callback surface (naming, arity,
#      defaults, overridability) and of `child_spec/1`'s shape -- these
#      never touch `Connection`/`Session` and always run.
#   2. One end-to-end smoke test wiring a minimal agent + client pair over
#      `Transport.Paired` and driving a real `initialize` -> `session/new`
#      -> `session/prompt` (2 streamed updates + response) turn through
#      `Connection`. `Connection`/`Session` are sibling-wave modules that
#      may not have landed in this worktree yet; the `describe` block below
#      skips (not fails) at runtime via `Code.ensure_loaded?/1` when they
#      are absent, so the rest of the suite stays green either way.
defmodule Raxol.AgentClientProtocol.AgentTest do
  use ExUnit.Case, async: true

  alias Raxol.AgentClientProtocol.Agent
  alias Raxol.AgentClientProtocol.Error
  alias Raxol.AgentClientProtocol.Handler.Codegen
  alias Raxol.AgentClientProtocol.MethodTable
  alias Raxol.AgentClientProtocol.Transport

  # -- fixtures -----------------------------------------------------------

  defmodule BareAgent do
    @moduledoc false
    use Agent
  end

  defmodule OverridingAgent do
    @moduledoc false
    use Agent

    alias Raxol.AgentClientProtocol.Schema.AgentTypes.InitializeResponse

    @impl true
    def init(arg), do: {:ok, {:custom_init, arg}}

    @impl true
    def initialize(_req, _ctx), do: {:ok, InitializeResponse.new(1)}

    @impl true
    def logout(_ctx), do: {:ok, :overridden_logout}

    @impl true
    def handle_ext_request(_wire, _params, _ctx), do: {:ok, %{"echo" => true}}
  end

  # -- callback surface: naming/arity mirrors MethodTable exactly ---------

  describe "generated callback surface" do
    test "callbacks/0 matches MethodTable.rows_for_side(:agent) exactly" do
      expected =
        for row <- MethodTable.rows_for_side(:agent), row.callback != nil do
          {row.callback, if(row.params == nil, do: 1, else: 2), row.wire}
        end

      assert Agent.callbacks() == expected
      # 13 core agent rows minus session/cancel (layer: :session_control, no
      # callback) = 12, plus the additive `_raxol/session.load` ext row = 13.
      assert length(Agent.callbacks()) == 13
    end

    test "logout is the sole arity-1 (params: nil, D1-6) callback" do
      assert {:logout, 1, "logout"} in Agent.callbacks()
      assert Enum.count(Agent.callbacks(), fn {_cb, arity, _wire} -> arity == 1 end) == 1
    end

    test "behaviour_info/1 declares every table callback plus init/1, handle_ext_request/3, handle_ext_notification/3" do
      declared = Agent.behaviour_info(:callbacks) |> MapSet.new()

      table_callbacks =
        for {cb, arity, _wire} <- Agent.callbacks(), into: MapSet.new(), do: {cb, arity}

      assert MapSet.subset?(table_callbacks, declared)
      assert MapSet.member?(declared, {:init, 1})
      assert MapSet.member?(declared, {:handle_ext_request, 3})
      assert MapSet.member?(declared, {:handle_ext_notification, 3})
    end
  end

  # -- defaults: every unoverridden callback is a safe, wire-correct no-op --

  describe "default implementations (BareAgent, nothing overridden)" do
    test "init/1 default is the identity {:ok, handler_arg}" do
      assert BareAgent.init(:some_arg) == {:ok, :some_arg}
    end

    test "every request-kind callback defaults to {:error, method_not_found}" do
      for row <- Codegen.rows(:agent), row.kind == :request do
        args = if row.params == nil, do: [:fake_ctx], else: [nil, :fake_ctx]

        assert apply(BareAgent, row.callback, args) ==
                 {:error, Error.method_not_found()},
               "expected #{row.callback}/#{length(args)} to default to method_not_found"
      end
    end

    test "the sole notification-kind callback (session/cancel excluded) has no bare-Agent equivalent" do
      # All 12 agent-side app-layer rows are requests; there is currently no
      # notification-kind row on the agent side to exercise the :notification
      # default clause here -- covered on the Client side instead, where
      # session/update (a notification) is a real row. Assert that
      # assumption stays true so this comment does not silently rot.
      assert Enum.all?(Codegen.rows(:agent), &(&1.kind == :request))
    end

    test "handle_ext_request/3 defaults to method_not_found" do
      assert BareAgent.handle_ext_request("_vendor/thing", %{}, :fake_ctx) ==
               {:error, Error.method_not_found()}
    end

    test "handle_ext_notification/3 defaults to :ok" do
      assert BareAgent.handle_ext_notification("_vendor/thing", %{}, :fake_ctx) == :ok
    end
  end

  # -- overridability -------------------------------------------------------

  describe "overriding generated defaults" do
    test "an overridden callback wins over the generated default" do
      assert OverridingAgent.init(%{x: 1}) == {:ok, {:custom_init, %{x: 1}}}
      assert {:ok, %{}} = elem(OverridingAgent.initialize(nil, :fake_ctx), 1) |> then(&{:ok, &1})
      assert OverridingAgent.logout(:fake_ctx) == {:ok, :overridden_logout}
      assert OverridingAgent.handle_ext_request("_x", %{}, :fake_ctx) == {:ok, %{"echo" => true}}
    end

    test "un-overridden callbacks on OverridingAgent still fall back to the default" do
      assert OverridingAgent.authenticate(nil, :fake_ctx) == {:error, Error.method_not_found()}
    end
  end

  # -- child_spec/1 / start_link/2 shape (no Connection required) -----------

  defmodule DummyHandler do
    @moduledoc false
    use Agent
  end

  describe "child_spec/1" do
    test "builds the ConnectionSupervisor start MFA with defaults" do
      spec = Agent.child_spec(handler: DummyHandler, transport: {Transport.Paired, :fake_handle})

      assert %{id: Agent, type: :supervisor} = spec

      assert {Agent.ConnectionSupervisor, :start_link,
              [{DummyHandler, nil, {Transport.Paired, :fake_handle}}, []]} = spec.start
    end

    test "threads :handler_arg, :name, :id through" do
      spec =
        Agent.child_spec(
          handler: DummyHandler,
          transport: {Transport.Paired, :fake_handle},
          handler_arg: %{seed: 1},
          name: :my_agent_sup,
          id: :agent_one
        )

      assert spec.id == :agent_one

      assert {Agent.ConnectionSupervisor, :start_link,
              [
                {DummyHandler, %{seed: 1}, {Transport.Paired, :fake_handle}},
                [name: :my_agent_sup]
              ]} = spec.start
    end

    test "requires :handler and :transport" do
      assert_raise KeyError, fn -> Agent.child_spec(transport: {Transport.Paired, :h}) end
      assert_raise KeyError, fn -> Agent.child_spec(handler: DummyHandler) end
    end
  end

  describe "start_link/2" do
    test "requires :transport" do
      assert_raise KeyError, fn -> Agent.start_link(DummyHandler, []) end
    end
  end

  # -- end-to-end smoke: initialize -> session/new -> prompt (2 updates) ----

  defmodule E2EAgent do
    @moduledoc false
    use Agent

    alias Raxol.AgentClientProtocol.Connection

    alias Raxol.AgentClientProtocol.Schema.AgentTypes.{
      InitializeResponse,
      NewSessionResponse,
      PromptResponse
    }

    alias Raxol.AgentClientProtocol.Schema.ContentBlock
    alias Raxol.AgentClientProtocol.Schema.ContentChunk
    alias Raxol.AgentClientProtocol.Schema.LifecycleExtras.SessionNotification

    @impl true
    def initialize(_req, _ctx), do: {:ok, InitializeResponse.new(1)}

    @impl true
    def new_session(_req, _ctx), do: {:ok, NewSessionResponse.new("sess-1")}

    @impl true
    def prompt(req, ctx) do
      for text <- ["chunk 1", "chunk 2"] do
        update =
          SessionNotification.new(
            req.session_id,
            {:agent_message_chunk, ContentChunk.new(ContentBlock.from_string(text))}
          )

        :ok = Connection.notify(ctx.conn, "session/update", update)
      end

      {:ok, PromptResponse.new(:end_turn)}
    end
  end

  defmodule E2EClient do
    @moduledoc false
    use Raxol.AgentClientProtocol.Client

    @impl true
    def session_update(notification, ctx) do
      send(ctx.handler_state, {:session_update, notification})
      :ok
    end
  end

  describe "end-to-end smoke over Transport.Paired" do
    setup do
      if Code.ensure_loaded?(Raxol.AgentClientProtocol.Connection) do
        :ok
      else
        {:skip, "Raxol.AgentClientProtocol.Connection has not landed in this worktree yet"}
      end
    end

    test "initialize -> session/new -> session/prompt streams 2 updates then a response" do
      alias Raxol.AgentClientProtocol.Connection

      alias Raxol.AgentClientProtocol.Schema.AgentTypes.{
        InitializeRequest,
        NewSessionRequest,
        PromptRequest
      }

      alias Raxol.AgentClientProtocol.Schema.ContentBlock

      {agent_handle, client_handle} = Transport.Paired.create_pair()

      {:ok, agent_sup} =
        Agent.start_link(E2EAgent, transport: {Transport.Paired, agent_handle})

      {:ok, client_sup} =
        Raxol.AgentClientProtocol.Client.start_link(E2EClient,
          transport: {Transport.Paired, client_handle},
          handler_arg: self()
        )

      on_exit(fn ->
        catch_exit(Supervisor.stop(agent_sup, :normal, 500))
        catch_exit(Supervisor.stop(client_sup, :normal, 500))
      end)

      client_conn = connection_pid(client_sup)

      assert {:ok, _init_resp} =
               Connection.request(client_conn, "initialize", InitializeRequest.new(1), 5_000)

      assert {:ok, %{session_id: session_id}} =
               Connection.request(
                 client_conn,
                 "session/new",
                 NewSessionRequest.new("/tmp"),
                 5_000
               )

      assert {:ok, prompt_resp} =
               Connection.request(
                 client_conn,
                 "session/prompt",
                 PromptRequest.new(session_id, [ContentBlock.from_string("hi")]),
                 5_000
               )

      assert prompt_resp.stop_reason == :end_turn

      assert_receive {:session_update, %{update: {:agent_message_chunk, chunk1}}}
      assert_receive {:session_update, %{update: {:agent_message_chunk, chunk2}}}

      texts =
        [chunk1, chunk2]
        |> Enum.map(fn %{content: {:text, %{text: text}}} -> text end)
        |> Enum.sort()

      assert texts == ["chunk 1", "chunk 2"]
    end

    defp connection_pid(sup) do
      sup
      |> Supervisor.which_children()
      |> Enum.find_value(fn
        {Raxol.AgentClientProtocol.Connection, pid, _type, _mods} -> pid
        _other -> nil
      end)
    end
  end
end
