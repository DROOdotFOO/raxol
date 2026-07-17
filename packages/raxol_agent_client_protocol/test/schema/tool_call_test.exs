# Ported (as new coverage; upstream had no dedicated tool_call test file)
# from the conventions of the MIT `f1729/agent_client_protocol` test suite
# (c) 2025 f1729; see NOTICE.md. Targets
# Raxol.AgentClientProtocol.Schema.{ToolKind,ToolCallStatus,
# ToolCallLocation,Diff,ToolCallTerminal,ToolCallContentWrapper,
# ToolCallContent,ToolCallUpdateFields,ToolCallUpdate,ToolCall}.
defmodule Raxol.AgentClientProtocol.Schema.ToolCallTest do
  use ExUnit.Case, async: true

  alias Raxol.AgentClientProtocol.Schema.ContentBlock
  alias Raxol.AgentClientProtocol.Schema.Diff
  alias Raxol.AgentClientProtocol.Schema.TextContent
  alias Raxol.AgentClientProtocol.Schema.ToolCall
  alias Raxol.AgentClientProtocol.Schema.ToolCallContent
  alias Raxol.AgentClientProtocol.Schema.ToolCallContentWrapper
  alias Raxol.AgentClientProtocol.Schema.ToolCallLocation
  alias Raxol.AgentClientProtocol.Schema.ToolCallStatus
  alias Raxol.AgentClientProtocol.Schema.ToolCallTerminal
  alias Raxol.AgentClientProtocol.Schema.ToolCallUpdate
  alias Raxol.AgentClientProtocol.Schema.ToolCallUpdateFields
  alias Raxol.AgentClientProtocol.Schema.ToolKind

  describe "ToolKind" do
    test "encode/decode round trip for every known variant" do
      for kind <- [
            :read,
            :edit,
            :delete,
            :move,
            :search,
            :execute,
            :think,
            :fetch,
            :switch_mode,
            :other
          ] do
        assert ToolKind.decode(ToolKind.encode(kind)) == kind
      end
    end

    test "decode/1 is total and infallible: unrecognized values default to :other (the documented default)" do
      assert ToolKind.decode("teleport") == :other
      assert ToolKind.decode(nil) == :other
      assert ToolKind.decode(42) == :other
    end

    test "default/0 and default?/1" do
      assert ToolKind.default() == :other
      assert ToolKind.default?(:other)
      refute ToolKind.default?(:read)
    end
  end

  describe "ToolCallStatus" do
    test "encode/decode round trip for every known variant" do
      for status <- [:pending, :in_progress, :completed, :failed] do
        assert ToolCallStatus.decode(ToolCallStatus.encode(status)) == status
      end
    end

    test "decode/1 is total and infallible: unrecognized values default to :pending (schema-documented default-on-error)" do
      assert ToolCallStatus.decode("cancelled") == :pending
      assert ToolCallStatus.decode(nil) == :pending
      assert ToolCallStatus.decode(42) == :pending
    end
  end

  describe "ToolCallLocation" do
    test "new/1, to_json/from_json round trip" do
      loc = ToolCallLocation.new("/tmp/a.txt")
      json = ToolCallLocation.to_json(loc)
      assert json == %{"path" => "/tmp/a.txt"}

      assert {:ok, %ToolCallLocation{path: "/tmp/a.txt", line: nil}} =
               ToolCallLocation.from_json(json)
    end

    test "with line" do
      loc = %ToolCallLocation{path: "/a", line: 42}

      assert {:ok, %ToolCallLocation{line: 42}} =
               loc |> ToolCallLocation.to_json() |> ToolCallLocation.from_json()
    end

    test "from_json/1 is total: missing path never raises; negative line defaults to nil" do
      assert {:error, {:missing_field, "path"}} = ToolCallLocation.from_json(%{})

      assert {:ok, %ToolCallLocation{line: nil}} =
               ToolCallLocation.from_json(%{"path" => "/a", "line" => -1})
    end
  end

  describe "Diff" do
    test "new/2, to_json/from_json round trip" do
      diff = Diff.new("/a.txt", "new content")
      json = Diff.to_json(diff)

      assert {:ok, %Diff{path: "/a.txt", new_text: "new content", old_text: nil}} =
               Diff.from_json(json)
    end

    # --- Fixed defect: oldText is omitted, never emitted as an explicit null ---

    test "to_json/1 omits oldText for a new-file diff instead of emitting null" do
      diff = Diff.new("/new.txt", "content")
      json = Diff.to_json(diff)
      refute Map.has_key?(json, "oldText")
    end

    test "to_json/1 includes oldText when present" do
      diff = %Diff{path: "/a", old_text: "before", new_text: "after"}
      json = Diff.to_json(diff)
      assert json["oldText"] == "before"
    end

    test "from_json/1 is total: missing path or newText never raises" do
      assert {:error, {:missing_field, "path"}} = Diff.from_json(%{"newText" => "x"})
      assert {:error, {:missing_field, "newText"}} = Diff.from_json(%{"path" => "/a"})
    end
  end

  describe "ToolCallTerminal" do
    test "new/1, to_json/from_json round trip" do
      t = ToolCallTerminal.new("term-1")
      json = ToolCallTerminal.to_json(t)
      assert json == %{"terminalId" => "term-1"}
      assert {:ok, %ToolCallTerminal{terminal_id: "term-1"}} = ToolCallTerminal.from_json(json)
    end

    test "from_json/1 is total: missing terminalId never raises" do
      assert {:error, {:missing_field, "terminalId"}} = ToolCallTerminal.from_json(%{})
    end
  end

  describe "ToolCallContentWrapper and ToolCallContent (tagged union)" do
    test "content variant round trip" do
      wrapper = ToolCallContentWrapper.new(ContentBlock.text(TextContent.new("hi")))
      json = ToolCallContentWrapper.to_json(wrapper)

      assert {:ok, %ToolCallContentWrapper{content: {:text, %TextContent{text: "hi"}}}} =
               ToolCallContentWrapper.from_json(json)
    end

    test "diff and terminal variants round trip through ToolCallContent" do
      diff_variant = ToolCallContent.diff(Diff.new("/a", "new"))

      assert {:ok, {:diff, %Diff{}}} =
               diff_variant |> ToolCallContent.to_json() |> ToolCallContent.from_json()

      term_variant = ToolCallContent.terminal(ToolCallTerminal.new("t1"))

      assert {:ok, {:terminal, %ToolCallTerminal{}}} =
               term_variant |> ToolCallContent.to_json() |> ToolCallContent.from_json()

      content_variant =
        ToolCallContent.content(
          ToolCallContentWrapper.new(ContentBlock.text(TextContent.new("x")))
        )

      assert {:ok, {:content, %ToolCallContentWrapper{}}} =
               content_variant |> ToolCallContent.to_json() |> ToolCallContent.from_json()
    end

    test "ToolCallContent.from_json/1 is total: unrecognized/missing type never raises" do
      assert {:error, {:unknown_tool_call_content_type, "video"}} =
               ToolCallContent.from_json(%{"type" => "video"})

      assert {:error, {:missing_field, "type"}} = ToolCallContent.from_json(%{})
      assert {:error, _} = ToolCallContent.from_json("nope")
    end
  end

  describe "ToolCallUpdateFields" do
    test "to_json/from_json round trip with every field set" do
      fields = %ToolCallUpdateFields{
        kind: :edit,
        status: :completed,
        title: "Editing",
        content: [ToolCallContent.diff(Diff.new("/a", "new"))],
        locations: [ToolCallLocation.new("/a")],
        raw_input: %{"x" => 1},
        raw_output: %{"y" => 2}
      }

      json = ToolCallUpdateFields.to_json(fields)
      assert {:ok, decoded} = ToolCallUpdateFields.from_json(json)
      assert decoded.kind == :edit
      assert decoded.status == :completed
      assert decoded.title == "Editing"
      assert length(decoded.content) == 1
      assert length(decoded.locations) == 1
      assert decoded.raw_input == %{"x" => 1}
      assert decoded.raw_output == %{"y" => 2}
    end

    test "new/0 emits an empty object (every field absent)" do
      assert ToolCallUpdateFields.to_json(ToolCallUpdateFields.new()) == %{}
    end

    # --- Total decode + full leniency (every field is optional with
    #     default-on-error / skip-invalid-items per the schema oracle) ---

    test "from_json/1 never fails for a map input, regardless of field shapes" do
      assert {:ok, %ToolCallUpdateFields{}} = ToolCallUpdateFields.from_json(%{})

      assert {:ok, fields} =
               ToolCallUpdateFields.from_json(%{
                 "kind" => "not_a_kind",
                 "status" => "not_a_status",
                 "content" => "not a list",
                 "locations" => "not a list"
               })

      assert fields.kind == :other
      assert fields.status == :pending
      assert fields.content == nil
      assert fields.locations == nil
    end

    test "from_json/1 skips content/location items that individually fail to decode" do
      raw = %{
        "content" => [
          %{"type" => "diff", "path" => "/a", "newText" => "x"},
          %{"type" => "bogus"}
        ],
        "locations" => [
          %{"path" => "/a"},
          %{"line" => 1}
        ]
      }

      assert {:ok, fields} = ToolCallUpdateFields.from_json(raw)
      assert length(fields.content) == 1
      assert length(fields.locations) == 1
    end
  end

  describe "ToolCallUpdate" do
    test "toolCallId flattens with the fields into one wire object" do
      fields = %ToolCallUpdateFields{status: :completed}
      update = ToolCallUpdate.new("tc-1", fields)
      json = ToolCallUpdate.to_json(update)
      assert json == %{"toolCallId" => "tc-1", "status" => "completed"}

      assert {:ok, decoded} = ToolCallUpdate.from_json(json)
      assert decoded.tool_call_id == "tc-1"
      assert decoded.fields.status == :completed
    end

    test "from_json/1 is total: missing toolCallId never raises" do
      assert {:error, {:missing_field, "toolCallId"}} =
               ToolCallUpdate.from_json(%{"status" => "completed"})
    end

    test "with _meta round-trips under the wire \"_meta\" key, separate from flattened fields" do
      update = %ToolCallUpdate{
        tool_call_id: "tc-1",
        fields: %ToolCallUpdateFields{},
        _meta: %{"a" => 1}
      }

      json = ToolCallUpdate.to_json(update)
      assert json["_meta"] == %{"a" => 1}
      assert {:ok, decoded} = ToolCallUpdate.from_json(json)
      assert decoded._meta == %{"a" => 1}
    end

    test "Jason.Encoder round-trips through real JSON" do
      update = ToolCallUpdate.new("tc-2", %ToolCallUpdateFields{title: "Working"})
      encoded = Jason.encode!(update)
      assert {:ok, decoded_json} = Jason.decode(encoded)
      assert {:ok, decoded} = ToolCallUpdate.from_json(decoded_json)
      assert decoded.tool_call_id == "tc-2"
      assert decoded.fields.title == "Working"
    end
  end

  describe "ToolCall" do
    test "new/2 defaults kind/status/content/locations" do
      tc = ToolCall.new("tc-1", "Reading file")
      assert tc.kind == :other
      assert tc.status == :pending
      assert tc.content == []
      assert tc.locations == []
    end

    test "to_json/1 omits default kind/status and empty content/locations" do
      tc = ToolCall.new("tc-1", "Reading file")
      json = ToolCall.to_json(tc)
      assert json == %{"toolCallId" => "tc-1", "title" => "Reading file"}
    end

    test "to_json/from_json round trip with non-default fields" do
      tc = %ToolCall{
        tool_call_id: "tc-1",
        title: "Editing file",
        kind: :edit,
        status: :in_progress,
        content: [ToolCallContent.diff(Diff.new("/a", "new"))],
        locations: [ToolCallLocation.new("/a")],
        raw_input: %{"path" => "/a"}
      }

      json = ToolCall.to_json(tc)
      assert json["kind"] == "edit"
      assert json["status"] == "in_progress"

      assert {:ok, decoded} = ToolCall.from_json(json)
      assert decoded.kind == :edit
      assert decoded.status == :in_progress
      assert length(decoded.content) == 1
      assert length(decoded.locations) == 1
      assert decoded.raw_input == %{"path" => "/a"}
    end

    test "from_json/1 is total: missing toolCallId or title never raises" do
      assert {:error, {:missing_field, "toolCallId"}} = ToolCall.from_json(%{"title" => "x"})
      assert {:error, {:missing_field, "title"}} = ToolCall.from_json(%{"toolCallId" => "x"})
      assert {:error, _} = ToolCall.from_json("not a map")
      assert {:error, _} = ToolCall.from_json(nil)
    end

    test "from_json/1 defaults an unrecognized kind/status rather than failing the whole tool call" do
      assert {:ok, %ToolCall{kind: :other, status: :pending}} =
               ToolCall.from_json(%{
                 "toolCallId" => "tc-1",
                 "title" => "x",
                 "kind" => "bogus",
                 "status" => "bogus"
               })
    end

    test "from_json/1 defaults content/locations to [] and skips invalid items" do
      raw = %{
        "toolCallId" => "tc-1",
        "title" => "x",
        "content" => [%{"type" => "bogus"}, %{"type" => "diff", "path" => "/a", "newText" => "n"}],
        "locations" => [%{"path" => "/a"}, %{"line" => 1}]
      }

      assert {:ok, decoded} = ToolCall.from_json(raw)
      assert length(decoded.content) == 1
      assert length(decoded.locations) == 1
    end

    test "update/2 overwrites only the non-nil fields present in ToolCallUpdateFields" do
      tc = ToolCall.new("tc-1", "Original title")
      fields = %ToolCallUpdateFields{status: :completed}
      updated = ToolCall.update(tc, fields)

      assert updated.status == :completed
      assert updated.title == "Original title"
      assert updated.kind == :other
    end

    test "to_update/1 projects the full current state into a ToolCallUpdate" do
      tc = %ToolCall{tool_call_id: "tc-1", title: "x", kind: :edit, status: :completed}
      update = ToolCall.to_update(tc)

      assert %ToolCallUpdate{tool_call_id: "tc-1"} = update
      assert update.fields.kind == :edit
      assert update.fields.status == :completed
      assert update.fields.title == "x"
    end

    test "with _meta round-trips under the wire \"_meta\" key" do
      tc = %ToolCall{tool_call_id: "tc-1", title: "x", _meta: %{"a" => 1}}
      json = ToolCall.to_json(tc)
      assert json["_meta"] == %{"a" => 1}
      assert {:ok, decoded} = ToolCall.from_json(json)
      assert decoded._meta == %{"a" => 1}
    end

    test "from_json/1 folds unknown wire fields into _meta" do
      assert {:ok, %ToolCall{_meta: meta}} =
               ToolCall.from_json(%{"toolCallId" => "tc-1", "title" => "x", "vendorField" => "v"})

      assert meta == %{"vendorField" => "v"}
    end

    test "Jason.Encoder round-trips through real JSON" do
      tc = ToolCall.new("tc-3", "Doing a thing")
      encoded = Jason.encode!(tc)
      assert {:ok, decoded_json} = Jason.decode(encoded)
      assert {:ok, decoded} = ToolCall.from_json(decoded_json)
      assert decoded.tool_call_id == "tc-3"
      assert decoded.title == "Doing a thing"
    end
  end

  describe "atom safety" do
    test "no ToolCall struct decode invokes String.to_atom on wire-derived data" do
      for i <- 1..50 do
        assert {:ok, _} =
                 ToolCall.from_json(%{
                   "toolCallId" => "tc-#{i}",
                   "title" => "t#{i}",
                   "kind" => "unknown_kind_#{i}",
                   "field_#{i}" => i
                 })
      end
    end
  end
end
