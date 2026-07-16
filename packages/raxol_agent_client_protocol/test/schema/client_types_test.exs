# Ported from the MIT `f1729/agent_client_protocol` (c) 2025 f1729; see NOTICE.md.
# Adapted: module names flattened directly under Raxol.AgentClientProtocol.Schema.* (matching
# the convention established by content.ex/plan.ex/tool_call.ex); assertions updated for the
# total from_json contract ({:ok, t} | {:error, reason}, never a bare/raising match); several
# wire shapes corrected to match the pinned ACP schema-oracle (schema-v1.19.0) -- see moduledocs
# in lib/raxol/agent_client_protocol/schema/client_types.ex for the specific defects fixed
# (TerminalExitStatus.signal, TerminalOutputResponse.truncated, WaitForTerminalExitResponse
# flattening, CreateTerminalRequest.output_byte_limit, KillTerminal{Request,Response} naming).
defmodule Raxol.AgentClientProtocol.Schema.ClientTypesTest do
  use ExUnit.Case, async: true

  alias Raxol.AgentClientProtocol.Schema.ClientTypes.CreateTerminalRequest
  alias Raxol.AgentClientProtocol.Schema.ClientTypes.CreateTerminalResponse
  alias Raxol.AgentClientProtocol.Schema.ClientTypes.KillTerminalRequest
  alias Raxol.AgentClientProtocol.Schema.ClientTypes.KillTerminalResponse
  alias Raxol.AgentClientProtocol.Schema.ClientTypes.PermissionOption
  alias Raxol.AgentClientProtocol.Schema.ClientTypes.PermissionOptionKind
  alias Raxol.AgentClientProtocol.Schema.ClientTypes.ReadTextFileRequest
  alias Raxol.AgentClientProtocol.Schema.ClientTypes.ReadTextFileResponse
  alias Raxol.AgentClientProtocol.Schema.ClientTypes.ReleaseTerminalRequest
  alias Raxol.AgentClientProtocol.Schema.ClientTypes.ReleaseTerminalResponse
  alias Raxol.AgentClientProtocol.Schema.ClientTypes.RequestPermissionOutcome
  alias Raxol.AgentClientProtocol.Schema.ClientTypes.RequestPermissionRequest
  alias Raxol.AgentClientProtocol.Schema.ClientTypes.RequestPermissionResponse
  alias Raxol.AgentClientProtocol.Schema.ClientTypes.SelectedPermissionOutcome
  alias Raxol.AgentClientProtocol.Schema.ClientTypes.TerminalExitStatus
  alias Raxol.AgentClientProtocol.Schema.ClientTypes.TerminalOutputRequest
  alias Raxol.AgentClientProtocol.Schema.ClientTypes.TerminalOutputResponse
  alias Raxol.AgentClientProtocol.Schema.ToolCallUpdate
  alias Raxol.AgentClientProtocol.Schema.ToolCallUpdateFields
  alias Raxol.AgentClientProtocol.Schema.ClientTypes.WaitForTerminalExitRequest
  alias Raxol.AgentClientProtocol.Schema.ClientTypes.WaitForTerminalExitResponse
  alias Raxol.AgentClientProtocol.Schema.ClientTypes.WriteTextFileRequest
  alias Raxol.AgentClientProtocol.Schema.ClientTypes.WriteTextFileResponse

  describe "PermissionOptionKind" do
    test "round-trips every variant" do
      for kind <- [:allow_once, :allow_always, :reject_once, :reject_always] do
        json = PermissionOptionKind.to_json(kind)
        assert {:ok, ^kind} = PermissionOptionKind.from_json(json)
      end
    end

    test "from_json is total: unknown string is an error, never a raise" do
      assert {:error, {:invalid_permission_option_kind, "bogus"}} =
               PermissionOptionKind.from_json("bogus")
    end
  end

  describe "PermissionOption" do
    test "to_json/from_json round-trip" do
      opt = PermissionOption.new("allow-once", "Allow Once", :allow_once)
      json = PermissionOption.to_json(opt)
      assert json["optionId"] == "allow-once"
      assert json["name"] == "Allow Once"
      assert json["kind"] == "allow_once"

      assert {:ok, decoded} = PermissionOption.from_json(json)
      assert decoded == opt
    end

    test "from_json is total: missing required field is an error, never a raise" do
      assert {:error, {:missing_field, "kind"}} =
               PermissionOption.from_json(%{"optionId" => "x", "name" => "X"})
    end

    test "unknown wire fields fold into _meta and re-emit (nested under \"_meta\") on encode" do
      json = %{"optionId" => "x", "name" => "X", "kind" => "allow_once", "futureField" => 1}
      assert {:ok, decoded} = PermissionOption.from_json(json)
      assert decoded._meta == %{"futureField" => 1}
      assert PermissionOption.to_json(decoded)["_meta"]["futureField"] == 1
    end
  end

  describe "SelectedPermissionOutcome" do
    test "to_json/from_json round-trip" do
      s = SelectedPermissionOutcome.new("opt-1")
      json = SelectedPermissionOutcome.to_json(s)
      assert json["optionId"] == "opt-1"
      assert {:ok, ^s} = SelectedPermissionOutcome.from_json(json)
    end
  end

  describe "RequestPermissionOutcome" do
    test "cancelled" do
      json = RequestPermissionOutcome.to_json(:cancelled)
      assert json == %{"outcome" => "cancelled"}
      assert {:ok, :cancelled} = RequestPermissionOutcome.from_json(json)
    end

    test "selected" do
      outcome = {:selected, SelectedPermissionOutcome.new("opt-1")}
      json = RequestPermissionOutcome.to_json(outcome)
      assert json["outcome"] == "selected"
      assert json["optionId"] == "opt-1"

      assert {:ok, {:selected, s}} = RequestPermissionOutcome.from_json(json)
      assert s.option_id == "opt-1"
    end

    test "from_json is total: unknown discriminator is an error, never a raise" do
      assert {:error, {:invalid_outcome, "bogus"}} =
               RequestPermissionOutcome.from_json(%{"outcome" => "bogus"})
    end

    test "from_json is total: missing discriminator is an error, never a raise" do
      assert {:error, {:missing_field, "outcome"}} = RequestPermissionOutcome.from_json(%{})
    end
  end

  describe "RequestPermissionResponse" do
    test "to_json/from_json round-trip (nested outcome discriminator)" do
      resp = RequestPermissionResponse.new({:selected, SelectedPermissionOutcome.new("opt-1")})
      json = RequestPermissionResponse.to_json(resp)
      assert json["outcome"]["outcome"] == "selected"
      assert json["outcome"]["optionId"] == "opt-1"

      assert {:ok, decoded} = RequestPermissionResponse.from_json(json)
      assert {:selected, %{option_id: "opt-1"}} = decoded.outcome
    end
  end

  describe "RequestPermissionRequest" do
    test "to_json/from_json round-trip with a real ToolCallUpdate + options" do
      tool_call = ToolCallUpdate.new("tc-1", ToolCallUpdateFields.new())
      opt = PermissionOption.new("allow-once", "Allow Once", :allow_once)
      req = RequestPermissionRequest.new("s1", tool_call, [opt])

      json = RequestPermissionRequest.to_json(req)
      assert json["sessionId"] == "s1"
      assert json["toolCall"]["toolCallId"] == "tc-1"
      assert [%{"optionId" => "allow-once"}] = json["options"]

      assert {:ok, decoded} = RequestPermissionRequest.from_json(json)
      assert decoded.session_id == "s1"
      assert decoded.tool_call.tool_call_id == "tc-1"
      assert [%PermissionOption{option_id: "allow-once"}] = decoded.options
    end

    test "options decode leniently: missing options defaults to []" do
      tool_call = ToolCallUpdate.new("tc-1", ToolCallUpdateFields.new())
      json = %{"sessionId" => "s1", "toolCall" => ToolCallUpdate.to_json(tool_call)}
      assert {:ok, decoded} = RequestPermissionRequest.from_json(json)
      assert decoded.options == []
    end

    test "from_json is total: missing toolCall is an error, never a raise" do
      assert {:error, {:missing_field, "toolCall"}} =
               RequestPermissionRequest.from_json(%{"sessionId" => "s1"})
    end
  end

  describe "WriteTextFileRequest" do
    test "to_json/from_json round-trip" do
      req = WriteTextFileRequest.new("s1", "/tmp/test.txt", "hello world")
      json = WriteTextFileRequest.to_json(req)
      assert json["sessionId"] == "s1"
      assert json["path"] == "/tmp/test.txt"
      assert json["content"] == "hello world"

      assert {:ok, decoded} = WriteTextFileRequest.from_json(json)
      assert decoded.content == "hello world"
    end
  end

  describe "WriteTextFileResponse" do
    test "empty payload round-trips" do
      resp = WriteTextFileResponse.new()
      assert WriteTextFileResponse.to_json(resp) == %{}
      assert {:ok, %WriteTextFileResponse{}} = WriteTextFileResponse.from_json(%{})
    end
  end

  describe "ReadTextFileRequest" do
    test "with line/limit" do
      req = %ReadTextFileRequest{session_id: "s1", path: "/test", line: 10, limit: 50}
      json = ReadTextFileRequest.to_json(req)
      assert json["line"] == 10
      assert json["limit"] == 50

      assert {:ok, decoded} = ReadTextFileRequest.from_json(json)
      assert decoded.line == 10
      assert decoded.limit == 50
    end

    test "without line/limit omits them from the wire" do
      req = ReadTextFileRequest.new("s1", "/test")
      json = ReadTextFileRequest.to_json(req)
      refute Map.has_key?(json, "line")
      refute Map.has_key?(json, "limit")
    end
  end

  describe "ReadTextFileResponse" do
    test "to_json/from_json round-trip" do
      resp = ReadTextFileResponse.new("file contents")
      json = ReadTextFileResponse.to_json(resp)
      assert json["content"] == "file contents"
      assert {:ok, decoded} = ReadTextFileResponse.from_json(json)
      assert decoded.content == "file contents"
    end
  end

  describe "CreateTerminalRequest" do
    test "to_json/from_json round-trip" do
      req = CreateTerminalRequest.new("s1", "echo")
      json = CreateTerminalRequest.to_json(req)
      assert json["command"] == "echo"
      assert json["args"] == []
      assert json["env"] == []
      refute Map.has_key?(json, "outputByteLimit")

      assert {:ok, decoded} = CreateTerminalRequest.from_json(json)
      assert decoded.command == "echo"
      assert decoded.args == []
      assert decoded.env == []
    end

    test "outputByteLimit round-trips (fixed defect: was missing upstream)" do
      req = %CreateTerminalRequest{session_id: "s1", command: "echo", output_byte_limit: 4096}
      json = CreateTerminalRequest.to_json(req)
      assert json["outputByteLimit"] == 4096
      assert {:ok, decoded} = CreateTerminalRequest.from_json(json)
      assert decoded.output_byte_limit == 4096
    end

    test "does not emit a timeoutMs field (fixed defect: upstream field not in the schema)" do
      req = CreateTerminalRequest.new("s1", "echo")
      refute Map.has_key?(CreateTerminalRequest.to_json(req), "timeoutMs")
    end

    test "from_json is total: missing required field is an error, never a raise" do
      assert {:error, {:missing_field, "command"}} =
               CreateTerminalRequest.from_json(%{"sessionId" => "s1"})
    end
  end

  describe "CreateTerminalResponse" do
    test "to_json/from_json round-trip" do
      resp = CreateTerminalResponse.new("term-1")
      json = CreateTerminalResponse.to_json(resp)
      assert json["terminalId"] == "term-1"
      assert {:ok, decoded} = CreateTerminalResponse.from_json(json)
      assert decoded.terminal_id == "term-1"
    end
  end

  describe "TerminalOutputRequest" do
    test "to_json/from_json round-trip" do
      req = TerminalOutputRequest.new("s1", "term-1")
      json = TerminalOutputRequest.to_json(req)
      assert {:ok, decoded} = TerminalOutputRequest.from_json(json)
      assert decoded == req
    end
  end

  describe "TerminalExitStatus" do
    test "to_json/from_json round-trip" do
      status = TerminalExitStatus.new(0)
      json = TerminalExitStatus.to_json(status)
      assert json["exitCode"] == 0
      assert {:ok, decoded} = TerminalExitStatus.from_json(json)
      assert decoded.exit_code == 0
    end

    test "signal round-trips (fixed defect: was missing upstream)" do
      status = TerminalExitStatus.new(nil, "SIGKILL")
      json = TerminalExitStatus.to_json(status)
      assert json["signal"] == "SIGKILL"
      refute Map.has_key?(json, "exitCode")
      assert {:ok, decoded} = TerminalExitStatus.from_json(json)
      assert decoded.signal == "SIGKILL"
      assert decoded.exit_code == nil
    end
  end

  describe "TerminalOutputResponse" do
    test "truncated round-trips (fixed defect: was missing upstream)" do
      resp = TerminalOutputResponse.new("hello", true)
      json = TerminalOutputResponse.to_json(resp)
      assert json["output"] == "hello"
      assert json["truncated"] == true

      assert {:ok, decoded} = TerminalOutputResponse.from_json(json)
      assert decoded.truncated == true
    end

    test "nested exitStatus round-trips" do
      resp = %TerminalOutputResponse{
        output: "done",
        truncated: false,
        exit_status: TerminalExitStatus.new(1, nil)
      }

      json = TerminalOutputResponse.to_json(resp)
      assert json["exitStatus"]["exitCode"] == 1

      assert {:ok, decoded} = TerminalOutputResponse.from_json(json)
      assert decoded.exit_status.exit_code == 1
    end

    test "from_json is total: missing required truncated field is an error" do
      assert {:error, {:missing_field, "truncated"}} =
               TerminalOutputResponse.from_json(%{"output" => "x"})
    end
  end

  describe "ReleaseTerminalRequest / ReleaseTerminalResponse" do
    test "request round-trip" do
      req = ReleaseTerminalRequest.new("s1", "term-1")
      json = ReleaseTerminalRequest.to_json(req)
      assert {:ok, decoded} = ReleaseTerminalRequest.from_json(json)
      assert decoded == req
    end

    test "response round-trip" do
      resp = ReleaseTerminalResponse.new()

      assert {:ok, %ReleaseTerminalResponse{}} =
               ReleaseTerminalResponse.from_json(ReleaseTerminalResponse.to_json(resp))
    end
  end

  describe "WaitForTerminalExitRequest / WaitForTerminalExitResponse" do
    test "request round-trip" do
      req = WaitForTerminalExitRequest.new("s1", "term-1")
      json = WaitForTerminalExitRequest.to_json(req)
      assert {:ok, decoded} = WaitForTerminalExitRequest.from_json(json)
      assert decoded == req
    end

    test "response is flattened, not nested under exitStatus (fixed defect vs. upstream)" do
      resp = WaitForTerminalExitResponse.new(0, nil)
      json = WaitForTerminalExitResponse.to_json(resp)
      assert json["exitCode"] == 0
      refute Map.has_key?(json, "exitStatus")

      assert {:ok, decoded} = WaitForTerminalExitResponse.from_json(json)
      assert decoded.exit_code == 0
    end
  end

  describe "KillTerminalRequest / KillTerminalResponse (renamed vs. upstream KillTerminalCommand*)" do
    test "request round-trip" do
      req = KillTerminalRequest.new("s1", "term-1")
      json = KillTerminalRequest.to_json(req)
      assert {:ok, decoded} = KillTerminalRequest.from_json(json)
      assert decoded == req
    end

    test "response round-trip" do
      resp = KillTerminalResponse.new()

      assert {:ok, %KillTerminalResponse{}} =
               KillTerminalResponse.from_json(KillTerminalResponse.to_json(resp))
    end
  end

  describe "Jason.Encoder" do
    test "structs encode without crashing" do
      assert {:ok, _} = Jason.encode(WriteTextFileRequest.new("s1", "/x", "y"))
      assert {:ok, _} = Jason.encode(TerminalExitStatus.new(0, "SIGKILL"))
      assert {:ok, _} = Jason.encode(TerminalOutputResponse.new("out", false))

      tool_call = ToolCallUpdate.new("tc-1", ToolCallUpdateFields.new())
      req = RequestPermissionRequest.new("s1", tool_call, [])
      assert {:ok, _} = Jason.encode(req)
    end
  end
end
