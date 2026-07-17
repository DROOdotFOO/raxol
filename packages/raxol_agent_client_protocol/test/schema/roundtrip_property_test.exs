# New coverage (W8): StreamData round-trip properties for the ACP schema
# layer, complementing the byte-fixed fixtures ported into
# `test/schema/serialization_test.exs` from the MIT
# `f1729/agent_client_protocol` test suite (c) 2025 f1729; see NOTICE.md.
# Upstream has no dedicated property-test file; the generators and
# properties below are new, written against this port's actual structs.
#
# Coverage: `ContentBlock` (every variant, unicode text), `ToolCall`, `Plan`,
# `ClientCapabilities`/`AgentCapabilities` trees, and `Rpc.Request`/
# `Response`/`Notification` across the `RequestId` type matrix (int/string/
# null), plus the reverse "unknown wire keys survive `_meta` pass-through"
# property in both directions this package actually implements (nested
# under `"_meta"` for `WireFields`-based structs; flat merge for the
# JSON-RPC envelope layer in `rpc.ex`).
#
# NOT covered: the `session/update` notification's `sessionUpdate`-tagged
# union (`ACP.SessionUpdate` upstream). That type is not yet ported anywhere
# in this package -- see the header comment on
# `lib/raxol/agent_client_protocol/schema/agent_types.ex` ("intentionally
# NOT ported here... belongs to whichever coder ports client_types.ex") and
# confirm no `SessionUpdate` module exists under `lib/`. Nothing to write a
# property against yet.
#
# `AgentTypes.*` capability structs (PromptCapabilities/McpCapabilities/
# SessionCapabilities/AgentCapabilities) now generate non-empty `_meta` too:
# the `AgentTypes.put_meta/2` flattening bug that used to make this
# unsound (documented, now fixed, in `serialization_test.exs`'s "meta field
# uses _meta key" test) no longer applies.
defmodule Raxol.AgentClientProtocol.Schema.RoundtripPropertyTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Raxol.AgentClientProtocol.Error
  alias Raxol.AgentClientProtocol.Rpc.{Notification, Request, RequestId, Response}

  alias Raxol.AgentClientProtocol.Schema.{
    Annotations,
    AudioContent,
    BlobResourceContents,
    ContentBlock,
    Diff,
    EmbeddedResource,
    ImageContent,
    Plan,
    PlanEntry,
    ResourceLink,
    Role,
    TextContent,
    TextResourceContents,
    ToolCall,
    ToolCallContent,
    ToolCallContentWrapper,
    ToolCallLocation,
    ToolCallTerminal
  }

  alias Raxol.AgentClientProtocol.Schema.AgentTypes.{
    AgentCapabilities,
    McpCapabilities,
    PromptCapabilities,
    SessionCapabilities
  }

  alias Raxol.AgentClientProtocol.Schema.ClientTypes.{ClientCapabilities, FileSystemCapability}

  # -- Shared generators -------------------------------------------------------

  defp unicode_string_gen(max_length) do
    string(:utf8, max_length: max_length)
  end

  defp json_scalar_gen do
    one_of([
      constant(nil),
      boolean(),
      integer(),
      unicode_string_gen(20)
    ])
  end

  # Unknown wire keys, guaranteed not to collide with any field this schema
  # layer actually recognizes (every recognized field is `camelCase` with no
  # underscore; these are deliberately snake_and_prefixed to stay clear).
  defp unknown_key_gen do
    map(string(:alphanumeric, min_length: 1, max_length: 8), &("vendor_" <> &1))
  end

  defp extra_fields_gen do
    map(
      list_of(tuple({unknown_key_gen(), json_scalar_gen()}), min_length: 1, max_length: 4),
      &Map.new/1
    )
  end

  # -- ContentBlock --------------------------------------------------------

  defp role_gen, do: member_of([:assistant, :user])

  defp annotations_gen do
    gen all(
          audience <- one_of([constant(nil), list_of(role_gen(), max_length: 3)]),
          last_modified <-
            one_of([constant(nil), string(:alphanumeric, min_length: 1, max_length: 20)]),
          priority <- one_of([constant(nil), float(min: 0.0, max: 1.0)])
        ) do
      %Annotations{audience: audience, last_modified: last_modified, priority: priority}
    end
  end

  defp maybe_annotations_gen, do: one_of([constant(nil), annotations_gen()])

  defp text_content_gen do
    gen all(text <- unicode_string_gen(80), annotations <- maybe_annotations_gen()) do
      %TextContent{text: text, annotations: annotations}
    end
  end

  defp image_content_gen do
    gen all(
          data <- string(:alphanumeric, max_length: 40),
          mime_type <- string(:alphanumeric, min_length: 1, max_length: 20),
          uri <- one_of([constant(nil), unicode_string_gen(30)]),
          annotations <- maybe_annotations_gen()
        ) do
      %ImageContent{data: data, mime_type: mime_type, uri: uri, annotations: annotations}
    end
  end

  defp audio_content_gen do
    gen all(
          data <- string(:alphanumeric, max_length: 40),
          mime_type <- string(:alphanumeric, min_length: 1, max_length: 20),
          annotations <- maybe_annotations_gen()
        ) do
      %AudioContent{data: data, mime_type: mime_type, annotations: annotations}
    end
  end

  defp text_resource_contents_gen do
    gen all(
          text <- unicode_string_gen(60),
          uri <- unicode_string_gen(30),
          mime_type <-
            one_of([constant(nil), string(:alphanumeric, min_length: 1, max_length: 20)])
        ) do
      %TextResourceContents{text: text, uri: uri, mime_type: mime_type}
    end
  end

  defp blob_resource_contents_gen do
    gen all(
          blob <- string(:alphanumeric, max_length: 60),
          uri <- unicode_string_gen(30),
          mime_type <-
            one_of([constant(nil), string(:alphanumeric, min_length: 1, max_length: 20)])
        ) do
      %BlobResourceContents{blob: blob, uri: uri, mime_type: mime_type}
    end
  end

  defp embedded_resource_resource_gen do
    one_of([text_resource_contents_gen(), blob_resource_contents_gen()])
  end

  defp embedded_resource_gen do
    gen all(resource <- embedded_resource_resource_gen(), annotations <- maybe_annotations_gen()) do
      %EmbeddedResource{resource: resource, annotations: annotations}
    end
  end

  defp resource_link_gen do
    gen all(
          name <- unicode_string_gen(30),
          uri <- unicode_string_gen(30),
          description <- one_of([constant(nil), unicode_string_gen(40)]),
          mime_type <-
            one_of([constant(nil), string(:alphanumeric, min_length: 1, max_length: 20)]),
          size <- one_of([constant(nil), integer(0..1_000_000)]),
          title <- one_of([constant(nil), unicode_string_gen(30)]),
          annotations <- maybe_annotations_gen()
        ) do
      %ResourceLink{
        name: name,
        uri: uri,
        description: description,
        mime_type: mime_type,
        size: size,
        title: title,
        annotations: annotations
      }
    end
  end

  defp content_block_gen do
    one_of([
      map(text_content_gen(), &ContentBlock.text/1),
      map(image_content_gen(), &ContentBlock.image/1),
      map(audio_content_gen(), &ContentBlock.audio/1),
      map(resource_link_gen(), &ContentBlock.resource_link/1),
      map(embedded_resource_gen(), &ContentBlock.resource/1)
    ])
  end

  describe "Role" do
    property "encode/decode round-trips for every variant" do
      check all(role <- role_gen(), max_runs: 10) do
        assert Role.decode(Role.encode(role)) == {:ok, role}
      end
    end
  end

  describe "ContentBlock" do
    property "to_json/from_json round-trips for every variant, including unicode text" do
      check all(block <- content_block_gen(), max_runs: 60) do
        wire = block |> ContentBlock.to_json() |> Jason.encode!() |> Jason.decode!()

        assert {:ok, decoded} = ContentBlock.from_json(wire)
        assert decoded == block
      end
    end
  end

  # -- ToolCall --------------------------------------------------------------

  defp tool_kind_gen do
    member_of([
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
    ])
  end

  defp tool_call_status_gen, do: member_of([:pending, :in_progress, :completed, :failed])

  defp tool_call_location_gen do
    gen all(path <- unicode_string_gen(40), line <- one_of([constant(nil), integer(0..10_000)])) do
      %ToolCallLocation{path: path, line: line}
    end
  end

  defp diff_gen do
    gen all(
          path <- unicode_string_gen(40),
          new_text <- unicode_string_gen(100),
          old_text <- one_of([constant(nil), unicode_string_gen(100)])
        ) do
      %Diff{path: path, new_text: new_text, old_text: old_text}
    end
  end

  defp tool_call_terminal_gen do
    gen all(terminal_id <- string(:alphanumeric, min_length: 1, max_length: 20)) do
      %ToolCallTerminal{terminal_id: terminal_id}
    end
  end

  defp tool_call_content_gen do
    one_of([
      map(content_block_gen(), fn block ->
        ToolCallContent.content(%ToolCallContentWrapper{content: block})
      end),
      map(diff_gen(), &ToolCallContent.diff/1),
      map(tool_call_terminal_gen(), &ToolCallContent.terminal/1)
    ])
  end

  defp tool_call_gen do
    gen all(
          tool_call_id <- string(:alphanumeric, min_length: 1, max_length: 20),
          title <- unicode_string_gen(40),
          kind <- tool_kind_gen(),
          status <- tool_call_status_gen(),
          content <- list_of(tool_call_content_gen(), max_length: 3),
          locations <- list_of(tool_call_location_gen(), max_length: 3),
          raw_input <- json_scalar_gen(),
          raw_output <- json_scalar_gen()
        ) do
      %ToolCall{
        tool_call_id: tool_call_id,
        title: title,
        kind: kind,
        status: status,
        content: content,
        locations: locations,
        raw_input: raw_input,
        raw_output: raw_output
      }
    end
  end

  describe "ToolCall" do
    property "to_json/from_json round-trips, including default kind/status omission" do
      check all(tc <- tool_call_gen(), max_runs: 40) do
        wire = tc |> ToolCall.to_json() |> Jason.encode!() |> Jason.decode!()

        assert {:ok, decoded} = ToolCall.from_json(wire)
        assert decoded == tc
      end
    end
  end

  # -- Plan --------------------------------------------------------------------

  defp plan_priority_gen, do: member_of([:high, :medium, :low])
  defp plan_status_gen, do: member_of([:pending, :in_progress, :completed])

  defp plan_entry_gen do
    gen all(
          content <- unicode_string_gen(60),
          priority <- plan_priority_gen(),
          status <- plan_status_gen()
        ) do
      %PlanEntry{content: content, priority: priority, status: status}
    end
  end

  defp plan_gen do
    gen all(entries <- list_of(plan_entry_gen(), max_length: 6)) do
      %Plan{entries: entries}
    end
  end

  describe "Plan" do
    property "to_json/from_json round-trips for an arbitrary entry list" do
      check all(plan <- plan_gen(), max_runs: 30) do
        wire = plan |> Plan.to_json() |> Jason.encode!() |> Jason.decode!()

        assert {:ok, decoded} = Plan.from_json(wire)
        assert decoded == plan
      end
    end
  end

  # -- ClientCapabilities / AgentCapabilities trees ---------------------------

  defp file_system_capability_gen do
    gen all(write_text_file <- boolean(), read_text_file <- boolean()) do
      %FileSystemCapability{write_text_file: write_text_file, read_text_file: read_text_file}
    end
  end

  defp client_capabilities_gen do
    gen all(
          terminal <- boolean(),
          file_system <- one_of([constant(nil), file_system_capability_gen()])
        ) do
      %ClientCapabilities{terminal: terminal, file_system: file_system}
    end
  end

  describe "ClientCapabilities" do
    property "tree round-trips through to_json/from_json" do
      check all(cc <- client_capabilities_gen(), max_runs: 30) do
        json = ClientCapabilities.to_json(cc)
        assert {:ok, decoded} = ClientCapabilities.from_json(json)
        assert decoded == cc
      end
    end
  end

  defp prompt_capabilities_gen do
    gen all(
          image <- boolean(),
          audio <- boolean(),
          embedded_context <- boolean(),
          meta <- extra_fields_gen()
        ) do
      %PromptCapabilities{
        image: image,
        audio: audio,
        embedded_context: embedded_context,
        _meta: meta
      }
    end
  end

  defp mcp_capabilities_gen do
    gen all(http <- boolean(), sse <- boolean(), meta <- extra_fields_gen()) do
      %McpCapabilities{http: http, sse: sse, _meta: meta}
    end
  end

  defp session_capabilities_gen do
    gen all(modes <- boolean(), meta <- extra_fields_gen()) do
      %SessionCapabilities{modes: modes, _meta: meta}
    end
  end

  defp agent_capabilities_gen do
    gen all(
          load_session <- boolean(),
          prompt <- one_of([constant(nil), prompt_capabilities_gen()]),
          mcp <- one_of([constant(nil), mcp_capabilities_gen()]),
          session <- one_of([constant(nil), session_capabilities_gen()]),
          meta <- extra_fields_gen()
        ) do
      %AgentCapabilities{
        load_session: load_session,
        prompt_capabilities: prompt,
        mcp_capabilities: mcp,
        session_capabilities: session,
        _meta: meta
      }
    end
  end

  describe "AgentCapabilities" do
    property "tree round-trips through to_json/from_json, including non-empty _meta at every level" do
      check all(ac <- agent_capabilities_gen(), max_runs: 30) do
        json = AgentCapabilities.to_json(ac)
        assert {:ok, decoded} = AgentCapabilities.from_json(json)
        assert decoded == ac
      end
    end
  end

  # -- Rpc Request/Response/Notification, id-type matrix ----------------------

  defp request_id_gen do
    one_of([constant(nil), integer(), string(:alphanumeric, min_length: 1, max_length: 12)])
  end

  describe "Rpc.Request" do
    property "round-trips for every RequestId shape (int/string/null)" do
      check all(
              id <- request_id_gen(),
              method <- string(:alphanumeric, min_length: 1, max_length: 20),
              params <- one_of([constant(nil), json_scalar_gen()]),
              meta <- extra_fields_gen(),
              max_runs: 40
            ) do
        req = %Request{id: id, method: method, params: params, _meta: meta}
        wire = req |> Request.to_json() |> Jason.encode!() |> Jason.decode!()

        assert {:ok, decoded} = Request.from_json(wire)
        assert decoded.id == id
        assert decoded.method == method
        assert decoded.params == params
        assert decoded._meta == meta
      end
    end

    property "unknown top-level wire keys survive to_json byte-faithfully (flat, not nested)" do
      check all(
              id <- request_id_gen(),
              method <- string(:alphanumeric, min_length: 1, max_length: 20),
              extra <- extra_fields_gen(),
              max_runs: 30
            ) do
        wire = Map.merge(%{"id" => RequestId.to_json(id), "method" => method}, extra)

        assert {:ok, decoded} = Request.from_json(wire)
        reencoded = Request.to_json(decoded)

        assert reencoded["id"] == RequestId.to_json(id)
        assert reencoded["method"] == method

        for {key, value} <- extra do
          assert reencoded[key] == value
        end
      end
    end
  end

  describe "Rpc.Response" do
    property "round-trips for every RequestId shape, both result and error variants" do
      check all(
              id <- request_id_gen(),
              which <- member_of([:result, :error]),
              result <- json_scalar_gen(),
              code <- integer(),
              message <- unicode_string_gen(30),
              max_runs: 40
            ) do
        resp =
          case which do
            :result -> Response.result(id, result)
            :error -> Response.error(id, Error.new(code, message))
          end

        wire = resp |> Response.to_json() |> Jason.encode!() |> Jason.decode!()

        assert {:ok, decoded} = Response.from_json(wire)

        case which do
          :result ->
            assert {:result, ^id, ^result} = decoded

          :error ->
            assert {:error, ^id, %Error{code: ^code, message: ^message}} = decoded
        end
      end
    end
  end

  describe "Rpc.Notification" do
    property "round-trips across id-less notification shapes" do
      check all(
              method <- string(:alphanumeric, min_length: 1, max_length: 20),
              params <- one_of([constant(nil), json_scalar_gen()]),
              meta <- extra_fields_gen(),
              max_runs: 30
            ) do
        notif = %Notification{method: method, params: params, _meta: meta}
        wire = notif |> Notification.to_json() |> Jason.encode!() |> Jason.decode!()

        assert {:ok, decoded} = Notification.from_json(wire)
        assert decoded.method == method
        assert decoded.params == params
        assert decoded._meta == meta
      end
    end
  end

  # -- _meta / unknown-key pass-through (WireFields-based nesting) -----------

  describe "TextContent _meta pass-through" do
    property "unknown top-level wire keys fold into _meta and re-emit nested under \"_meta\"" do
      check all(text <- unicode_string_gen(30), extra <- extra_fields_gen(), max_runs: 30) do
        wire = Map.merge(%{"text" => text}, extra)

        assert {:ok, decoded} = TextContent.from_json(wire)
        reencoded = TextContent.to_json(decoded)

        assert reencoded["text"] == text
        assert reencoded["_meta"] == extra
      end
    end

    property "an explicit wire _meta object survives to_json byte-faithfully" do
      check all(text <- unicode_string_gen(30), extra <- extra_fields_gen(), max_runs: 30) do
        wire = %{"text" => text, "_meta" => extra}

        assert {:ok, decoded} = TextContent.from_json(wire)
        reencoded = TextContent.to_json(decoded)

        assert reencoded["text"] == text
        assert reencoded["_meta"] == extra
      end
    end
  end
end
