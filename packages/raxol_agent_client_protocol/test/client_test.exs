# Tests for Raxol.AgentClientProtocol.Client -- the ergonomic `use`-based
# behaviour + library-mode start helpers for the client side of ACP. Mirrors
# `agent_test.exs`'s structure and rationale (see its header comment); not a
# port of any upstream f1729 test file.
defmodule Raxol.AgentClientProtocol.ClientTest do
  use ExUnit.Case, async: true

  alias Raxol.AgentClientProtocol.Client
  alias Raxol.AgentClientProtocol.Connection.Ctx
  alias Raxol.AgentClientProtocol.Error
  alias Raxol.AgentClientProtocol.Handler.Codegen
  alias Raxol.AgentClientProtocol.MethodTable
  alias Raxol.AgentClientProtocol.Test.Teardown
  alias Raxol.AgentClientProtocol.Transport

  # -- fixtures -----------------------------------------------------------

  defmodule BareClient do
    @moduledoc false
    use Client
  end

  defmodule OverridingClient do
    @moduledoc false
    use Client

    alias Raxol.AgentClientProtocol.Schema.ClientTypes.ReadTextFileResponse

    @impl true
    def init(arg), do: {:ok, {:custom_init, arg}}

    @impl true
    def read_text_file(_req, _ctx), do: {:ok, ReadTextFileResponse.new("overridden")}

    @impl true
    def session_update(_notification, _ctx), do: :overridden_marker

    @impl true
    def handle_ext_notification(_wire, _params, _ctx), do: :overridden_marker
  end

  # -- callback surface: naming/arity mirrors MethodTable exactly ---------

  describe "generated callback surface" do
    test "callbacks/0 matches MethodTable.rows_for_side(:client) exactly" do
      expected =
        for row <- MethodTable.rows_for_side(:client), row.callback != nil do
          {row.callback, if(row.params == nil, do: 1, else: 2), row.wire}
        end

      assert Client.callbacks() == expected
      # 9 core client rows ($/cancel_request, direction: both, has callback:
      # nil), plus the additive `_raxol/session.record` ext row = 10.
      assert length(Client.callbacks()) == 10
    end

    test "every client-side row has params != nil (all callbacks arity 2)" do
      assert Enum.all?(Client.callbacks(), fn {_cb, arity, _wire} -> arity == 2 end)
    end

    test "session/update is the sole CORE notification-kind callback" do
      notification_rows =
        Enum.filter(Codegen.rows(:client), &(&1.kind == :notification and &1.ext == nil))

      assert Enum.map(notification_rows, & &1.callback) == [:session_update]

      # The additive reattach ext contributes exactly one a2c notification
      # callback (`_raxol/session.record`); it never displaces the core one.
      ext_notifications =
        Enum.filter(Codegen.rows(:client), &(&1.kind == :notification and &1.ext == :raxol))

      assert Enum.map(ext_notifications, & &1.callback) == [:raxol_session_record]
    end

    test "behaviour_info/1 declares every table callback plus init/1, handle_ext_request/3, handle_ext_notification/3" do
      declared = Client.behaviour_info(:callbacks) |> MapSet.new()

      table_callbacks =
        for {cb, arity, _wire} <- Client.callbacks(), into: MapSet.new(), do: {cb, arity}

      assert MapSet.subset?(table_callbacks, declared)
      assert MapSet.member?(declared, {:init, 1})
      assert MapSet.member?(declared, {:handle_ext_request, 3})
      assert MapSet.member?(declared, {:handle_ext_notification, 3})
    end
  end

  # -- defaults: every unoverridden callback is a safe, wire-correct no-op --

  describe "default implementations (BareClient, nothing overridden)" do
    test "init/1 default is the identity {:ok, handler_arg}" do
      assert BareClient.init(:some_arg) == {:ok, :some_arg}
    end

    test "every request-kind callback defaults to {:error, method_not_found}" do
      for row <- Codegen.rows(:client), row.kind == :request do
        assert apply(BareClient, row.callback, [nil, :fake_ctx]) ==
                 {:error, Error.method_not_found()},
               "expected #{row.callback}/2 to default to method_not_found"
      end
    end

    # W17-client: the generated default now broadcasts to `Client.subscribe/3`
    # subscribers (client_ergonomics_test.exs covers the subscription
    # mechanics in depth) instead of being a pure no-op, so this needs a
    # real `conn` pid and a notification-shaped argument -- `:fake_ctx`/
    # `nil` placeholders no longer apply for THIS one row.
    test "session_update/2 (the sole notification row) broadcasts to subscribers and returns :ok" do
      conn = self()
      ctx = %Ctx{conn: conn, role: :client}
      notification = %{session_id: "sess-1", update: {:agent_message_chunk, :placeholder}}

      :ok = Client.subscribe(conn, "sess-1", self())
      assert BareClient.session_update(notification, ctx) == :ok
      assert_receive {:acp_session_update, "sess-1", {:agent_message_chunk, :placeholder}}
    end

    test "handle_ext_request/3 defaults to method_not_found" do
      assert BareClient.handle_ext_request("_vendor/thing", %{}, :fake_ctx) ==
               {:error, Error.method_not_found()}
    end

    test "handle_ext_notification/3 defaults to :ok" do
      assert BareClient.handle_ext_notification("_vendor/thing", %{}, :fake_ctx) == :ok
    end
  end

  # -- overridability -------------------------------------------------------

  describe "overriding generated defaults" do
    test "an overridden callback wins over the generated default" do
      assert OverridingClient.init(%{x: 1}) == {:ok, {:custom_init, %{x: 1}}}
      assert {:ok, %{content: "overridden"}} = OverridingClient.read_text_file(nil, :fake_ctx)
      assert OverridingClient.session_update(nil, :fake_ctx) == :overridden_marker
      assert OverridingClient.handle_ext_notification("_x", %{}, :fake_ctx) == :overridden_marker
    end

    test "un-overridden callbacks on OverridingClient still fall back to the default" do
      assert OverridingClient.write_text_file(nil, :fake_ctx) ==
               {:error, Error.method_not_found()}
    end
  end

  # -- child_spec/1 / start_link/2 shape (no Connection required) -----------

  defmodule DummyHandler do
    @moduledoc false
    use Client
  end

  describe "child_spec/1" do
    test "builds the ConnectionSupervisor start MFA with defaults" do
      spec = Client.child_spec(handler: DummyHandler, transport: {Transport.Paired, :fake_handle})

      assert %{id: Client, type: :supervisor} = spec

      assert {Client.ConnectionSupervisor, :start_link,
              [{DummyHandler, nil, {Transport.Paired, :fake_handle}}, []]} = spec.start
    end

    test "threads :handler_arg, :name, :id through" do
      spec =
        Client.child_spec(
          handler: DummyHandler,
          transport: {Transport.Paired, :fake_handle},
          handler_arg: %{seed: 1},
          name: :my_client_sup,
          id: :client_one
        )

      assert spec.id == :client_one

      assert {Client.ConnectionSupervisor, :start_link,
              [
                {DummyHandler, %{seed: 1}, {Transport.Paired, :fake_handle}},
                [name: :my_client_sup]
              ]} = spec.start
    end

    test "requires :handler and :transport" do
      assert_raise KeyError, fn -> Client.child_spec(transport: {Transport.Paired, :h}) end
      assert_raise KeyError, fn -> Client.child_spec(handler: DummyHandler) end
    end
  end

  describe "start_link/2" do
    test "requires :transport" do
      assert_raise KeyError, fn -> Client.start_link(DummyHandler, []) end
    end
  end

  # -- end-to-end smoke: initialize -> session/new -> prompt (2 updates) ----

  defmodule E2EAgent do
    @moduledoc false
    use Raxol.AgentClientProtocol.Agent

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
    use Client

    @impl true
    def session_update(notification, ctx) do
      send(ctx.handler_state, {:session_update, notification})
      :ok
    end
  end

  describe "end-to-end smoke over Transport.Paired" do
    # ExUnit has no runtime skip: a callback returning {:skip, _} raises and
    # invalidates the module. Decide at load time instead.
    if not Code.ensure_loaded?(Raxol.AgentClientProtocol.Connection) do
      @describetag skip:
                     "Raxol.AgentClientProtocol.Connection has not landed in this worktree yet"
    end

    test "client-side session_update/2 observes both streamed updates before the prompt response" do
      alias Raxol.AgentClientProtocol.Connection

      alias Raxol.AgentClientProtocol.Schema.AgentTypes.{
        InitializeRequest,
        NewSessionRequest,
        PromptRequest
      }

      alias Raxol.AgentClientProtocol.Schema.ContentBlock

      {agent_handle, client_handle} = Transport.Paired.create_pair()

      {:ok, agent_sup} =
        Raxol.AgentClientProtocol.Agent.start_link(E2EAgent,
          transport: {Transport.Paired, agent_handle}
        )

      {:ok, client_sup} =
        Client.start_link(E2EClient,
          transport: {Transport.Paired, client_handle},
          handler_arg: self()
        )

      on_exit(fn -> Teardown.stop_all([agent_sup, client_sup]) end)

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

      # Generous timeout (matching the request timeouts above): the two
      # notifications are dispatched to this process AFTER the synchronous
      # prompt response unblocks, so under a loaded async suite they can land
      # >100ms (the assert_receive default) later. They are never lost, only
      # late -- a tight default timeout is the sole reason this smoke test
      # flaked ~2.5% of runs.
      assert_receive {:session_update, %{update: {:agent_message_chunk, chunk1}}}, 5_000
      assert_receive {:session_update, %{update: {:agent_message_chunk, chunk2}}}, 5_000

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
