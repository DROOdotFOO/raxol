# Wire-level torture / skew tests for the ACP transport + schema + Connection
# stack -- NOT a port of any upstream f1729 test. Five independent stress
# axes, each its own `describe` block:
#
#   1. forward-compat skew  -- unknown fields at every schema level survive
#      decode->encode byte-faithfully via the `_meta` pass-through fold
#      (`Raxol.AgentClientProtocol.Schema.WireFields`/`AgentTypes`); unknown
#      wire methods answer `-32601` regardless of param shape; a
#      never-negotiated (higher) `protocolVersion` integer is tolerated at
#      both the schema and live-handshake layers (`Schema.Version.coerce/1`).
#   2. oversized frames -- a ~5MB multimodal (base64 image) content block
#      round-trips through the REAL byte-level `Transport.Stdio` (Framer +
#      JSON codec, not the in-process `Transport.Paired` passthrough), then
#      through `PromptRequest.from_json/1`, with no truncation.
#   3. id-type matrix -- int/string/edge-case request ids are preserved
#      byte-exact through `Connection` correlation, including two requests
#      in flight AT THE SAME TIME whose ids are the integer `1` and the
#      string `"1"` (proving no accidental `to_string`/coercion collapses
#      them onto the same `pending_in` entry).
#   4. three-state fields -- `Schema.MaybeUndefined` (absent / explicit null
#      / value) round-trips for `Schema.Unstable.SessionInfoUpdate`
#      (`session_info_update`'s `title`/`updatedAt`), plus the `_meta`
#      three-state analog (absent / empty object / populated) on
#      `SetSessionModeRequest`/`Response`.
#   5. malformed input totality -- 5000 random garbage frames (well-formed
#      maps with wrong-typed JSON-RPC fields, deeply nested junk, and
#      non-map top-level shapes) never crash a live `Connection`; the node's
#      atom table stays flat (Inv-7: no `String.to_atom/1` on wire input).
#
# Ambiguity flagged (not silently resolved): the assignment names
# "ProviderInfo.current-style" as a three-state target; no `ProviderInfo`
# struct exists in this package. `Schema.Unstable.SessionInfoUpdate` is the
# only genuine `MaybeUndefined`-typed (three-state) struct in the schema
# layer today, so it stands in as the concrete target; `set_session_mode`'s
# request/response `_meta` fold is exercised alongside it as the closest
# actual "current-style" three-state-shaped field this package has.

defmodule Raxol.AgentClientProtocol.Torture.WireTortureTest.SimpleAgent do
  @moduledoc false
  use Raxol.AgentClientProtocol.Agent

  alias Raxol.AgentClientProtocol.Schema.AgentTypes.InitializeResponse
  alias Raxol.AgentClientProtocol.Schema.AgentTypes.NewSessionResponse
  alias Raxol.AgentClientProtocol.Schema.AgentTypes.PromptResponse

  @impl true
  def initialize(_req, _ctx), do: {:ok, InitializeResponse.new(1)}

  @impl true
  def new_session(_req, _ctx) do
    sid =
      "sess-" <>
        (4 |> :crypto.strong_rand_bytes() |> Base.encode16(case: :lower))

    {:ok, NewSessionResponse.new(sid)}
  end

  @impl true
  def prompt(_req, _ctx), do: {:ok, PromptResponse.new(:end_turn)}
end

defmodule Raxol.AgentClientProtocol.Torture.WireTortureTest.ControlledAgent do
  @moduledoc false
  # Like SimpleAgent, but `new_session/2` blocks on a message from the test
  # process before answering -- lets a test drive TWO requests into genuinely
  # concurrent in-flight state (both dispatched, neither replied) before
  # releasing either, which is what the id-type collision test (§3) needs.
  use Raxol.AgentClientProtocol.Agent

  alias Raxol.AgentClientProtocol.Schema.AgentTypes.InitializeResponse
  alias Raxol.AgentClientProtocol.Schema.AgentTypes.NewSessionResponse

  @impl true
  def initialize(_req, _ctx), do: {:ok, InitializeResponse.new(1)}

  @impl true
  def new_session(req, ctx) do
    test_pid = ctx.handler_state
    ref = make_ref()
    send(test_pid, {:new_session_invoked, self(), ref, req.cwd})

    receive do
      {:proceed, ^ref} -> :ok
    end

    sid =
      "sess-" <>
        (4 |> :crypto.strong_rand_bytes() |> Base.encode16(case: :lower))

    {:ok, NewSessionResponse.new(sid)}
  end
end

defmodule Raxol.AgentClientProtocol.Torture.WireTortureTest do
  use ExUnit.Case, async: false

  @moduletag :capture_log

  alias Raxol.AgentClientProtocol.Connection
  alias Raxol.AgentClientProtocol.Error
  alias Raxol.AgentClientProtocol.Rpc.Message
  alias Raxol.AgentClientProtocol.Rpc.Request
  alias Raxol.AgentClientProtocol.Schema.AgentTypes.InitializeRequest
  alias Raxol.AgentClientProtocol.Schema.AgentTypes.PromptRequest
  alias Raxol.AgentClientProtocol.Schema.ContentBlock
  alias Raxol.AgentClientProtocol.Schema.ImageContent
  alias Raxol.AgentClientProtocol.Schema.LifecycleExtras.SessionNotification
  alias Raxol.AgentClientProtocol.Schema.MaybeUndefined
  alias Raxol.AgentClientProtocol.Schema.TextContent
  alias Raxol.AgentClientProtocol.Schema.Unstable.SessionInfoUpdate
  alias Raxol.AgentClientProtocol.Schema.Version
  alias Raxol.AgentClientProtocol.Torture.WireTortureTest.ControlledAgent
  alias Raxol.AgentClientProtocol.Torture.WireTortureTest.SimpleAgent
  alias Raxol.AgentClientProtocol.Transport.Paired
  alias Raxol.AgentClientProtocol.Transport.Stdio
  alias Raxol.AgentClientProtocol.Test.ScriptedPeer

  # ===========================================================================
  # Shared fixtures
  # ===========================================================================

  defp connection_child_spec(opts) do
    %{
      id: Connection,
      start: {Connection, :start_link, [opts]},
      restart: :temporary
    }
  end

  defp start_torture_conn(handler \\ SimpleAgent, handler_arg \\ nil) do
    task_sup = start_supervised!({Task.Supervisor, []})
    {conn_handle, peer} = ScriptedPeer.new()

    conn =
      start_supervised!(
        connection_child_spec(
          role: :agent,
          transport: {Paired, conn_handle},
          handler: handler,
          handler_arg: handler_arg,
          task_sup: task_sup
        )
      )

    %{conn: conn, peer: peer}
  end

  defp complete_handshake(peer, id \\ 1, protocol_version \\ 1) do
    ScriptedPeer.send_request(peer, id, "initialize", %{
      "protocolVersion" => protocol_version
    })

    frame = ScriptedPeer.recv(peer)
    assert frame["id"] == id
    frame
  end

  # ===========================================================================
  # 1. Forward-compat skew
  # ===========================================================================

  describe "1. forward-compat skew" do
    test "unknown fields at the request/nested-capability levels survive decode -> encode via _meta pass-through" do
      raw_init = %{
        "protocolVersion" => 1,
        "clientCapabilities" => %{
          "terminal" => true,
          "fileSystem" => %{"readTextFile" => true, "writeTextFile" => false},
          "futureCapability" => %{"nested" => [1, 2, 3], "flag" => true}
        },
        "clientInfo" => %{"name" => "torture-client", "version" => "9.9.9"},
        "futureTopLevelField" => "unknown-but-must-survive",
        "_meta" => %{"vendor.example" => %{"x" => 1}}
      }

      assert {:ok, req} = InitializeRequest.from_json(raw_init)

      # Top-level: an unrecognized wire key folds into `_meta` alongside the
      # explicit `_meta` bucket -- nothing is silently dropped.
      assert req._meta["futureTopLevelField"] == "unknown-but-must-survive"
      assert req._meta["vendor.example"] == %{"x" => 1}

      # One level deeper: the nested ClientCapabilities struct folds its OWN
      # unrecognized key into its OWN `_meta`, independent of the parent's.
      assert req.client_capabilities._meta["futureCapability"] == %{
               "nested" => [1, 2, 3],
               "flag" => true
             }

      # `Schema.AgentTypes.put_meta/2` re-emits the fold NESTED back under
      # `"_meta"` (unlike the RPC envelope layer's `Rpc.Request`/
      # `Notification`, which FLATTEN `_meta` onto the top-level map) -- a
      # real, reported convention split between the two layers, not a bug.
      re_encoded = InitializeRequest.to_json(req)

      assert re_encoded["_meta"]["futureTopLevelField"] ==
               "unknown-but-must-survive"

      assert re_encoded["_meta"]["vendor.example"] == %{"x" => 1}

      assert re_encoded["clientCapabilities"]["_meta"]["futureCapability"] == %{
               "nested" => [1, 2, 3],
               "flag" => true
             }

      # Byte-faithful (modulo map key order, which is not wire-observable):
      # decode(encode(decode(raw))) == decode(raw).
      assert {:ok, req2} = InitializeRequest.from_json(re_encoded)
      assert req2 == req
    end

    test "unknown fields inside a ContentBlock (a level deeper than a request) survive decode -> encode" do
      raw = %{
        "type" => "text",
        "text" => "hi",
        "futureContentField" => %{"z" => true, "list" => [1, "two", nil]}
      }

      assert {:ok, {:text, %TextContent{} = tc}} = ContentBlock.from_json(raw)

      assert tc._meta["futureContentField"] == %{
               "z" => true,
               "list" => [1, "two", nil]
             }

      re = ContentBlock.to_json({:text, tc})
      assert re["type"] == "text"

      assert re["_meta"]["futureContentField"] == %{
               "z" => true,
               "list" => [1, "two", nil]
             }

      assert {:ok, {:text, tc2}} = ContentBlock.from_json(re)
      assert tc2 == tc
    end

    test "unknown wire methods answer -32601 through a live Connection regardless of param garbage shape" do
      %{peer: peer} = start_torture_conn()
      complete_handshake(peer)

      garbage_corpus = [
        {"totally/unknown",
         %{"nested" => %{"deep" => [1, %{"x" => "y"}, nil]}}},
        {"session/newx", nil},
        {"_vendor/unregistered_ext_method", %{"whatever" => 1}},
        {"a" <> String.duplicate("b", 500), %{}},
        {"unicode/日本語/🎉", [1, 2, 3]},
        {"", %{}}
      ]

      Enum.with_index(garbage_corpus, 100)
      |> Enum.each(fn {{method, params}, id} ->
        ScriptedPeer.send_request(peer, id, method, params)
        frame = ScriptedPeer.recv(peer)
        assert frame["id"] == id
        assert frame["error"]["code"] == Error.method_not_found_code()
      end)
    end

    test "a never-negotiated (higher) protocolVersion integer is tolerated at decode and live handshake" do
      # Schema layer: Version.coerce/1 accepts any non-negative integer, not
      # just the ones this library actually implements.
      assert Version.coerce(999) == {:ok, 999}

      assert {:ok, %InitializeRequest{protocol_version: 999}} =
               InitializeRequest.from_json(%{"protocolVersion" => 999})

      # Live handshake: Connection does not itself reject an unrecognized
      # protocolVersion pre-emptively -- that is the handler's call, and the
      # handler here accepts unconditionally, so the handshake completes and
      # subsequent traffic flows normally.
      %{peer: peer} = start_torture_conn()
      frame = complete_handshake(peer, 1, 999)
      assert frame["result"]["protocolVersion"] == 1

      ScriptedPeer.send_request(peer, 2, "session/new", %{"cwd" => "/tmp"})
      post_handshake = ScriptedPeer.recv(peer)
      assert post_handshake["id"] == 2
      assert is_binary(post_handshake["result"]["sessionId"])
    end
  end

  # ===========================================================================
  # 2. Oversized (~5MB multimodal) frames
  # ===========================================================================

  describe "2. oversized frames" do
    test "a ~5MB base64 image content block round-trips through the real Stdio transport + framer, no truncation" do
      big_data =
        5
        |> Kernel.*(1024 * 1024)
        |> :crypto.strong_rand_bytes()
        |> Base.encode64()

      prompt_req =
        PromptRequest.new("sess-torture", [
          ContentBlock.text(TextContent.new("describe this image")),
          ContentBlock.image(ImageContent.new(big_data, "image/png"))
        ])

      wire_map =
        1
        |> Request.new("session/prompt", PromptRequest.to_json(prompt_req))
        |> Message.wrap()
        |> Message.to_json()

      {:ok, transport} = Stdio.start_spawn("cat", [], owner: self())
      {:ok, _transport} = Stdio.send_message(transport, wire_map)

      # Real byte-level round trip through the Framer + Port + Jason codec
      # (not the in-process, zero-copy Paired transport): if the Framer or
      # any hop truncated/split the line (the classic Erlang `{:line, N}`
      # port-mode footgun this transport deliberately avoids -- see
      # `Transport.Stdio`'s `Port.open/2` call using `:binary`, never
      # `:line`), this either times out or decodes to a corrupted map.
      assert_receive {:acp_transport, _ref, {:message, echoed}}, 15_000
      assert echoed == wire_map

      :ok = Stdio.close(transport)

      # And the payload survives the SCHEMA decode on top of the byte-level
      # round trip -- exact byte size, exact content, no partial decode.
      assert {:ok, decoded_req} = Request.from_json(echoed)

      assert {:ok, %PromptRequest{prompt: blocks}} =
               PromptRequest.from_json(decoded_req.params)

      assert [{:text, _}, {:image, %ImageContent{data: roundtripped_data}}] =
               blocks

      assert roundtripped_data == big_data
      assert byte_size(roundtripped_data) == byte_size(big_data)
    end
  end

  # ===========================================================================
  # 3. id-type matrix
  # ===========================================================================

  describe "3. id-type matrix" do
    test "integer and string ids in flight AT THE SAME TIME correlate independently, no collision" do
      %{peer: peer} = start_torture_conn(ControlledAgent, self())
      complete_handshake(peer)

      ScriptedPeer.send_request(peer, 1, "session/new", %{"cwd" => "/a"})
      assert_receive {:new_session_invoked, task1, ref1, "/a"}

      ScriptedPeer.send_request(peer, "1", "session/new", %{"cwd" => "/b"})
      assert_receive {:new_session_invoked, task2, ref2, "/b"}

      # Both requests are now genuinely pending simultaneously (neither
      # handler has returned) -- proof the `pending_in`/`reply_refs` maps
      # keyed the integer `1` and the string `"1"` as two distinct entries,
      # not one collapsed by an accidental `to_string`/coercion.
      send(task1, {:proceed, ref1})
      send(task2, {:proceed, ref2})

      frames = [ScriptedPeer.recv(peer), ScriptedPeer.recv(peer)]
      ids_by_type = Enum.group_by(frames, & &1["id"])

      assert Map.has_key?(ids_by_type, 1)
      assert Map.has_key?(ids_by_type, "1")
      assert Enum.all?(frames, &is_binary(&1["result"]["sessionId"]))
    end

    test "edge-case request ids (zero, negative, max-int, unicode string, empty string) echo back byte-exact" do
      %{peer: peer} = start_torture_conn()
      complete_handshake(peer)

      ids = [
        0,
        -1,
        -9_007_199_254_740_991,
        9_007_199_254_740_991,
        "",
        "日本語-🎉",
        "0"
      ]

      Enum.each(ids, fn id ->
        ScriptedPeer.send_request(peer, id, "session/new", %{"cwd" => "/tmp"})
        frame = ScriptedPeer.recv(peer)
        assert frame["id"] === id
      end)
    end

    test "a null request id is preserved as JSON null on a malformed-frame error response" do
      %{peer: peer} = start_torture_conn()
      complete_handshake(peer)

      # No "method" key -> classified as malformed, not a notification
      # (notifications require "method" and NO "id"; this frame has "id").
      ScriptedPeer.send_raw(peer, %{"jsonrpc" => "2.0", "id" => nil})
      frame = ScriptedPeer.recv(peer)
      assert frame["id"] == nil
      assert frame["error"]["code"] == Error.invalid_request_code()

      # Connection survives; a well-formed request right after still works.
      ScriptedPeer.send_request(peer, "after-null", "session/new", %{
        "cwd" => "/tmp"
      })

      ok_frame = ScriptedPeer.recv(peer)
      assert ok_frame["id"] == "after-null"
    end
  end

  # ===========================================================================
  # 4. Three-state fields (MaybeUndefined + the _meta analog)
  # ===========================================================================

  describe "4. three-state fields" do
    test "SessionInfoUpdate.title: absent vs explicit-null vs value round-trip independently" do
      # Absent -> :undefined -> omitted on re-encode.
      assert {:ok, %SessionInfoUpdate{title: :undefined} = absent} =
               SessionInfoUpdate.from_json(%{})

      refute Map.has_key?(SessionInfoUpdate.to_json(absent), "title")
      assert MaybeUndefined.undefined?(absent.title)

      # Explicit null -> nil -> re-emitted as JSON null (present key).
      assert {:ok, %SessionInfoUpdate{title: nil} = explicit_null} =
               SessionInfoUpdate.from_json(%{"title" => nil})

      null_json = SessionInfoUpdate.to_json(explicit_null)
      assert Map.has_key?(null_json, "title")
      assert null_json["title"] == nil
      assert MaybeUndefined.null?(explicit_null.title)

      # A value -> {:value, v} -> re-emitted verbatim.
      assert {:ok, %SessionInfoUpdate{title: {:value, "New Title"}} = valued} =
               SessionInfoUpdate.from_json(%{"title" => "New Title"})

      value_json = SessionInfoUpdate.to_json(valued)
      assert value_json["title"] == "New Title"
      assert MaybeUndefined.value?(valued.title)
      assert MaybeUndefined.value(valued.title) == "New Title"

      # Full round trip is stable for each of the three states.
      for json <- [%{}, %{"title" => nil}, %{"title" => "New Title"}] do
        assert {:ok, decoded} = SessionInfoUpdate.from_json(json)

        assert {:ok, decoded2} =
                 decoded
                 |> SessionInfoUpdate.to_json()
                 |> SessionInfoUpdate.from_json()

        assert decoded2 == decoded
      end
    end

    test "SessionInfoUpdate: title and updated_at carry INDEPENDENT three-state values" do
      assert {:ok, siu} =
               SessionInfoUpdate.from_json(%{
                 "title" => nil,
                 "updatedAt" => "2026-01-01"
               })

      assert MaybeUndefined.null?(siu.title)
      assert MaybeUndefined.value(siu.updated_at) == "2026-01-01"

      json = SessionInfoUpdate.to_json(siu)
      assert json["title"] == nil
      assert json["updatedAt"] == "2026-01-01"
    end

    test "the three-state field round-trips through the full SessionNotification envelope" do
      {:ok, siu} = SessionInfoUpdate.from_json(%{"title" => nil})
      notif = SessionNotification.new("sess-1", {:session_info_update, siu})

      wire = SessionNotification.to_json(notif)
      assert wire["update"]["title"] == nil

      assert {:ok, decoded} = SessionNotification.from_json(wire)

      assert {:session_info_update, %SessionInfoUpdate{title: nil}} =
               decoded.update
    end

    test "set_session_mode's _meta three-state analog: absent vs empty-object vs populated" do
      alias Raxol.AgentClientProtocol.Schema.AgentTypes.SetSessionModeRequest

      absent = %{"sessionId" => "s1", "modeId" => "m1"}
      empty = Map.put(absent, "_meta", %{})
      populated = Map.put(absent, "_meta", %{"trace" => "abc"})

      assert {:ok, %SetSessionModeRequest{_meta: %{}}} =
               SetSessionModeRequest.from_json(absent)

      assert {:ok, %SetSessionModeRequest{_meta: %{}}} =
               SetSessionModeRequest.from_json(empty)

      assert {:ok, %SetSessionModeRequest{_meta: %{"trace" => "abc"}} = req} =
               SetSessionModeRequest.from_json(populated)

      # Documented (not a bug): an explicitly-empty `_meta: {}` and an
      # absent `_meta` key are indistinguishable after decode (both fold to
      # `%{}`) and BOTH re-encode by omitting the key entirely -- `_meta`
      # has no true three-state discipline of its own, unlike
      # `MaybeUndefined` fields. Populated `_meta` survives round trip.
      assert SetSessionModeRequest.to_json(req)["_meta"] == %{"trace" => "abc"}

      refute Map.has_key?(
               SetSessionModeRequest.to_json(%SetSessionModeRequest{
                 req
                 | _meta: %{}
               }),
               "_meta"
             )
    end
  end

  # ===========================================================================
  # 5. Malformed input totality
  # ===========================================================================

  describe "5. malformed input totality" do
    test "5000 random garbage frames never crash a live Connection; atom_count stays flat" do
      %{conn: conn, peer: peer} = start_torture_conn()
      complete_handshake(peer)

      before_count = :erlang.system_info(:atom_count)

      Enum.each(1..5000, fn i ->
        case rem(i, 5) do
          0 -> ScriptedPeer.send_raw_unchecked(peer, garbage_scalar(i))
          1 -> ScriptedPeer.send_raw_unchecked(peer, garbage_list(i))
          2 -> ScriptedPeer.send_raw(peer, garbage_map(i))
          3 -> ScriptedPeer.send_raw(peer, garbage_looks_like_request(i))
          4 -> ScriptedPeer.send_raw(peer, garbage_looks_like_response(i))
        end
      end)

      assert Process.alive?(conn)

      # Drain: the connection must still be fully responsive after 5000
      # garbage frames -- a genuine reply to a well-formed request proves
      # the mailbox never wedged and Router/Connection dispatch still works.
      # Many garbage frames ALSO produced their own (correct) -32601/-32600
      # response noise, still queued ahead of the drain reply in the test
      # process's mailbox (`assert_receive` matches ANY queued message, not
      # just the head) -- discard those until the tagged "drain" id surfaces.
      ScriptedPeer.send_request(peer, "drain", "session/new", %{"cwd" => "/tmp"})

      drain_frame = recv_until_id(peer, "drain")
      assert drain_frame["id"] == "drain"
      assert is_binary(drain_frame["result"]["sessionId"])

      after_count = :erlang.system_info(:atom_count)

      assert after_count - before_count < 200,
             "atom count grew by #{after_count - before_count} after 5000 garbage frames"
    end
  end

  defp recv_until_id(peer, id, tries \\ 6000) do
    frame = ScriptedPeer.recv(peer, 5_000)

    cond do
      frame["id"] == id -> frame
      tries > 0 -> recv_until_id(peer, id, tries - 1)
      true -> flunk("never observed a frame with id #{inspect(id)}")
    end
  end

  # -- garbage generators (deterministic-ish, varied shapes, no atom creation) --

  defp garbage_scalar(i) do
    Enum.at(
      [i, i * 1.5, "junk-#{i}", true, false, nil, <<0, 1, 2, 255>>],
      rem(i, 7)
    )
  end

  defp garbage_list(i) do
    [i, "x#{i}", %{"a" => i}, [1, [2, [3, [4]]]], nil, true]
  end

  defp garbage_map(i) do
    case rem(i, 6) do
      0 ->
        %{"jsonrpc" => "2.0", "id" => i, "method" => 123}

      1 ->
        %{"jsonrpc" => "1.0", "id" => "x#{i}", "method" => "y"}

      2 ->
        %{"random#{i}" => %{"nested" => %{"deep" => %{"deeper" => i}}}}

      3 ->
        %{"jsonrpc" => "2.0", "id" => %{"not" => "valid"}, "method" => "z"}

      4 ->
        %{
          "jsonrpc" => "2.0",
          "method" => "unicode/日本語-#{i}",
          "params" => [i, nil, true]
        }

      5 ->
        %{}
    end
  end

  defp garbage_looks_like_request(i) do
    %{
      "jsonrpc" => "2.0",
      "id" => i,
      "method" => "junk/method-#{i}",
      "params" => garbage_list(i)
    }
  end

  defp garbage_looks_like_response(i) do
    # An unrecognized id -> dropped silently (late/unknown response), never
    # a crash and never a frame back.
    %{"jsonrpc" => "2.0", "id" => 900_000 + i, "result" => %{"whatever" => i}}
  end
end
