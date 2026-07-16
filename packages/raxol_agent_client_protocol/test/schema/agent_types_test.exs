# Ported from the MIT `f1729/agent_client_protocol` test suite
# (c) 2025 f1729; see NOTICE.md. Adapted: module names restructured under
# Raxol.AgentClientProtocol.Schema.AgentTypes.*; assertions updated for the
# total from_json contract ({:ok, t} | {:error, reason}, never a bare/raising
# match, per the port's mandatory defect-fix (a)); added coverage for the
# forward-compat `_meta` fold (defect-fix (d)) and the `StopReason.from_json/1`
# totality fix (upstream had no catch-all clause, defect-fix (a)).
#
# `Implementation`/`InitializeRequest`/`InitializeResponse` tests that touch
# `ClientCapabilities` (ported separately, in `client_types.ex`, not yet
# landed at the time this file was written) are tagged `:pending_sibling` and
# excluded by default — see this file's coder report for the compile-barrier
# note.
defmodule Raxol.AgentClientProtocol.Schema.AgentTypesTest do
  use ExUnit.Case, async: true

  alias Raxol.AgentClientProtocol.Schema.AgentTypes.{
    AgentAuthCapabilities,
    AgentCapabilities,
    AuthMethod,
    CancelNotification,
    EnvVariable,
    HttpHeader,
    Implementation,
    LogoutCapabilities,
    McpCapabilities,
    McpServer,
    McpServerHttp,
    McpServerSse,
    McpServerStdio,
    PromptCapabilities,
    PromptResponse,
    SessionCapabilities,
    SessionCloseCapabilities,
    SessionDeleteCapabilities,
    SessionMode,
    SessionModeState,
    SetSessionModeRequest,
    StopReason
  }

  alias Raxol.AgentClientProtocol.Schema.AgentTypes.{
    AuthenticateRequest,
    AuthenticateResponse,
    CancelNotification,
    ClientRequest,
    LoadSessionRequest,
    NewSessionRequest,
    NewSessionResponse,
    PromptRequest,
    SetSessionModeResponse
  }

  describe "Implementation" do
    test "to_json/from_json round trip" do
      impl = Implementation.new("test-agent", "1.0.0")
      json = Implementation.to_json(impl)
      assert json == %{"name" => "test-agent", "version" => "1.0.0"}

      assert {:ok, decoded} = Implementation.from_json(json)
      assert decoded.name == "test-agent"
      assert decoded.version == "1.0.0"
    end

    test "with title and _meta" do
      impl = %Implementation{
        name: "test",
        version: "1.0",
        title: "Test Agent",
        _meta: %{"x" => 1}
      }

      json = Implementation.to_json(impl)
      assert json["title"] == "Test Agent"
      assert json["_meta"] == %{"x" => 1}
      refute Map.has_key?(json, "x")
    end

    test "to_json/1 nests _meta under the wire \"_meta\" key, matching WireFields.emit_meta/2 (regression: put_meta/2 used to flatten it onto the top-level object)" do
      impl = %Implementation{name: "test", version: "1.0", _meta: %{"custom" => true}}

      assert Implementation.to_json(impl) == %{
               "name" => "test",
               "version" => "1.0",
               "_meta" => %{"custom" => true}
             }
    end

    test "a wire map with an explicit nested _meta object round-trips byte-faithfully" do
      wire = %{"name" => "test", "version" => "1.0", "_meta" => %{"custom" => true, "n" => 1}}

      assert {:ok, decoded} = Implementation.from_json(wire)
      assert decoded._meta == %{"custom" => true, "n" => 1}
      assert Implementation.to_json(decoded) == wire
    end

    test "from_json/1 is total: missing required field never raises" do
      assert {:error, {:missing_field, "name"}} = Implementation.from_json(%{"version" => "1"})
      assert {:error, {:invalid_implementation, "nope"}} = Implementation.from_json("nope")
      assert {:error, {:invalid_implementation, nil}} = Implementation.from_json(nil)
    end

    test "from_json/1 folds unknown wire fields into _meta (forward-compat)" do
      assert {:ok, %Implementation{_meta: meta}} =
               Implementation.from_json(%{"name" => "a", "version" => "1", "vendorX" => "y"})

      assert meta == %{"vendorX" => "y"}
    end

    test "from_json/1 merges an explicit _meta object with folded unknown fields" do
      assert {:ok, %Implementation{_meta: meta}} =
               Implementation.from_json(%{
                 "name" => "a",
                 "version" => "1",
                 "vendorX" => "y",
                 "_meta" => %{"z" => 1}
               })

      assert meta == %{"vendorX" => "y", "z" => 1}
    end
  end

  describe "AuthMethod" do
    test "to_json/from_json round trip" do
      am = AuthMethod.new("oauth", "OAuth 2.0")
      json = AuthMethod.to_json(am)
      assert json == %{"id" => "oauth", "name" => "OAuth 2.0"}

      assert {:ok, decoded} = AuthMethod.from_json(json)
      assert decoded.id == "oauth"
    end

    test "from_json/1 is total" do
      assert {:error, {:missing_field, "id"}} = AuthMethod.from_json(%{"name" => "x"})
    end
  end

  @tag :pending_sibling
  test "InitializeRequest to_json/from_json (needs ClientCapabilities)" do
    alias Raxol.AgentClientProtocol.Schema.AgentTypes.InitializeRequest
    req = InitializeRequest.new(1)
    json = InitializeRequest.to_json(req)
    assert json["protocolVersion"] == 1
    assert {:ok, decoded} = InitializeRequest.from_json(json)
    assert decoded.protocol_version == 1
  end

  @tag :pending_sibling
  test "InitializeResponse to_json/from_json (needs ClientCapabilities/AgentCapabilities)" do
    alias Raxol.AgentClientProtocol.Schema.AgentTypes.InitializeResponse
    resp = InitializeResponse.new(1)
    json = InitializeResponse.to_json(resp)
    assert json["protocolVersion"] == 1
    assert {:ok, decoded} = InitializeResponse.from_json(json)
    assert decoded.protocol_version == 1
  end

  describe "AuthenticateRequest / AuthenticateResponse" do
    test "AuthenticateRequest round trip" do
      req = AuthenticateRequest.new("oauth")
      json = AuthenticateRequest.to_json(req)
      assert json == %{"methodId" => "oauth"}
      assert {:ok, decoded} = AuthenticateRequest.from_json(json)
      assert decoded.method_id == "oauth"
    end

    test "AuthenticateResponse round trip (empty besides _meta)" do
      resp = AuthenticateResponse.new()
      assert AuthenticateResponse.to_json(resp) == %{}
      assert {:ok, %AuthenticateResponse{_meta: %{}}} = AuthenticateResponse.from_json(%{})
    end
  end

  describe "NewSessionRequest / NewSessionResponse" do
    test "NewSessionRequest to_json/from_json" do
      req = NewSessionRequest.new("/home/user")
      json = NewSessionRequest.to_json(req)
      assert json["cwd"] == "/home/user"
      assert json["mcpServers"] == []

      assert {:ok, decoded} = NewSessionRequest.from_json(json)
      assert decoded.cwd == "/home/user"
    end

    test "NewSessionResponse to_json/from_json" do
      resp = NewSessionResponse.new("session-123")
      json = NewSessionResponse.to_json(resp)
      assert json["sessionId"] == "session-123"

      assert {:ok, decoded} = NewSessionResponse.from_json(json)
      assert decoded.session_id == "session-123"
    end

    test "NewSessionRequest.from_json/1 is total" do
      assert {:error, {:missing_field, "cwd"}} = NewSessionRequest.from_json(%{})
      assert {:error, {:invalid_new_session_request, nil}} = NewSessionRequest.from_json(nil)
    end
  end

  describe "LoadSessionRequest" do
    test "round trip" do
      req = LoadSessionRequest.new("s1", "/home")
      json = LoadSessionRequest.to_json(req)
      assert json == %{"sessionId" => "s1", "cwd" => "/home", "mcpServers" => []}

      assert {:ok, decoded} = LoadSessionRequest.from_json(json)
      assert decoded.session_id == "s1"
      assert decoded.cwd == "/home"
    end
  end

  describe "PromptResponse / StopReason" do
    test "PromptResponse with stop_reason" do
      resp = PromptResponse.new(:end_turn)
      json = PromptResponse.to_json(resp)
      assert json["stopReason"] == "end_turn"

      assert {:ok, decoded} = PromptResponse.from_json(json)
      assert decoded.stop_reason == :end_turn
    end

    test "StopReason all values round trip" do
      for {atom, str} <- [
            end_turn: "end_turn",
            max_tokens: "max_tokens",
            max_turn_requests: "max_turn_requests",
            refusal: "refusal",
            cancelled: "cancelled"
          ] do
        assert StopReason.to_json(atom) == str
        assert StopReason.from_json(str) == {:ok, atom}
      end
    end

    test "StopReason.from_json/1 is total: unrecognized value never raises (upstream had no catch-all)" do
      assert {:error, {:invalid_stop_reason, "bogus"}} = StopReason.from_json("bogus")
      assert {:error, {:invalid_stop_reason, nil}} = StopReason.from_json(nil)
    end

    test "PromptResponse.from_json/1 propagates an invalid stop reason as an error, not a raise" do
      assert {:error, {:invalid_stop_reason, "bogus"}} =
               PromptResponse.from_json(%{"stopReason" => "bogus"})
    end
  end

  describe "McpServer union" do
    test "stdio to_json/from_json (untagged variant)" do
      server = {:stdio, McpServerStdio.new("test-server", "/usr/bin/server")}
      json = McpServer.to_json(server)
      assert json["name"] == "test-server"
      assert json["command"] == "/usr/bin/server"
      refute Map.has_key?(json, "type")

      assert {:ok, decoded} = McpServer.from_json(json)
      assert {:stdio, stdio} = decoded
      assert stdio.name == "test-server"
    end

    test "http to_json/from_json" do
      server = {:http, McpServerHttp.new("http-server", "https://api.example.com")}
      json = McpServer.to_json(server)
      assert json["type"] == "http"
      assert json["url"] == "https://api.example.com"

      assert {:ok, decoded} = McpServer.from_json(json)
      assert {:http, http} = decoded
      assert http.url == "https://api.example.com"
      # "type" must not leak into the sub-struct's own _meta
      assert http._meta == %{}
    end

    test "sse to_json/from_json" do
      server = {:sse, McpServerSse.new("sse-server", "https://sse.example.com")}
      json = McpServer.to_json(server)
      assert json["type"] == "sse"

      assert {:ok, decoded} = McpServer.from_json(json)
      assert {:sse, sse} = decoded
      assert sse.name == "sse-server"
    end

    test "McpServerStdio carries env/args and headers round trip via McpServerHttp" do
      server =
        {:http,
         %McpServerHttp{
           name: "h",
           url: "https://x",
           headers: [HttpHeader.new("Authorization", "Bearer x")]
         }}

      json = McpServer.to_json(server)
      assert {:ok, {:http, decoded}} = McpServer.from_json(json)
      assert [%HttpHeader{name: "Authorization", value: "Bearer x"}] = decoded.headers
    end

    test "McpServerStdio env round trip" do
      server = %McpServerStdio{
        name: "s",
        command: "cmd",
        args: ["--flag"],
        env: [EnvVariable.new("KEY", "value")]
      }

      json = McpServerStdio.to_json(server)
      assert {:ok, decoded} = McpServerStdio.from_json(json)
      assert decoded.args == ["--flag"]
      assert [%EnvVariable{name: "KEY", value: "value"}] = decoded.env
    end
  end

  describe "AgentCapabilities / PromptCapabilities / McpCapabilities / SessionCapabilities" do
    test "AgentCapabilities defaults" do
      caps = AgentCapabilities.new()
      assert caps.load_session == false
      assert AgentCapabilities.to_json(caps) == %{"loadSession" => false}
    end

    test "PromptCapabilities defaults" do
      caps = PromptCapabilities.new()

      assert PromptCapabilities.to_json(caps) == %{
               "image" => false,
               "audio" => false,
               "embeddedContext" => false
             }

      assert {:ok, decoded} = PromptCapabilities.from_json(%{})
      assert decoded == caps
    end

    test "McpCapabilities defaults" do
      caps = McpCapabilities.new()
      assert McpCapabilities.to_json(caps) == %{"http" => false, "sse" => false}
    end

    test "SessionCapabilities defaults" do
      caps = SessionCapabilities.new()
      assert SessionCapabilities.to_json(caps) == %{"modes" => false}
      assert {:ok, decoded} = SessionCapabilities.from_json(%{"modes" => true})
      assert decoded.modes == true
    end

    test "SessionCapabilities delete/close round trip (oracle-divergence gap closed)" do
      caps = %SessionCapabilities{
        delete: SessionDeleteCapabilities.new(),
        close: SessionCloseCapabilities.new()
      }

      json = SessionCapabilities.to_json(caps)
      assert json["delete"] == %{}
      assert json["close"] == %{}

      assert {:ok, decoded} = SessionCapabilities.from_json(json)
      assert decoded == caps
    end

    test "SessionCapabilities delete/close default to nil and are omitted on encode" do
      caps = SessionCapabilities.new()
      json = SessionCapabilities.to_json(caps)
      refute Map.has_key?(json, "delete")
      refute Map.has_key?(json, "close")

      assert {:ok, decoded} = SessionCapabilities.from_json(%{})
      assert decoded.delete == nil
      assert decoded.close == nil
    end

    test "AgentCapabilities auth.logout round trip (oracle-divergence gap closed)" do
      caps = %AgentCapabilities{auth: %AgentAuthCapabilities{logout: LogoutCapabilities.new()}}

      json = AgentCapabilities.to_json(caps)
      assert json["auth"] == %{"logout" => %{}}

      assert {:ok, decoded} = AgentCapabilities.from_json(json)
      assert decoded == caps
    end

    test "AgentCapabilities auth defaults to nil and is omitted on encode" do
      caps = AgentCapabilities.new()
      json = AgentCapabilities.to_json(caps)
      refute Map.has_key?(json, "auth")

      assert {:ok, decoded} = AgentCapabilities.from_json(%{})
      assert decoded.auth == nil
    end

    test "AgentAuthCapabilities with logout absent" do
      caps = AgentAuthCapabilities.new()
      assert AgentAuthCapabilities.to_json(caps) == %{}
      assert {:ok, decoded} = AgentAuthCapabilities.from_json(%{})
      assert decoded.logout == nil
    end

    test "SessionDeleteCapabilities / SessionCloseCapabilities / LogoutCapabilities are empty-object leaves" do
      for {mod, invalid_tag} <- [
            {SessionDeleteCapabilities, :invalid_session_delete_capabilities},
            {SessionCloseCapabilities, :invalid_session_close_capabilities},
            {LogoutCapabilities, :invalid_logout_capabilities}
          ] do
        leaf = mod.new()
        assert mod.to_json(leaf) == %{}
        assert {:ok, ^leaf} = mod.from_json(%{})
        assert {:error, {^invalid_tag, "nope"}} = mod.from_json("nope")
      end
    end
  end

  describe "CancelNotification" do
    test "to_json/from_json" do
      notif = CancelNotification.new("session-1")
      json = CancelNotification.to_json(notif)
      assert json["sessionId"] == "session-1"

      assert {:ok, decoded} = CancelNotification.from_json(json)
      assert decoded.session_id == "session-1"
    end
  end

  describe "SessionModeState / SessionMode / SetSessionModeRequest / SetSessionModeResponse" do
    test "SessionModeState to_json/from_json" do
      state =
        SessionModeState.new("code", [
          SessionMode.new("code", "Code"),
          SessionMode.new("ask", "Ask")
        ])

      json = SessionModeState.to_json(state)
      assert json["currentModeId"] == "code"
      assert length(json["availableModes"]) == 2

      assert {:ok, decoded} = SessionModeState.from_json(json)
      assert decoded.current_mode_id == "code"
      assert length(decoded.available_modes) == 2
    end

    test "SetSessionModeRequest round trip" do
      req = SetSessionModeRequest.new("s1", "ask")
      json = SetSessionModeRequest.to_json(req)
      assert json == %{"sessionId" => "s1", "modeId" => "ask"}
      assert {:ok, decoded} = SetSessionModeRequest.from_json(json)
      assert decoded.mode_id == "ask"
    end

    test "SetSessionModeResponse round trip (empty besides _meta)" do
      resp = SetSessionModeResponse.new()
      assert SetSessionModeResponse.to_json(resp) == %{}
      assert {:ok, %SetSessionModeResponse{}} = SetSessionModeResponse.from_json(%{})
    end
  end

  describe "PromptRequest" do
    test "from_json/1 is total: missing prompt never raises" do
      assert {:error, {:missing_field, "prompt"}} =
               PromptRequest.from_json(%{"sessionId" => "s1"})
    end
  end

  describe "ClientRequest routing" do
    test "method names" do
      assert ClientRequest.method({:initialize, nil}) == "initialize"
      assert ClientRequest.method({:new_session, nil}) == "session/new"
      assert ClientRequest.method({:prompt, nil}) == "session/prompt"
      assert ClientRequest.method({:set_session_mode, nil}) == "session/set_mode"
    end
  end
end
