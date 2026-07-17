# SPIKE — react-devtools bridge (graduate or delete after V verdict).
#
# Poses as a React renderer backend to the STANDALONE react-devtools app
# (pinned: react-devtools / react-devtools-core 7.0.1). The Electron app
# is a WebSocket SERVER on port 8097; this bridge is the WS CLIENT, the
# same role `react-devtools-core/backend`'s `connectToDevTools` plays in
# a real React app.
#
# Protocol notes (reverse-engineered from the 7.0.1 dist bundles,
# `standalone.js` Store/`onBridgeOperations` + unminified `backend.js`):
#
#   * Wall format: one JSON object per WS text frame:
#     `{"event": name, "payload": any}`.
#   * Handshake: backend sends `backendInitialized` after connect. THAT
#     is what arms the frontend: its Store then sends
#     `getBridgeProtocol` (10s timeout -> "unsupported" dialog),
#     `getBackendVersion`, `getIfHasUnsupportedRendererVersion` (silence
#     means "supported"), and `getHookSettings`. Other frontend chatter
#     seen at startup: `getProfilingStatus`, `getEnvironmentNames`,
#     `setTraceUpdatesEnabled`, `updateConsolePatchSettings`,
#     `updateComponentFilters`.
#   * Replies: `bridgeProtocol` {version: 2, minNpmVersion: "4.22.0",
#     maxNpmVersion: null}, `backendVersion` (string), `hookSettings`,
#     `profilingStatus` false, `environmentNames` [].
#   * Tree: `operations` events, payload = flat int array:
#     [rendererID, rootID, stringTableWordCount, ...stringTable, ...ops]
#     String table entries: [len, ...utf16CodeUnits], ids 1-based, 0=null.
#     ADD(1) root:  [1, id, 11, isStrictModeCompliant, profilingFlags,
#                    supportsStrictMode, hasOwnerMetadata]
#     ADD(1) child: [1, id, type, parentID, ownerID, displayNameStrID,
#                    keyStrID, namePropStrID]   <- 7.x has a THIRD string
#                    (nameProp); the widely documented 6-field layout is
#                    pre-7.
#     REMOVE(2): [2, count, ...ids] (children before parents)
#     REORDER(3): [3, id, count, ...childIDs]
#     Element types: Function=5, HostComponent=7, Root=11.
#   * Hover in the Elements panel -> frontend sends
#     `highlightHostInstance` {id, rendererID, displayName,
#     hideAfterTimeout, openBuiltinElementsPanel, scrollIntoView} and
#     `clearHostInstanceHighlight` on leave (7.x names; pre-5 these were
#     highlightNativeElement / clearNativeElementHighlight).
#   * Selecting an element -> `inspectElement` {id, rendererID,
#     requestID, path, forceFullData} -> reply `inspectedElement`
#     {type: "full-data", responseID, id, value: InspectedElement} where
#     props/context/state are dehydrated: {cleaned: [], data: map,
#     unserializable: []}.
#
# The tree this bridge exposes is a MINIMAL, bridge-owned snapshot built
# from the same `Raxol.Agent.SessionStreamer` events the live driver
# consumes (normalized through `Raxol.Harness.EventBoundary`, the same
# security seam) — NOT the Surface's own projection. The debug-tap
# `to_debug_tree` contract landed CONCURRENTLY with this spike
# (`Raxol.Examples.HarnessDebug.TreeBuilder` in
# examples/support/harness_debug.exs, the DEBUG_WEB instrument);
# graduation should swap this event-derived tree for that one — it reads
# the real Surface model. Honest consequence meanwhile: fold state and
# seal status per block are approximated here (sealed = turn bracket
# seen), not read from the Surface.
#
# Highlight payoff (the REAL painted one — the Surface-side seam the
# spike's first pass lacked now exists): hover OR select
# (`highlightHostInstance` / `inspectElement`, last-writer-wins, one
# highlight at a time) on a FOOTER-region element sends
# `{:surface_command, %{type: :debug_highlight, payload: %{group: g}}}`
# to the live driver, and `Surface.put_debug_highlight/2` paints a
# pale-blue background under exactly that footer group's rows
# (StatusStrip -> :status, LaneNotice -> :lane, Composer -> :composer,
# the live tail -> :preview — the footer's own group vocabulary). The
# tint is a palette role (`Raxol.UI.Theming.Palette.debug_highlight_bg/1`,
# capability-tiered) — no color literal on this side of the wire.
# `clearHostInstanceHighlight` clears it (group `nil`).
#
# Sealed history rows CANNOT be repainted (seal-once is a Surface
# invariant), so a history block hover/select still renders an honest
# footer notice naming the block instead — the lane-notice channel keeps
# that job, and a history hover also CLEARS any active footer highlight
# (the hover has moved; keeping a stale tint would lie about where it
# is).

defmodule Raxol.Spike.ReactDevtools.Wire do
  @moduledoc false
  # Minimal RFC6455 WebSocket wire helpers — client AND server side, so
  # the sim harness (devtools_frontend_sim.exs) reuses the exact same
  # framing code it is validating against. No deps beyond :crypto
  # (mint_web_socket is not in raxol_agent's dep tree, and a spike does
  # not grow a shared lockfile).

  @ws_guid "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"

  # -- client handshake -----------------------------------------------------

  def client_connect(host, port, timeout \\ 3_000) do
    with {:ok, sock} <-
           :gen_tcp.connect(
             String.to_charlist(host),
             port,
             [:binary, active: false, nodelay: true],
             timeout
           ) do
      key = 16 |> :crypto.strong_rand_bytes() |> Base.encode64()

      req = [
        "GET / HTTP/1.1\r\n",
        "Host: #{host}:#{port}\r\n",
        "Upgrade: websocket\r\nConnection: Upgrade\r\n",
        "Sec-WebSocket-Key: #{key}\r\n",
        "Sec-WebSocket-Version: 13\r\n\r\n"
      ]

      :ok = :gen_tcp.send(sock, req)

      case read_http_head(sock, <<>>, timeout) do
        {:ok, head, rest} ->
          if String.contains?(head, " 101 ") do
            {:ok, sock, rest}
          else
            :gen_tcp.close(sock)
            {:error, {:bad_upgrade, String.slice(head, 0, 120)}}
          end

        {:error, reason} ->
          :gen_tcp.close(sock)
          {:error, reason}
      end
    end
  end

  defp read_http_head(sock, acc, timeout) do
    case :binary.match(acc, "\r\n\r\n") do
      {pos, 4} ->
        head_len = pos + 4
        <<head::binary-size(^head_len), rest::binary>> = acc
        {:ok, head, rest}

      :nomatch ->
        case :gen_tcp.recv(sock, 0, timeout) do
          {:ok, data} -> read_http_head(sock, acc <> data, timeout)
          {:error, reason} -> {:error, reason}
        end
    end
  end

  # -- server handshake (sim harness side) ----------------------------------

  def server_accept_upgrade(sock, timeout \\ 5_000) do
    with {:ok, head, rest} <- read_http_head(sock, <<>>, timeout),
         [_, key] <-
           Regex.run(~r/Sec-WebSocket-Key:\s*(\S+)/i, head) do
      accept = Base.encode64(:crypto.hash(:sha, key <> @ws_guid))

      resp = [
        "HTTP/1.1 101 Switching Protocols\r\n",
        "Upgrade: websocket\r\nConnection: Upgrade\r\n",
        "Sec-WebSocket-Accept: #{accept}\r\n\r\n"
      ]

      :ok = :gen_tcp.send(sock, resp)
      {:ok, rest}
    else
      other -> {:error, {:bad_ws_request, other}}
    end
  end

  # -- frames ---------------------------------------------------------------

  # masked?: client->server frames MUST be masked; server->client MUST NOT.
  def encode_text(payload, masked?), do: encode_frame(0x1, payload, masked?)
  def encode_pong(payload, masked?), do: encode_frame(0xA, payload, masked?)
  def encode_close(masked?), do: encode_frame(0x8, <<>>, masked?)

  def encode_frame(opcode, payload, masked?) do
    len = byte_size(payload)
    b1 = <<1::1, 0::3, opcode::4>>
    m = if masked?, do: 1, else: 0

    len_part =
      cond do
        len < 126 -> <<m::1, len::7>>
        len < 65_536 -> <<m::1, 126::7, len::16>>
        true -> <<m::1, 127::7, len::64>>
      end

    if masked? do
      key = :crypto.strong_rand_bytes(4)
      IO.iodata_to_binary([b1, len_part, key, mask(payload, key)])
    else
      IO.iodata_to_binary([b1, len_part, payload])
    end
  end

  def mask(payload, key) do
    len = byte_size(payload)
    stream = :binary.copy(key, div(len, 4) + 1)
    :crypto.exor(payload, :binary.part(stream, 0, len))
  end

  @doc """
  Decode every complete frame in `buf`. Returns `{messages, rest, frag}`
  where `frag` carries an unfinished fragmented message across calls
  (`nil` or `{opcode, payload_so_far}`); messages are
  `{:text, bin} | {:binary, bin} | {:ping, bin} | {:pong, bin} | :close`.
  """
  def decode_frames(buf, frag \\ nil, acc \\ []) do
    case parse_frame(buf) do
      {:ok, fin, op, payload, rest} ->
        {frag, acc} = assemble(fin, op, payload, frag, acc)
        decode_frames(rest, frag, acc)

      :incomplete ->
        {Enum.reverse(acc), buf, frag}
    end
  end

  defp assemble(1, 0x0, payload, {op0, sofar}, acc),
    do: {nil, [finish(op0, sofar <> payload) | acc]}

  defp assemble(0, 0x0, payload, {op0, sofar}, acc),
    do: {{op0, sofar <> payload}, acc}

  defp assemble(1, op, payload, _frag, acc),
    do: {nil, [finish(op, payload) | acc]}

  defp assemble(0, op, payload, _frag, acc), do: {{op, payload}, acc}

  defp finish(0x1, payload), do: {:text, payload}
  defp finish(0x2, payload), do: {:binary, payload}
  defp finish(0x8, _payload), do: :close
  defp finish(0x9, payload), do: {:ping, payload}
  defp finish(0xA, payload), do: {:pong, payload}
  defp finish(op, payload), do: {:unknown, op, payload}

  defp parse_frame(<<fin::1, _rsv::3, op::4, masked::1, len7::7, rest::binary>>) do
    with {:ok, len, rest} <- parse_len(len7, rest),
         {:ok, key, rest} <- parse_key(masked, rest),
         true <- byte_size(rest) >= len do
      <<payload::binary-size(^len), tail::binary>> = rest
      payload = if key, do: mask(payload, key), else: payload
      {:ok, fin, op, payload, tail}
    else
      _ -> :incomplete
    end
  end

  defp parse_frame(_), do: :incomplete

  defp parse_len(len7, rest) when len7 < 126, do: {:ok, len7, rest}
  defp parse_len(126, <<len::16, rest::binary>>), do: {:ok, len, rest}
  defp parse_len(127, <<len::64, rest::binary>>), do: {:ok, len, rest}
  defp parse_len(_, _), do: :incomplete

  defp parse_key(0, rest), do: {:ok, nil, rest}
  defp parse_key(1, <<key::binary-size(4), rest::binary>>), do: {:ok, key, rest}
  defp parse_key(1, _short), do: :incomplete
end

defmodule Raxol.Spike.ReactDevtools.Ops do
  @moduledoc false
  # Encode/decode the react-devtools `operations` payload (7.0.1 layout —
  # see the header notes; the decoder exists so the sim harness and the
  # bridge's own self-check read frames back with store.js semantics).

  @op_add 1
  @op_remove 2
  @op_reorder 3

  @el_root 11

  def el_root, do: @el_root

  @doc """
  Build one operations frame. `adds` is a parent-first list of
  `%{id:, type:, parent_id:, name:, key:}` (root: `parent_id: nil`);
  `removes` is a children-first list of ids.
  """
  def encode(renderer_id, root_id, adds, removes) do
    strings =
      adds
      |> Enum.flat_map(fn n -> [n[:name], n[:key]] end)
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()

    index = strings |> Enum.with_index(1) |> Map.new()

    table_words =
      Enum.flat_map(strings, fn s ->
        units = utf16_units(s)
        [length(units) | units]
      end)

    add_ops =
      Enum.flat_map(adds, fn
        %{type: @el_root, id: id} ->
          # [ADD, id, Root, isStrictModeCompliant, profilingFlags,
          #  supportsStrictMode, hasOwnerMetadata]
          [@op_add, id, @el_root, 0, 0, 0, 0]

        %{id: id, type: type, parent_id: parent, name: name, key: key} ->
          # [ADD, id, type, parentID, ownerID, nameStrID, keyStrID,
          #  namePropStrID]  (namePropStrID is new in 7.x)
          [
            @op_add,
            id,
            type,
            parent,
            0,
            str_id(index, name),
            str_id(index, key),
            0
          ]
      end)

    remove_ops =
      if removes == [], do: [], else: [@op_remove, length(removes) | removes]

    [renderer_id, root_id, length(table_words)] ++
      table_words ++ add_ops ++ remove_ops
  end

  defp str_id(_index, nil), do: 0
  defp str_id(index, s), do: Map.fetch!(index, s)

  defp utf16_units(s) do
    for <<unit::16 <- :unicode.characters_to_binary(s, :utf8, {:utf16, :big})>>,
      do: unit
  end

  @doc """
  Decode a frame with store.js semantics. Returns
  `%{renderer_id:, root_id:, ops: [...]}` with ops of
  `{:add_root, id} | {:add, %{id, type, parent_id, name, key}} |
   {:remove, ids} | {:reorder, id, child_ids}`.
  """
  def decode([renderer_id, root_id, table_size | rest]) do
    {table_words, op_words} = Enum.split(rest, table_size)
    strings = decode_table(table_words, [nil])
    ops = decode_ops(op_words, strings, [])
    %{renderer_id: renderer_id, root_id: root_id, ops: ops}
  end

  defp decode_table([], acc), do: acc |> Enum.reverse() |> List.to_tuple()

  defp decode_table([len | rest], acc) do
    {units, rest} = Enum.split(rest, len)

    s =
      units
      |> Enum.map(&<<&1::16>>)
      |> IO.iodata_to_binary()
      |> :unicode.characters_to_binary({:utf16, :big}, :utf8)

    decode_table(rest, [s | acc])
  end

  defp lookup(strings, 0) when is_tuple(strings), do: nil
  defp lookup(strings, i), do: elem(strings, i)

  defp decode_ops([], _strings, acc), do: Enum.reverse(acc)

  defp decode_ops(
         [@op_add, id, @el_root, _strict, _flags, _sm, _om | rest],
         s,
         acc
       ),
       do: decode_ops(rest, s, [{:add_root, id} | acc])

  defp decode_ops(
         [@op_add, id, type, parent, _owner, name_i, key_i, _prop_i | rest],
         s,
         acc
       ) do
    node = %{
      id: id,
      type: type,
      parent_id: parent,
      name: lookup(s, name_i),
      key: lookup(s, key_i)
    }

    decode_ops(rest, s, [{:add, node} | acc])
  end

  defp decode_ops([@op_remove, count | rest], s, acc) do
    {ids, rest} = Enum.split(rest, count)
    decode_ops(rest, s, [{:remove, ids} | acc])
  end

  defp decode_ops([@op_reorder, id, count | rest], s, acc) do
    {children, rest} = Enum.split(rest, count)
    decode_ops(rest, s, [{:reorder, id, children} | acc])
  end

  defp decode_ops(other, _s, acc),
    do: Enum.reverse([{:undecodable_tail, other} | acc])
end

defmodule Raxol.Spike.ReactDevtools.Bridge do
  @moduledoc false
  use GenServer

  alias Raxol.Harness.EventBoundary
  alias Raxol.Spike.ReactDevtools.Ops
  alias Raxol.Spike.ReactDevtools.Wire

  @el_function 5
  @el_host 7

  @renderer_id 1
  @root_id 1
  @retry_ms 2_000
  @default_log "/tmp/raxol_devtools_bridge.log"

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  @impl true
  def init(opts) do
    {:ok, _} = Application.ensure_all_started(:crypto)
    session_id = Keyword.fetch!(opts, :session_id)
    log = Keyword.get(opts, :log, @default_log)
    File.write!(log, "")

    # Second subscriber on the same session the live driver renders —
    # SessionStreamer broadcasts to all subscribers, so this taps the
    # stream without touching the driver's pipeline.
    :ok = Raxol.Agent.SessionStreamer.subscribe(session_id)

    state = %{
      session_id: session_id,
      driver: Keyword.get(opts, :driver),
      host: Keyword.get(opts, :host, "localhost"),
      port: Keyword.get(opts, :port, 8097),
      log: log,
      sock: nil,
      buf: <<>>,
      frag: nil,
      attempts: 0,
      # tree state
      nodes: %{},
      order: [],
      ids: %{},
      by_id: %{},
      props: %{},
      next_id: @root_id,
      synced: MapSet.new()
    }

    state =
      state
      |> skeleton()
      |> log_line("bridge up; dialing ws://#{state.host}:#{state.port}")

    {:ok, state, {:continue, :connect}}
  end

  @impl true
  def handle_continue(:connect, state), do: {:noreply, try_connect(state)}

  # -- static skeleton -------------------------------------------------------

  defp skeleton(state) do
    state
    |> put_node(:root, nil, Ops.el_root(), nil, nil, %{})
    |> put_node(:surface, :root, @el_function, "HarnessSurface", nil, %{
      "session_id" => state.session_id
    })
    |> put_node(:history, :surface, @el_function, "History", nil, %{})
    |> put_node(:footer, :surface, @el_function, "Footer", nil, %{})
    |> put_node(:status_strip, :footer, @el_host, "StatusStrip", nil, %{
      "region" => "footer"
    })
    |> put_node(:lane_notice, :footer, @el_host, "LaneNotice", nil, %{
      "region" => "footer"
    })
    |> put_node(:composer, :footer, @el_host, "Composer", nil, %{
      "region" => "footer"
    })
  end

  # -- connection ------------------------------------------------------------

  defp try_connect(state) do
    case Wire.client_connect(state.host, state.port) do
      {:ok, sock, leftover} ->
        :ok = :inet.setopts(sock, active: true)

        state =
          %{
            state
            | sock: sock,
              buf: leftover,
              frag: nil,
              attempts: 0,
              synced: MapSet.new()
          }
          |> log_line("CONNECTED to react-devtools frontend")
          |> send_wall("backendInitialized", nil)
          |> flush_tree()

        notify_driver(
          state,
          "» [devtools] connected — tree published to react-devtools"
        )

        state

      {:error, reason} ->
        state = %{state | sock: nil}

        state =
          if state.attempts in [0, 5] do
            log_line(
              state,
              "connect failed (#{inspect(reason)}) — retrying every #{@retry_ms}ms; " <>
                "is `npx react-devtools` running?"
            )
          else
            state
          end

        Process.send_after(self(), :retry_connect, @retry_ms)
        %{state | attempts: state.attempts + 1}
    end
  end

  @impl true
  def handle_info(:retry_connect, state), do: {:noreply, try_connect(state)}

  def handle_info({:tcp, sock, data}, %{sock: sock} = state) do
    {messages, rest, frag} = Wire.decode_frames(state.buf <> data, state.frag)
    state = %{state | buf: rest, frag: frag}
    {:noreply, Enum.reduce(messages, state, &handle_ws/2)}
  end

  def handle_info({:tcp_closed, sock}, %{sock: sock} = state),
    do: {:noreply, drop_connection(state, :tcp_closed)}

  def handle_info({:tcp_error, sock, reason}, %{sock: sock} = state),
    do: {:noreply, drop_connection(state, {:tcp_error, reason})}

  def handle_info({:session_event, sid, event}, %{session_id: sid} = state) do
    state =
      case EventBoundary.normalize(event) do
        {:ok, map} ->
          state |> apply_event(map) |> flush_tree()

        {:error, _} ->
          log_line(state, "malformed session event rejected at boundary")
      end

    {:noreply, state}
  end

  def handle_info(_other, state), do: {:noreply, state}

  defp drop_connection(state, why) do
    state = log_line(state, "connection lost (#{inspect(why)}) — will retry")
    if state.sock, do: :gen_tcp.close(state.sock)
    Process.send_after(self(), :retry_connect, @retry_ms)
    %{state | sock: nil, buf: <<>>, frag: nil, synced: MapSet.new()}
  end

  # -- inbound wall messages --------------------------------------------------

  defp handle_ws({:text, raw}, state) do
    case Jason.decode(raw) do
      {:ok, %{"event" => event} = msg} ->
        dispatch(event, Map.get(msg, "payload"), state)

      _other ->
        log_line(
          state,
          "<- undecodable wall frame: #{String.slice(raw, 0, 200)}"
        )
    end
  end

  defp handle_ws({:ping, payload}, state) do
    if state.sock,
      do: :gen_tcp.send(state.sock, Wire.encode_pong(payload, true))

    state
  end

  defp handle_ws(:close, state), do: drop_connection(state, :ws_close)
  defp handle_ws(_other, state), do: state

  defp dispatch("getBridgeProtocol", _p, state) do
    state
    |> log_line("<- getBridgeProtocol")
    |> send_wall("bridgeProtocol", %{
      "version" => 2,
      "minNpmVersion" => "4.22.0",
      "maxNpmVersion" => nil
    })
  end

  defp dispatch("getBackendVersion", _p, state) do
    state
    |> log_line("<- getBackendVersion")
    |> send_wall("backendVersion", "7.0.1-raxol-harness-spike")
  end

  defp dispatch("getHookSettings", _p, state) do
    state
    |> log_line("<- getHookSettings")
    |> send_wall("hookSettings", %{
      "appendComponentStack" => false,
      "breakOnConsoleErrors" => false,
      "showInlineWarningsAndErrors" => false,
      "hideConsoleLogsInStrictMode" => false
    })
  end

  defp dispatch("getProfilingStatus", _p, state) do
    state
    |> log_line("<- getProfilingStatus")
    |> send_wall("profilingStatus", false)
  end

  defp dispatch("getEnvironmentNames", _p, state) do
    state
    |> log_line("<- getEnvironmentNames")
    |> send_wall("environmentNames", [])
  end

  # Silence = "no unsupported renderer" — the real backend only replies
  # when a renderer IS unsupported.
  defp dispatch("getIfHasUnsupportedRendererVersion", _p, state),
    do: log_line(state, "<- getIfHasUnsupportedRendererVersion (no reply needed)")

  # THE PAYOFF: hover in the DevTools Elements panel lands here.
  defp dispatch("highlightHostInstance", %{"id" => id} = p, state) do
    state = log_line(state, "<- highlightHostInstance id=#{id}")
    apply_highlight(state, id)
    if Map.get(p, "scrollIntoView"), do: :ok
    state
  end

  # Pre-5 name for the same event — handled so the spike also works
  # against an older globally-installed react-devtools.
  defp dispatch("highlightNativeElement", p, state),
    do: dispatch("highlightHostInstance", p, state)

  defp dispatch("clearHostInstanceHighlight", _p, state) do
    send_debug_highlight(state, nil)
    notify_driver(state, nil)
    log_line(state, "<- clearHostInstanceHighlight")
  end

  defp dispatch("clearNativeElementHighlight", p, state),
    do: dispatch("clearHostInstanceHighlight", p, state)

  # Selection is treated exactly like hover (last-writer-wins, one
  # highlight at a time): `inspectElement` IS the frontend's select
  # signal, so a selected footer element keeps its painted highlight
  # after the hover's own clear event fires.
  defp dispatch("inspectElement", %{"id" => id, "requestID" => rid}, state) do
    state = log_line(state, "<- inspectElement id=#{id} requestID=#{rid}")
    apply_highlight(state, id)
    send_wall(state, "inspectedElement", inspected_payload(state, id, rid))
  end

  defp dispatch("shutdown", _p, state),
    do: drop_connection(state, :frontend_shutdown)

  # Spike rule: log every inbound message we don't handle.
  defp dispatch(event, payload, state) do
    log_line(
      state,
      "<- UNHANDLED #{event} payload=#{String.slice(inspect(payload), 0, 300)}"
    )
  end

  # -- highlight payoff --------------------------------------------------------

  # Both channels, every hover/select: the debug-highlight group (a real
  # painted bg for footer elements; `nil` — which also CLEARS a stale
  # tint — for sealed history/unknown) and the lane notice (the honest
  # descriptive line). Last-writer-wins by construction: one group field
  # on the Surface, one notice row.
  defp apply_highlight(state, devtools_id) do
    case Map.get(state.by_id, devtools_id) do
      nil ->
        send_debug_highlight(state, nil)

        notify_driver(
          state,
          "» [devtools] hover on unknown element ##{devtools_id}"
        )

      key ->
        node = Map.fetch!(state.nodes, key)
        send_debug_highlight(state, highlight_group(key))
        notify_driver(state, describe_for_highlight(key, node))
    end

    :ok
  end

  # Footer-region element -> the Surface footer-group vocabulary
  # `Surface.put_debug_highlight/2` accepts. Everything else (sealed
  # blocks/turns, the root, unknowns) maps to `nil`: sealed history
  # cannot be repainted (seal-once), so those get the honest notice only.
  defp highlight_group(:status_strip), do: :status
  defp highlight_group(:lane_notice), do: :lane
  defp highlight_group(:composer), do: :composer
  defp highlight_group({:tail, _turn_id}), do: :preview
  defp highlight_group(_sealed_or_other), do: nil

  defp send_debug_highlight(%{driver: pid}, group) when is_pid(pid) do
    send(
      pid,
      {:surface_command, %{type: :debug_highlight, payload: %{group: group}}}
    )
  end

  defp send_debug_highlight(_state, _group), do: :ok

  # Sealed history cannot be repainted (seal-once invariant) — the honest
  # notice names the block instead of pretending to flash it.
  defp describe_for_highlight({:block, turn_id, _eid}, node) do
    "» [devtools] block #{node.name} (#{turn_id}) — sealed, cannot highlight in place"
  end

  defp describe_for_highlight({:turn, turn_id}, _node) do
    "» [devtools] turn #{turn_id} — sealed history, cannot highlight in place"
  end

  defp describe_for_highlight({:tail, turn_id}, _node) do
    "» [devtools] live tail of #{turn_id} (streaming in the footer preview)"
  end

  defp describe_for_highlight(key, node)
       when key in [:status_strip, :lane_notice, :composer] do
    "» [devtools] ▶ #{node.name} ◀ — this footer row"
  end

  defp describe_for_highlight(_key, node) do
    "» [devtools] #{node.name || "root"}"
  end

  defp notify_driver(%{driver: pid}, text) when is_pid(pid) do
    send(pid, {:surface_command, %{type: :lane_notice, payload: %{text: text}}})
  end

  defp notify_driver(_state, _text), do: :ok

  # -- inspectElement (stretch) -------------------------------------------------

  defp inspected_payload(state, id, rid) do
    case Map.get(state.by_id, id) do
      nil ->
        %{"type" => "not-found", "responseID" => rid, "id" => id}

      key ->
        node = Map.fetch!(state.nodes, key)
        props = Map.get(state.props, key, %{})

        %{
          "type" => "full-data",
          "responseID" => rid,
          "id" => id,
          "value" => inspected_value(id, node, props)
        }
    end
  end

  # Field list mirrors 7.0.1 backend.js's InspectedElement construction
  # (createEmptyInspectedScreen superset); props are dehydrated-format.
  defp inspected_value(id, node, props) do
    %{
      "id" => id,
      "displayName" => node.name || "Root",
      "type" => node.type,
      "key" => node.key,
      "isErrored" => false,
      "errors" => [],
      "warnings" => [],
      "canEditFunctionProps" => false,
      "canEditFunctionPropsDeletePaths" => false,
      "canEditFunctionPropsRenamePaths" => false,
      "canEditHooks" => false,
      "canEditHooksAndDeletePaths" => false,
      "canEditHooksAndRenamePaths" => false,
      "canToggleError" => false,
      "canToggleSuspense" => false,
      "isSuspended" => false,
      "hasLegacyContext" => false,
      "context" => nil,
      "hooks" => nil,
      "state" => nil,
      "owners" => nil,
      "props" => %{"cleaned" => [], "data" => props, "unserializable" => []},
      "source" => nil,
      "stack" => nil,
      "env" => nil,
      "nativeTag" => nil,
      "plugins" => %{"stylex" => nil},
      "rootType" => "raxol-harness",
      "rendererPackageName" => "raxol-harness-devtools-spike",
      "rendererVersion" => "0.0.1-spike",
      "suspendedBy" => %{"cleaned" => [], "data" => [], "unserializable" => []},
      "suspendedByRange" => nil
    }
  end

  # -- tree from session events --------------------------------------------------

  # Normalized (EventBoundary) events: string payload keys. IDs are stable
  # per the spike brief: block id = {turn_id, event id}; footer children
  # fixed at skeleton time.
  defp apply_event(state, %{type: :turn_started} = ev) do
    prompt = get_in(ev.payload, ["prompt"]) || ""

    state
    |> ensure_turn(ev.turn_id)
    |> put_node(
      {:block, ev.turn_id, ev.id},
      {:turn, ev.turn_id},
      @el_host,
      "UserPrompt",
      "#{ev.id}",
      %{
        "kind" => "user_prompt",
        "excerpt" => excerpt(prompt),
        "turn_id" => ev.turn_id,
        "sealed" => false
      }
    )
  end

  defp apply_event(state, %{type: :item_delta} = ev) do
    state
    |> ensure_turn(ev.turn_id)
    |> put_node(
      {:tail, ev.turn_id},
      {:turn, ev.turn_id},
      @el_host,
      "LiveTail",
      nil,
      %{
        "kind" => "live_tail",
        "turn_id" => ev.turn_id
      }
    )
  end

  defp apply_event(state, %{type: :item_completed} = ev) do
    {name, extra} =
      case get_in(ev.payload, ["item_type"]) do
        "tool_use" ->
          {"ToolUse", %{"tool" => get_in(ev.payload, ["name"])}}

        "tool_result" ->
          {"ToolResult", %{"tool" => get_in(ev.payload, ["name"])}}

        "message" ->
          {"AssistantMessage", %{"excerpt" => excerpt(get_in(ev.payload, ["content"]) || "")}}

        other ->
          {"Item", %{"item_type" => inspect(other)}}
      end

    props =
      Map.merge(extra, %{
        "kind" => name,
        "turn_id" => ev.turn_id,
        "sealed" => false
      })

    state
    |> ensure_turn(ev.turn_id)
    |> put_node(
      {:block, ev.turn_id, ev.id},
      {:turn, ev.turn_id},
      @el_host,
      name,
      "#{ev.id}",
      props
    )
  end

  defp apply_event(state, %{type: type} = ev)
       when type in [:turn_completed, :turn_canceled] do
    # The bracket: drop the live tail, mark this turn's blocks sealed
    # (approximation — the Surface's own frontier is the truth; see the
    # header's graduation note).
    state
    |> remove_node({:tail, ev.turn_id})
    |> seal_turn_props(ev.turn_id)
  end

  defp apply_event(state, %{type: :error} = ev) do
    state
    |> ensure_turn(ev.turn_id)
    |> put_node(
      {:block, ev.turn_id, ev.id},
      {:turn, ev.turn_id},
      @el_host,
      "ErrorBlock",
      "#{ev.id}",
      %{
        "kind" => "error",
        "reason" => excerpt(inspect(get_in(ev.payload, ["reason"]))),
        "turn_id" => ev.turn_id
      }
    )
  end

  defp apply_event(state, _ev), do: state

  defp ensure_turn(state, nil), do: state

  defp ensure_turn(state, turn_id),
    do:
      put_node(
        state,
        {:turn, turn_id},
        :history,
        @el_function,
        "Turn",
        turn_id,
        %{
          "turn_id" => turn_id
        }
      )

  defp seal_turn_props(state, turn_id) do
    props =
      Map.new(state.props, fn
        {{:block, ^turn_id, _} = k, p} -> {k, Map.put(p, "sealed", true)}
        other -> other
      end)

    %{state | props: props}
  end

  defp excerpt(text) when is_binary(text) do
    text |> String.replace(~r/\s+/, " ") |> String.slice(0, 120)
  end

  defp excerpt(other), do: other |> inspect() |> String.slice(0, 120)

  # -- tree bookkeeping / diff push -------------------------------------------------

  defp put_node(state, key, parent_key, type, name, key_str, props) do
    if Map.has_key?(state.nodes, key) do
      %{state | props: Map.put(state.props, key, props)}
    else
      id = state.next_id

      node = %{
        id: id,
        parent_key: parent_key,
        type: type,
        name: name,
        key: key_str
      }

      %{
        state
        | nodes: Map.put(state.nodes, key, node),
          order: state.order ++ [key],
          ids: Map.put(state.ids, key, id),
          by_id: Map.put(state.by_id, id, key),
          props: Map.put(state.props, key, props),
          next_id: id + 1
      }
    end
  end

  defp remove_node(state, key) do
    case Map.get(state.nodes, key) do
      nil ->
        state

      %{id: id} ->
        %{
          state
          | nodes: Map.delete(state.nodes, key),
            order: List.delete(state.order, key),
            ids: Map.delete(state.ids, key),
            by_id: Map.delete(state.by_id, id),
            props: Map.delete(state.props, key)
        }
    end
  end

  defp flush_tree(%{sock: nil} = state), do: state

  defp flush_tree(state) do
    live_ids = state.ids |> Map.values() |> MapSet.new()

    adds =
      state.order
      |> Enum.reject(fn key ->
        MapSet.member?(state.synced, state.nodes[key].id)
      end)
      |> Enum.map(fn key ->
        node = state.nodes[key]

        %{
          id: node.id,
          type: node.type,
          parent_id: node.parent_key && state.nodes[node.parent_key].id,
          name: node.name,
          key: node.key
        }
      end)

    removes =
      state.synced
      |> MapSet.difference(live_ids)
      |> Enum.sort(:desc)

    if adds == [] and removes == [] do
      state
    else
      frame = Ops.encode(@renderer_id, @root_id, adds, removes)

      # Self-check: our own frames must decode with store.js semantics
      # before we trust them on the wire.
      decoded = Ops.decode(frame)

      if Enum.any?(decoded.ops, &match?({:undecodable_tail, _}, &1)) do
        log_line(state, "SELF-CHECK FAILED, frame not sent: #{inspect(frame)}")
      else
        state =
          log_line(
            state,
            "-> operations adds=#{length(adds)} removes=#{length(removes)} " <>
              "decoded-ok=#{length(decoded.ops)} ops"
          )

        state = send_wall(state, "operations", frame)
        %{state | synced: live_ids}
      end
    end
  end

  # -- wall / log ------------------------------------------------------------------

  defp send_wall(%{sock: nil} = state, _event, _payload), do: state

  defp send_wall(state, event, payload) do
    json = Jason.encode!(%{"event" => event, "payload" => payload})

    case :gen_tcp.send(state.sock, Wire.encode_text(json, true)) do
      :ok -> log_line(state, "-> #{event}")
      {:error, reason} -> drop_connection(state, {:send_failed, reason})
    end
  end

  defp log_line(state, text) do
    ts = DateTime.utc_now() |> DateTime.to_iso8601()
    File.write!(state.log, "#{ts} #{text}\n", [:append])
    state
  end
end
