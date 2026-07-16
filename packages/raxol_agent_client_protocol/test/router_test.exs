# Tests pinning Raxol.AgentClientProtocol.Router per
# scratchpad/specs/acp-methodtable-design.md (D1-1 decode/4 arity, D1-2
# $/cancel_request + session/cancel pre-filter exclusion, D1-6 params: nil
# arity-1 dispatch, §4 clause ordering). Not a port of any upstream f1729
# test file -- Router and its codegen have no upstream analogue.
#
# Capability gating (design doc §6, D1-3's "capability check on the wire
# method string BEFORE decode" ordering) is explicitly Connection's job,
# not Router's -- Router has no capability awareness at all, so it is not
# exercised here. See the "capability gating is out of scope" note below.
defmodule Raxol.AgentClientProtocol.RouterTest do
  use ExUnit.Case, async: true

  alias Raxol.AgentClientProtocol.Router
  alias Raxol.AgentClientProtocol.Schema.AgentTypes
  alias Raxol.AgentClientProtocol.Schema.ClientTypes
  alias Raxol.AgentClientProtocol.Schema.LifecycleExtras

  defmodule MockAgentHandler do
    @moduledoc false
    def prompt(req, ctx), do: {:prompt_called, req, ctx}
    def initialize(req, ctx), do: {:initialize_called, req, ctx}
    def logout(ctx), do: {:logout_called, ctx}
  end

  defmodule MockClientHandler do
    @moduledoc false
    def read_text_file(req, ctx), do: {:read_text_file_called, req, ctx}
    def session_update(n, ctx), do: {:session_update_called, n, ctx}
  end

  # -- decode/4 happy paths: :agent side ---------------------------------------

  describe "decode/4 on the :agent side" do
    test "session/prompt (normal request, params != nil)" do
      params = %{"sessionId" => "s1", "prompt" => []}

      assert {:ok, {:prompt, %AgentTypes.PromptRequest{} = req}} =
               Router.decode(:agent, :request, "session/prompt", params)

      assert req.session_id == "s1"
      assert req.prompt == []
    end

    test "initialize (normal request, params != nil)" do
      params = %{"protocolVersion" => 1}

      assert {:ok, {:initialize, %AgentTypes.InitializeRequest{} = req}} =
               Router.decode(:agent, :request, "initialize", params)

      assert req.protocol_version == 1
    end

    test "logout (D1-6: params: nil row -- decode passes nil straight through)" do
      assert {:ok, {:logout, nil}} = Router.decode(:agent, :request, "logout", %{"anything" => 1})
      assert {:ok, {:logout, nil}} = Router.decode(:agent, :request, "logout", nil)
    end

    test "decode failure on a normal request propagates the from_json error" do
      assert {:error, {:missing_field, "sessionId"}} =
               Router.decode(:agent, :request, "session/prompt", %{})
    end
  end

  # -- decode/4 happy paths: :client side ---------------------------------------

  describe "decode/4 on the :client side" do
    test "fs/read_text_file (normal request, params != nil)" do
      params = %{"sessionId" => "s1", "path" => "/tmp/x"}

      assert {:ok, {:read_text_file, %ClientTypes.ReadTextFileRequest{} = req}} =
               Router.decode(:client, :request, "fs/read_text_file", params)

      assert req.session_id == "s1"
      assert req.path == "/tmp/x"
    end

    test "session/update (notification, params != nil)" do
      params = %{
        "sessionId" => "s1",
        "update" => %{
          "sessionUpdate" => "agent_message_chunk",
          "content" => %{"type" => "text", "text" => "hi"}
        }
      }

      assert {:ok, {:session_update, %LifecycleExtras.SessionNotification{} = n}} =
               Router.decode(:client, :notification, "session/update", params)

      assert n.session_id == "s1"
    end
  end

  # -- D1-2 fix: protocol / session_control rows generate no Router clause ----

  describe "layer: :protocol and layer: :session_control rows are absent from Router" do
    test "$/cancel_request falls through to method_not_found (Connection must pre-filter it)" do
      assert Router.decode(:agent, :notification, "$/cancel_request", %{"requestId" => 1}) ==
               {:error, :method_not_found}

      assert Router.decode(:client, :notification, "$/cancel_request", %{"requestId" => 1}) ==
               {:error, :method_not_found}
    end

    test "session/cancel falls through to method_not_found (Connection must pre-filter it, §6.0 G2 delta)" do
      assert Router.decode(:agent, :notification, "session/cancel", %{"sessionId" => "s1"}) ==
               {:error, :method_not_found}
    end
  end

  # -- unknown method -> method_not_found ---------------------------------------

  describe "unknown methods" do
    test "unknown request -> {:error, :method_not_found}" do
      assert Router.decode(:agent, :request, "no/such/method", %{}) == {:error, :method_not_found}

      assert Router.decode(:client, :request, "no/such/method", %{}) ==
               {:error, :method_not_found}
    end

    test "unknown notification -> {:error, :method_not_found}" do
      assert Router.decode(:agent, :notification, "no/such/method", %{}) ==
               {:error, :method_not_found}
    end

    test "a known :agent wire method is unrecognized on the :client side" do
      # session/prompt is client_to_agent -- the :client side never handles
      # it, so it must fall through to the catch-all just like any other
      # unrecognized method.
      assert Router.decode(:client, :request, "session/prompt", %{}) ==
               {:error, :method_not_found}
    end
  end

  # -- ext ("_"-prefixed) passthrough: binary preserved end-to-end -------------

  describe "ext passthrough" do
    test "request: binary method preserved, params passed through raw" do
      assert {:ok, {:ext_request, "_vendor/thing", %{"a" => 1}}} =
               Router.decode(:agent, :request, "_vendor/thing", %{"a" => 1})
    end

    test "notification: binary method preserved, params passed through raw" do
      assert {:ok, {:ext_notification, "_vendor/thing", %{"a" => 1}}} =
               Router.decode(:client, :notification, "_vendor/thing", %{"a" => 1})
    end

    test "ext passthrough never creates an atom from the method string" do
      method = "_vendor/" <> (:crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower))
      refute method_already_an_atom?(method)

      assert {:ok, {:ext_request, ^method, %{}}} = Router.decode(:agent, :request, method, %{})
    end
  end

  # -- dispatch/4 --------------------------------------------------------------

  describe "dispatch/4" do
    test "normal request row calls handler with (params, ctx) and returns the handler's result" do
      req = %AgentTypes.PromptRequest{session_id: "s1", prompt: []}

      assert Router.dispatch(:agent, MockAgentHandler, {:prompt, req}, :ctx) ==
               {:prompt_called, req, :ctx}
    end

    test "params: nil row (D1-6) calls handler with (ctx) only, arity 1" do
      assert Router.dispatch(:agent, MockAgentHandler, {:logout, nil}, :ctx) ==
               {:logout_called, :ctx}
    end

    test "notification row always returns :ok regardless of the handler's own return value" do
      n = %LifecycleExtras.SessionNotification{
        session_id: "s1",
        update: {:user_message_chunk, nil}
      }

      assert Router.dispatch(:client, MockClientHandler, {:session_update, n}, :ctx) == :ok
    end
  end

  # -- result_marker/1 (D1-4: computed once at send time, never re-derived) --

  describe "result_marker/1" do
    test "known request row -> {:decode, ResultModule}" do
      assert Router.result_marker("session/prompt") == {:decode, AgentTypes.PromptResponse}

      assert Router.result_marker("fs/read_text_file") ==
               {:decode, ClientTypes.ReadTextFileResponse}

      assert Router.result_marker("logout") == {:decode, LifecycleExtras.LogoutResponse}
    end

    test "ext (\"_\"-prefixed) method -> :ext" do
      assert Router.result_marker("_vendor/thing") == :ext
    end

    test "notification and non-existent wire strings -> :unknown (defensive fallback)" do
      assert Router.result_marker("session/update") == :unknown
      assert Router.result_marker("no/such/method") == :unknown
    end
  end

  # -- capability gating is out of scope for Router ----------------------------
  #
  # Per the design doc's D1-3 fix, Connection must consult MethodTable's
  # `capability` field and reject a gated-and-unnegotiated method with
  # -32601 BEFORE ever calling Router.decode/4. Router itself has zero
  # capability awareness -- fs/read_text_file above decodes successfully
  # with no capability check performed, which is correct: gating happens
  # one layer up, in Connection, not tested here.

  defp method_already_an_atom?(method) do
    _ = String.to_existing_atom(method)
    true
  rescue
    ArgumentError -> false
  end
end
