# Ported from the MIT `f1729/agent_client_protocol` test suite
# (c) 2025 f1729; see NOTICE.md. Adapted: module names restructured under
# Raxol.AgentClientProtocol.Schema.Unstable.*; assertions updated for the
# total from_json contract ({:ok, t} | {:error, reason}, never a bare/raising
# match, per the port's mandatory defect-fix (a)); added coverage for the
# forward-compat `_meta` fold (defect-fix (d)) and the `SessionConfigKind`
# totality fix (upstream had no catch-all for an unknown/missing "type",
# defect-fix (a)).
#
# The upstream `MaybeUndefined`, `SessionUpdate`, `AgentSide.decode_request`,
# and `MethodNames` test groups are intentionally NOT ported here: those
# types live in different upstream files (`maybe_undefined.ex`,
# `client_types.ex`, `agent_side_connection.ex`, `method_names.ex`
# respectively), so they belong to whichever coder ports those files. The
# `SessionInfoUpdate` tests here are tagged `:pending_sibling` and excluded
# by default since they exercise `MaybeUndefined`, not yet landed at the time
# this file was written — see this file's coder report.
defmodule Raxol.AgentClientProtocol.Schema.UnstableTest do
  use ExUnit.Case, async: true

  alias Raxol.AgentClientProtocol.Schema.Unstable.{
    ConfigOptionUpdate,
    ForkSessionRequest,
    ForkSessionResponse,
    ListSessionsRequest,
    ListSessionsResponse,
    ModelInfo,
    ResumeSessionRequest,
    ResumeSessionResponse,
    SessionConfigKind,
    SessionConfigOption,
    SessionConfigOptionCategory,
    SessionConfigSelect,
    SessionConfigSelectGroup,
    SessionConfigSelectOption,
    SessionConfigSelectOptions,
    SessionForkCapabilities,
    SessionInfo,
    SessionListCapabilities,
    SessionModelState,
    SessionResumeCapabilities,
    SetSessionConfigOptionRequest,
    SetSessionConfigOptionResponse,
    SetSessionModelRequest,
    SetSessionModelResponse
  }

  alias Raxol.AgentClientProtocol.Schema.AgentTypes.SessionCapabilities

  describe "SessionModelState / ModelInfo" do
    test "round trip serialization" do
      model =
        SessionModelState.new("opus-4", [
          ModelInfo.new("opus-4", "Claude Opus 4"),
          %ModelInfo{model_id: "sonnet-4", name: "Claude Sonnet 4", description: "Fast model"}
        ])

      json = SessionModelState.to_json(model)
      assert json["currentModelId"] == "opus-4"
      assert length(json["availableModels"]) == 2
      assert hd(json["availableModels"])["modelId"] == "opus-4"

      assert {:ok, decoded} = SessionModelState.from_json(json)
      assert decoded.current_model_id == "opus-4"
      assert length(decoded.available_models) == 2
      assert Enum.at(decoded.available_models, 1).description == "Fast model"
    end

    test "ModelInfo serialization with optional description" do
      info = ModelInfo.new("test-model", "Test Model")
      json = ModelInfo.to_json(info)
      assert json == %{"modelId" => "test-model", "name" => "Test Model"}

      info_with_desc = %{info | description: "A test model"}
      json2 = ModelInfo.to_json(info_with_desc)
      assert json2["description"] == "A test model"
    end

    test "ModelInfo.from_json/1 is total" do
      assert {:error, {:missing_field, "modelId"}} = ModelInfo.from_json(%{"name" => "x"})
      assert {:error, {:invalid_model_info, nil}} = ModelInfo.from_json(nil)
    end
  end

  describe "SetSessionModelRequest / SetSessionModelResponse" do
    test "request round trip" do
      req = SetSessionModelRequest.new("sess-1", "opus-4")
      json = SetSessionModelRequest.to_json(req)
      assert json == %{"sessionId" => "sess-1", "modelId" => "opus-4"}

      assert {:ok, decoded} = SetSessionModelRequest.from_json(json)
      assert decoded.session_id == "sess-1"
      assert decoded.model_id == "opus-4"
    end

    test "empty response" do
      resp = SetSessionModelResponse.new()
      json = SetSessionModelResponse.to_json(resp)
      assert json == %{}
      assert {:ok, decoded} = SetSessionModelResponse.from_json(json)
      assert decoded._meta == %{}
    end
  end

  describe "SessionConfigOption" do
    test "select option round trip (ungrouped)" do
      opt =
        SessionConfigOption.select(
          "model-selector",
          "Model",
          "opus-4",
          {:ungrouped,
           [
             SessionConfigSelectOption.new("opus-4", "Claude Opus 4"),
             SessionConfigSelectOption.new("sonnet-4", "Claude Sonnet 4")
           ]}
        )

      json = SessionConfigOption.to_json(opt)
      assert json["id"] == "model-selector"
      assert json["name"] == "Model"
      assert json["type"] == "select"
      assert json["currentValue"] == "opus-4"
      assert length(json["options"]) == 2

      assert {:ok, decoded} = SessionConfigOption.from_json(json)
      assert decoded.id == "model-selector"
      assert {:select, select} = decoded.kind
      assert select.current_value == "opus-4"
      assert {:ungrouped, options} = select.options
      assert length(options) == 2
    end

    test "select with grouped options" do
      opt =
        SessionConfigOption.select(
          "model-selector",
          "Model",
          "opus-4",
          {:grouped,
           [
             SessionConfigSelectGroup.new("premium", "Premium Models", [
               SessionConfigSelectOption.new("opus-4", "Claude Opus 4")
             ]),
             SessionConfigSelectGroup.new("standard", "Standard Models", [
               SessionConfigSelectOption.new("sonnet-4", "Claude Sonnet 4")
             ])
           ]}
        )

      json = SessionConfigOption.to_json(opt)
      assert length(json["options"]) == 2
      assert hd(json["options"])["group"] == "premium"

      assert {:ok, decoded} = SessionConfigOption.from_json(json)
      {:select, select} = decoded.kind
      {:grouped, groups} = select.options
      assert length(groups) == 2
      assert hd(groups).group == "premium"
    end

    test "with category" do
      opt = %{SessionConfigOption.select("m", "M", "v1", {:ungrouped, []}) | category: :model}

      json = SessionConfigOption.to_json(opt)
      assert json["category"] == "model"

      assert {:ok, decoded} = SessionConfigOption.from_json(json)
      assert decoded.category == :model
    end

    test "from_json/1 folds unknown wire fields into _meta alongside the flattened kind fields" do
      assert {:ok, %SessionConfigOption{_meta: meta}} =
               SessionConfigOption.from_json(%{
                 "id" => "m",
                 "name" => "M",
                 "type" => "select",
                 "currentValue" => "v",
                 "options" => [],
                 "vendorX" => "y"
               })

      assert meta == %{"vendorX" => "y"}
    end

    test "from_json/1 is total: missing id never raises" do
      assert {:error, {:missing_field, "id"}} =
               SessionConfigOption.from_json(%{
                 "name" => "M",
                 "type" => "select",
                 "currentValue" => "v",
                 "options" => []
               })
    end
  end

  describe "SessionConfigKind" do
    test "unrecognized type is total, not a raise (upstream had no catch-all)" do
      assert {:error, {:unsupported_session_config_kind, "radio"}} =
               SessionConfigKind.from_json(%{"type" => "radio"})
    end

    test "missing type is total" do
      assert {:error, {:missing_field, "type"}} = SessionConfigKind.from_json(%{})
    end
  end

  describe "SessionConfigSelectOptions untagged union" do
    test "empty list decodes as ungrouped" do
      assert {:ok, {:ungrouped, []}} = SessionConfigSelectOptions.from_json([])
    end

    test "non-list input is total" do
      assert {:error, {:invalid_session_config_select_options, "nope"}} =
               SessionConfigSelectOptions.from_json("nope")
    end
  end

  describe "SessionConfigOptionCategory" do
    test "all variants" do
      assert SessionConfigOptionCategory.to_json(:mode) == "mode"
      assert SessionConfigOptionCategory.to_json(:model) == "model"
      assert SessionConfigOptionCategory.to_json(:thought_level) == "thought_level"
      assert SessionConfigOptionCategory.to_json(:other) == "other"

      assert SessionConfigOptionCategory.from_json("mode") == {:ok, :mode}
      assert SessionConfigOptionCategory.from_json("model") == {:ok, :model}
      assert SessionConfigOptionCategory.from_json("thought_level") == {:ok, :thought_level}
      assert SessionConfigOptionCategory.from_json("unknown") == {:ok, :other}
    end
  end

  describe "SessionConfigSelect" do
    test "carries no independent _meta (flattened into its parent)" do
      select = SessionConfigSelect.new("v1", {:ungrouped, []})
      refute Map.has_key?(Map.from_struct(select), :_meta)
    end
  end

  describe "SetSessionConfigOptionRequest / SetSessionConfigOptionResponse" do
    test "request round trip" do
      req = SetSessionConfigOptionRequest.new("sess-1", "model-selector", "opus-4")
      json = SetSessionConfigOptionRequest.to_json(req)

      assert json == %{
               "sessionId" => "sess-1",
               "configId" => "model-selector",
               "value" => "opus-4"
             }

      assert {:ok, decoded} = SetSessionConfigOptionRequest.from_json(json)
      assert decoded.config_id == "model-selector"
      assert decoded.value == "opus-4"
    end

    test "response round trip" do
      resp =
        SetSessionConfigOptionResponse.new([
          SessionConfigOption.select("m", "Model", "v1", {:ungrouped, []})
        ])

      json = SetSessionConfigOptionResponse.to_json(resp)
      assert length(json["configOptions"]) == 1

      assert {:ok, decoded} = SetSessionConfigOptionResponse.from_json(json)
      assert length(decoded.config_options) == 1
    end
  end

  describe "ForkSessionRequest / ForkSessionResponse" do
    test "request round trip" do
      req = ForkSessionRequest.new("sess-1", "/home/user")
      json = ForkSessionRequest.to_json(req)
      assert json == %{"sessionId" => "sess-1", "cwd" => "/home/user"}

      assert {:ok, decoded} = ForkSessionRequest.from_json(json)
      assert decoded.session_id == "sess-1"
      assert decoded.cwd == "/home/user"
      assert decoded.mcp_servers == []
    end

    test "response minimal round trip" do
      resp = ForkSessionResponse.new("new-sess")
      json = ForkSessionResponse.to_json(resp)
      assert json == %{"sessionId" => "new-sess"}

      assert {:ok, decoded} = ForkSessionResponse.from_json(json)
      assert decoded.session_id == "new-sess"
      assert decoded.modes == nil
      assert decoded.models == nil
      assert decoded.config_options == nil
    end

    test "response with models and config_options" do
      resp = %ForkSessionResponse{
        session_id: "new-sess",
        models: SessionModelState.new("opus", [ModelInfo.new("opus", "Opus")])
      }

      json = ForkSessionResponse.to_json(resp)
      assert json["models"]["currentModelId"] == "opus"

      assert {:ok, decoded} = ForkSessionResponse.from_json(json)
      assert decoded.models.current_model_id == "opus"
    end
  end

  describe "ResumeSessionRequest / ResumeSessionResponse" do
    test "request round trip" do
      req = ResumeSessionRequest.new("sess-1", "/home/user")
      json = ResumeSessionRequest.to_json(req)
      assert json == %{"sessionId" => "sess-1", "cwd" => "/home/user"}

      assert {:ok, decoded} = ResumeSessionRequest.from_json(json)
      assert decoded.session_id == "sess-1"
    end

    test "response empty round trip" do
      resp = ResumeSessionResponse.new()
      json = ResumeSessionResponse.to_json(resp)
      assert json == %{}

      assert {:ok, decoded} = ResumeSessionResponse.from_json(json)
      assert decoded.modes == nil
    end
  end

  describe "ListSessionsRequest / ListSessionsResponse" do
    test "request empty round trip" do
      req = ListSessionsRequest.new()
      json = ListSessionsRequest.to_json(req)
      assert json == %{}

      assert {:ok, decoded} = ListSessionsRequest.from_json(json)
      assert decoded.cwd == nil
      assert decoded.cursor == nil
    end

    test "request with cwd and cursor" do
      req = %ListSessionsRequest{cwd: "/home", cursor: "abc123"}
      json = ListSessionsRequest.to_json(req)
      assert json == %{"cwd" => "/home", "cursor" => "abc123"}
    end

    test "response round trip" do
      resp =
        ListSessionsResponse.new([
          SessionInfo.new("sess-1", "/home"),
          %SessionInfo{
            session_id: "sess-2",
            cwd: "/tmp",
            title: "My Session",
            updated_at: "2025-01-01T00:00:00Z"
          }
        ])

      json = ListSessionsResponse.to_json(resp)
      assert length(json["sessions"]) == 2
      assert Enum.at(json["sessions"], 1)["title"] == "My Session"

      assert {:ok, decoded} = ListSessionsResponse.from_json(json)
      assert length(decoded.sessions) == 2
      assert Enum.at(decoded.sessions, 1).title == "My Session"
    end

    test "response with next_cursor" do
      resp = %{ListSessionsResponse.new([]) | next_cursor: "page2"}
      json = ListSessionsResponse.to_json(resp)
      assert json["nextCursor"] == "page2"
    end

    test "response.from_json/1 is total" do
      assert {:error, {:missing_field, "sessions"}} = ListSessionsResponse.from_json(%{})
    end
  end

  describe "SessionCapabilities with unstable list/fork/resume fields" do
    test "round trip" do
      caps = %SessionCapabilities{
        modes: true,
        list: SessionListCapabilities.new(),
        fork: SessionForkCapabilities.new(),
        resume: SessionResumeCapabilities.new()
      }

      json = SessionCapabilities.to_json(caps)
      assert json["modes"] == true
      assert json["list"] == %{}
      assert json["fork"] == %{}
      assert json["resume"] == %{}

      assert {:ok, decoded} = SessionCapabilities.from_json(json)
      assert decoded.modes == true
      assert decoded.list != nil
      assert decoded.fork != nil
      assert decoded.resume != nil
    end
  end

  describe "ConfigOptionUpdate" do
    test "round trip" do
      update =
        ConfigOptionUpdate.new([
          SessionConfigOption.select("m", "Model", "v1", {:ungrouped, []})
        ])

      json = ConfigOptionUpdate.to_json(update)
      assert length(json["configOptions"]) == 1

      assert {:ok, decoded} = ConfigOptionUpdate.from_json(json)
      assert length(decoded.config_options) == 1
    end
  end

  @tag :pending_sibling
  test "SessionInfoUpdate (needs MaybeUndefined)" do
    alias Raxol.AgentClientProtocol.Schema.Unstable.SessionInfoUpdate

    update = SessionInfoUpdate.new()
    assert SessionInfoUpdate.to_json(update) == %{}

    update2 = %SessionInfoUpdate{title: {:value, "My Session"}}
    assert SessionInfoUpdate.to_json(update2) == %{"title" => "My Session"}

    update3 = %SessionInfoUpdate{title: nil}
    assert SessionInfoUpdate.to_json(update3) == %{"title" => nil}

    assert {:ok, decoded} = SessionInfoUpdate.from_json(%{})
    assert decoded.title == :undefined
    assert decoded.updated_at == :undefined
  end

  describe "NewSessionResponse / LoadSessionResponse with unstable fields" do
    test "NewSessionResponse with models" do
      alias Raxol.AgentClientProtocol.Schema.AgentTypes.NewSessionResponse

      resp = %NewSessionResponse{
        session_id: "s1",
        models: SessionModelState.new("opus", [ModelInfo.new("opus", "Opus")])
      }

      json = NewSessionResponse.to_json(resp)
      assert json["models"]["currentModelId"] == "opus"

      assert {:ok, decoded} = NewSessionResponse.from_json(json)
      assert decoded.models.current_model_id == "opus"
    end

    test "NewSessionResponse with config_options" do
      alias Raxol.AgentClientProtocol.Schema.AgentTypes.NewSessionResponse

      resp = %NewSessionResponse{
        session_id: "s1",
        config_options: [SessionConfigOption.select("m", "M", "v", {:ungrouped, []})]
      }

      json = NewSessionResponse.to_json(resp)
      assert length(json["configOptions"]) == 1

      assert {:ok, decoded} = NewSessionResponse.from_json(json)
      assert length(decoded.config_options) == 1
    end

    test "LoadSessionResponse with models and config_options" do
      alias Raxol.AgentClientProtocol.Schema.AgentTypes.LoadSessionResponse

      resp = %LoadSessionResponse{
        models: SessionModelState.new("opus", [ModelInfo.new("opus", "Opus")]),
        config_options: [SessionConfigOption.select("m", "M", "v", {:ungrouped, []})]
      }

      json = LoadSessionResponse.to_json(resp)
      assert json["models"]["currentModelId"] == "opus"
      assert length(json["configOptions"]) == 1

      assert {:ok, decoded} = LoadSessionResponse.from_json(json)
      assert decoded.models.current_model_id == "opus"
      assert length(decoded.config_options) == 1
    end
  end

  describe "ClientRequest unstable variants (routing)" do
    test "method names" do
      alias Raxol.AgentClientProtocol.Schema.AgentTypes.ClientRequest

      assert ClientRequest.method({:list_sessions, nil}) == "session/list"
      assert ClientRequest.method({:fork_session, nil}) == "session/fork"
      assert ClientRequest.method({:resume_session, nil}) == "session/resume"

      assert ClientRequest.method({:set_session_config_option, nil}) ==
               "session/set_config_option"

      assert ClientRequest.method({:set_session_model, nil}) == "session/set_model"
    end
  end
end
