# Ported/adapted from the MIT `f1729/agent_client_protocol` test suite
# (c) 2025 f1729; see NOTICE.md ("SessionUpdate plan", "SessionUpdate
# current_mode_update", "AvailableCommand to_json/from_json" in
# `test/acp/client_types_test.exs`). Adapted: module names restructured
# under `Raxol.AgentClientProtocol.Schema.*`; assertions updated for the
# total `from_json/1` contract (`{:ok, t} | {:error, reason}`, never a
# bare/raising match). The upstream "SessionNotification to_json/from_json"
# test is NOT ported here: `ACP.SessionNotification` (the envelope wrapping
# a `SessionUpdate` with `sessionId`/`_meta`) belongs to whichever coder
# ports `client_types.ex` -- see `SessionUpdate`'s moduledoc.
#
# New coverage (not in upstream): a discriminator round-trip test for every
# one of the eleven variants (including `usage_update`, the oracle's 11th
# variant absent from f1729), `"sessionUpdate"` non-leakage into a variant
# payload's `_meta`, totality assertions for unrecognized/missing
# discriminators and non-map input, and `ContentChunk.messageId` /
# `UsageUpdate` / `Cost` coverage (all closing oracle-vs-f1729 gaps, none
# ported from upstream).
defmodule Raxol.AgentClientProtocol.Schema.SessionUpdateTest do
  use ExUnit.Case, async: true

  alias Raxol.AgentClientProtocol.Schema.AvailableCommand
  alias Raxol.AgentClientProtocol.Schema.AvailableCommandInput
  alias Raxol.AgentClientProtocol.Schema.AvailableCommandsUpdate
  alias Raxol.AgentClientProtocol.Schema.ContentBlock
  alias Raxol.AgentClientProtocol.Schema.ContentChunk
  alias Raxol.AgentClientProtocol.Schema.Cost
  alias Raxol.AgentClientProtocol.Schema.CurrentModeUpdate
  alias Raxol.AgentClientProtocol.Schema.Plan
  alias Raxol.AgentClientProtocol.Schema.PlanEntry
  alias Raxol.AgentClientProtocol.Schema.SessionUpdate
  alias Raxol.AgentClientProtocol.Schema.TextContent
  alias Raxol.AgentClientProtocol.Schema.ToolCall
  alias Raxol.AgentClientProtocol.Schema.ToolCallUpdate
  alias Raxol.AgentClientProtocol.Schema.ToolCallUpdateFields
  alias Raxol.AgentClientProtocol.Schema.Unstable.ConfigOptionUpdate
  alias Raxol.AgentClientProtocol.Schema.Unstable.SessionConfigOption
  alias Raxol.AgentClientProtocol.Schema.Unstable.SessionInfoUpdate
  alias Raxol.AgentClientProtocol.Schema.UnstructuredCommandInput
  alias Raxol.AgentClientProtocol.Schema.UsageUpdate

  # -- Upstream fixtures, adapted -------------------------------------------

  describe "SessionUpdate plan (upstream fixture)" do
    test "to_json tags the payload with the sessionUpdate discriminator" do
      plan = Plan.new([PlanEntry.new("Do thing", :high, :pending)])
      update = {:plan, plan}
      json = SessionUpdate.to_json(update)
      assert json["sessionUpdate"] == "plan"
      assert length(json["entries"]) == 1
    end
  end

  describe "SessionUpdate current_mode_update (upstream fixture)" do
    test "to_json tags the payload with the sessionUpdate discriminator" do
      cmu = CurrentModeUpdate.new("architect")
      json = SessionUpdate.to_json({:current_mode_update, cmu})
      assert json["sessionUpdate"] == "current_mode_update"
      assert json["currentModeId"] == "architect"
    end
  end

  describe "AvailableCommand (upstream fixture)" do
    test "to_json/from_json" do
      cmd = AvailableCommand.new("commit", "Commit changes")
      json = AvailableCommand.to_json(cmd)
      assert json["name"] == "commit"

      assert {:ok, decoded} = AvailableCommand.from_json(json)
      assert decoded.description == "Commit changes"
    end
  end

  # -- Discriminator round trip, every variant ------------------------------

  defp chunk_fixture, do: ContentChunk.new(ContentBlock.text(TextContent.new("hi there")))

  defp tool_call_fixture, do: ToolCall.new("tc-1", "Read file")

  defp tool_call_update_fixture,
    do: ToolCallUpdate.new("tc-1", %ToolCallUpdateFields{title: "Reading file"})

  defp plan_fixture, do: Plan.new([PlanEntry.new("Do thing", :high, :pending)])

  defp available_commands_update_fixture do
    AvailableCommandsUpdate.new([
      %AvailableCommand{
        name: "commit",
        description: "Commit changes",
        input: {:unstructured, UnstructuredCommandInput.new("commit message")}
      }
    ])
  end

  defp current_mode_update_fixture, do: CurrentModeUpdate.new("architect")

  defp config_option_update_fixture do
    ConfigOptionUpdate.new([SessionConfigOption.select("m", "Model", "v1", {:ungrouped, []})])
  end

  defp session_info_update_fixture, do: %SessionInfoUpdate{title: {:value, "My Session"}}

  defp usage_update_fixture, do: UsageUpdate.new(120, 1000, Cost.new(0.05, "USD"))

  describe "discriminator round trip, every variant" do
    test "user_message_chunk" do
      assert_round_trips(:user_message_chunk, chunk_fixture())
    end

    test "agent_message_chunk" do
      assert_round_trips(:agent_message_chunk, chunk_fixture())
    end

    test "agent_thought_chunk" do
      assert_round_trips(:agent_thought_chunk, chunk_fixture())
    end

    test "tool_call" do
      assert_round_trips(:tool_call, tool_call_fixture())
    end

    test "tool_call_update" do
      assert_round_trips(:tool_call_update, tool_call_update_fixture())
    end

    test "plan" do
      assert_round_trips(:plan, plan_fixture())
    end

    test "available_commands_update" do
      assert_round_trips(:available_commands_update, available_commands_update_fixture())
    end

    test "current_mode_update" do
      assert_round_trips(:current_mode_update, current_mode_update_fixture())
    end

    test "config_option_update" do
      assert_round_trips(:config_option_update, config_option_update_fixture())
    end

    test "session_info_update" do
      assert_round_trips(:session_info_update, session_info_update_fixture())
    end

    test "usage_update" do
      assert_round_trips(:usage_update, usage_update_fixture())
    end
  end

  defp assert_round_trips(tag, payload) do
    update = {tag, payload}
    wire = update |> SessionUpdate.to_json() |> Jason.encode!() |> Jason.decode!()
    assert wire["sessionUpdate"] == Atom.to_string(tag)

    assert {:ok, decoded} = SessionUpdate.from_json(wire)
    assert decoded == update
  end

  # -- "sessionUpdate" non-leakage into payload _meta -----------------------

  describe "\"sessionUpdate\" discriminator does not leak into the payload's _meta" do
    test "current_mode_update" do
      wire = %{"sessionUpdate" => "current_mode_update", "currentModeId" => "architect"}
      assert {:ok, {:current_mode_update, cmu}} = SessionUpdate.from_json(wire)
      assert cmu._meta == %{}
    end

    test "plan" do
      wire = %{"sessionUpdate" => "plan", "entries" => []}
      assert {:ok, {:plan, plan}} = SessionUpdate.from_json(wire)
      assert plan._meta == %{}
    end
  end

  # -- Totality --------------------------------------------------------------

  describe "from_json/1 is total" do
    test "unrecognized sessionUpdate value returns a descriptive error, never raises" do
      assert {:error, {:invalid_session_update_variant, "bogus"}} =
               SessionUpdate.from_json(%{"sessionUpdate" => "bogus"})
    end

    test "a map with no sessionUpdate key at all returns a descriptive error" do
      assert {:error, {:missing_field, "sessionUpdate"}} = SessionUpdate.from_json(%{})
    end

    test "a non-map argument returns a descriptive error, never raises" do
      assert {:error, {:invalid_session_update, "nope"}} = SessionUpdate.from_json("nope")
      assert {:error, {:invalid_session_update, nil}} = SessionUpdate.from_json(nil)
    end

    test "a malformed variant payload propagates the payload's own error" do
      assert {:error, {:missing_field, "content"}} =
               SessionUpdate.from_json(%{"sessionUpdate" => "agent_message_chunk"})
    end
  end

  # -- ContentChunk ------------------------------------------------------------

  describe "ContentChunk" do
    test "to_json/from_json round trip" do
      chunk = ContentChunk.new(ContentBlock.text(TextContent.new("hello")))
      json = ContentChunk.to_json(chunk)
      assert json["content"] == %{"type" => "text", "text" => "hello"}

      assert {:ok, decoded} = ContentChunk.from_json(json)
      assert decoded == chunk
    end

    test "from_json/1 is total: missing content never raises" do
      assert {:error, {:missing_field, "content"}} = ContentChunk.from_json(%{})
      assert {:error, {:invalid_content_chunk, "nope"}} = ContentChunk.from_json("nope")
    end

    test "_meta pass-through: unknown wire keys fold in, explicit _meta merges, re-emits nested" do
      wire = %{
        "content" => %{"type" => "text", "text" => "hi"},
        "vendorX" => "y",
        "_meta" => %{"z" => 1}
      }

      assert {:ok, decoded} = ContentChunk.from_json(wire)
      assert decoded._meta == %{"vendorX" => "y", "z" => 1}

      reencoded = ContentChunk.to_json(decoded)
      assert reencoded["_meta"] == %{"vendorX" => "y", "z" => 1}
    end

    test "messageId round trip (oracle gap closed)" do
      chunk = ContentChunk.new(ContentBlock.text(TextContent.new("hello")), "msg-1")
      json = ContentChunk.to_json(chunk)
      assert json["messageId"] == "msg-1"

      assert {:ok, decoded} = ContentChunk.from_json(json)
      assert decoded == chunk
      assert decoded.message_id == "msg-1"
    end

    test "messageId is absent-safe: omitted on encode when nil, nil on decode when absent" do
      chunk = ContentChunk.new(ContentBlock.text(TextContent.new("hello")))
      json = ContentChunk.to_json(chunk)
      refute Map.has_key?(json, "messageId")

      assert {:ok, decoded} = ContentChunk.from_json(json)
      assert decoded.message_id == nil
    end

    test "a non-string messageId defaults to nil rather than failing the whole object" do
      wire = %{"content" => %{"type" => "text", "text" => "hi"}, "messageId" => 42}
      assert {:ok, decoded} = ContentChunk.from_json(wire)
      assert decoded.message_id == nil
    end
  end

  # -- UsageUpdate (oracle's 11th SessionUpdate variant) ------------------------

  describe "UsageUpdate" do
    test "to_json/from_json round trip with cost" do
      usage = UsageUpdate.new(120, 1000, Cost.new(0.05, "USD"))
      json = UsageUpdate.to_json(usage)

      assert json == %{
               "used" => 120,
               "size" => 1000,
               "cost" => %{"amount" => 0.05, "currency" => "USD"}
             }

      assert {:ok, decoded} = UsageUpdate.from_json(json)
      assert decoded == usage
    end

    test "cost is optional: omitted on encode, nil on decode when absent" do
      usage = UsageUpdate.new(0, 1000)
      json = UsageUpdate.to_json(usage)
      refute Map.has_key?(json, "cost")

      assert {:ok, decoded} = UsageUpdate.from_json(json)
      assert decoded.cost == nil
    end

    test "from_json/1 is total: missing used/size never raises" do
      assert {:error, {:missing_field, "used"}} = UsageUpdate.from_json(%{"size" => 10})
      assert {:error, {:missing_field, "size"}} = UsageUpdate.from_json(%{"used" => 10})
      assert {:error, {:invalid_usage_update, "nope"}} = UsageUpdate.from_json("nope")
    end

    test "a negative used/size is invalid (non-negative integer required)" do
      assert {:error, {:invalid_field, "used", -1}} =
               UsageUpdate.from_json(%{"used" => -1, "size" => 10})
    end

    test "an unparseable cost defaults to nil rather than failing the whole object" do
      assert {:ok, decoded} =
               UsageUpdate.from_json(%{"used" => 1, "size" => 10, "cost" => "nope"})

      assert decoded.cost == nil
    end
  end

  describe "Cost" do
    test "to_json/from_json round trip" do
      cost = Cost.new(1.5, "EUR")
      json = Cost.to_json(cost)
      assert json == %{"amount" => 1.5, "currency" => "EUR"}

      assert {:ok, decoded} = Cost.from_json(json)
      assert decoded == cost
    end

    test "from_json/1 is total: missing amount/currency never raises" do
      assert {:error, {:missing_field, "amount"}} = Cost.from_json(%{"currency" => "USD"})
      assert {:error, {:missing_field, "currency"}} = Cost.from_json(%{"amount" => 1})
      assert {:error, {:invalid_cost, "nope"}} = Cost.from_json("nope")
    end
  end

  # -- CurrentModeUpdate --------------------------------------------------------

  describe "CurrentModeUpdate" do
    test "to_json/from_json round trip" do
      cmu = CurrentModeUpdate.new("code")
      json = CurrentModeUpdate.to_json(cmu)
      assert json == %{"currentModeId" => "code"}

      assert {:ok, decoded} = CurrentModeUpdate.from_json(json)
      assert decoded.current_mode_id == "code"
    end

    test "from_json/1 is total: missing currentModeId never raises" do
      assert {:error, {:missing_field, "currentModeId"}} = CurrentModeUpdate.from_json(%{})
      assert {:error, {:invalid_current_mode_update, nil}} = CurrentModeUpdate.from_json(nil)
    end
  end

  # -- AvailableCommandsUpdate / AvailableCommand / AvailableCommandInput ------

  describe "AvailableCommandsUpdate" do
    test "to_json/from_json round trip with a nested command" do
      update =
        AvailableCommandsUpdate.new([
          %AvailableCommand{name: "commit", description: "Commit changes"}
        ])

      json = AvailableCommandsUpdate.to_json(update)
      assert length(json["availableCommands"]) == 1

      assert {:ok, decoded} = AvailableCommandsUpdate.from_json(json)
      assert decoded == update
    end

    test "from_json/1 is total: a missing/wrong-typed list defaults to [], never raises" do
      assert {:ok, %AvailableCommandsUpdate{available_commands: []}} =
               AvailableCommandsUpdate.from_json(%{})

      assert {:ok, %AvailableCommandsUpdate{available_commands: []}} =
               AvailableCommandsUpdate.from_json("nope")
    end

    test "items that individually fail to decode are skipped, not aborted" do
      assert {:ok, %AvailableCommandsUpdate{available_commands: [cmd]}} =
               AvailableCommandsUpdate.from_json(%{
                 "availableCommands" => [
                   %{"name" => "commit", "description" => "Commit changes"},
                   %{"name" => "missing-description"}
                 ]
               })

      assert cmd.name == "commit"
    end
  end

  describe "AvailableCommandInput" do
    test "unstructured with an explicit hint" do
      assert {:ok, {:unstructured, %UnstructuredCommandInput{hint: "message"}}} =
               AvailableCommandInput.from_json(%{"hint" => "message"})

      assert AvailableCommandInput.to_json({:unstructured, UnstructuredCommandInput.new("h")}) ==
               %{"hint" => "h"}
    end

    test "a map without hint still decodes as unstructured with an empty hint (matches upstream fallback)" do
      assert {:ok, {:unstructured, %UnstructuredCommandInput{hint: ""}}} =
               AvailableCommandInput.from_json(%{})
    end

    test "from_json/1 is total: a non-map argument returns a descriptive error" do
      assert {:error, {:invalid_available_command_input, "nope"}} =
               AvailableCommandInput.from_json("nope")
    end
  end

  describe "UnstructuredCommandInput" do
    test "to_json/from_json round trip" do
      input = UnstructuredCommandInput.new("do the thing")
      json = UnstructuredCommandInput.to_json(input)
      assert json == %{"hint" => "do the thing"}

      assert {:ok, decoded} = UnstructuredCommandInput.from_json(json)
      assert decoded == input
    end

    test "from_json/1 is total: missing hint never raises" do
      assert {:error, {:missing_field, "hint"}} = UnstructuredCommandInput.from_json(%{})
    end
  end
end
