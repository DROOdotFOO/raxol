# Harness debug instrument (DEBUG_WEB=true), demo-local support for
# examples/harness_live_demo.exs. NOT part of the raxol_agent package
# build -- loaded via Code.require_file only when DEBUG_WEB is set, so
# the demo's default path is byte-identical to before.
#
# What it is: a live "TUI devtools" web page for the harness demo --
# two panes:
#
#   * a DOM-tree-style state panel (browser-devtools Elements style):
#     the live Surface model as an expandable tree, rebuilt via the
#     LiveSessionDriver's `:debug_state_probe` seam after each paint
#     (paint detected via the device tee -- bytes written == a paint
#     happened);
#   * an event-sourcing stream pane: sequence-numbered journal/session
#     events, input-path entries (raw tty bytes -> InputEvent ->
#     keymap resolution), and teed device writes (hex-escaped).
#
# Architecture notes (the decisions, so nobody re-derives them):
#
#   * Device tee: `DeviceTee` is a process implementing the Erlang I/O
#     protocol. The demo hands its pid to LiveSessionDriver as the
#     `:device`; put_chars requests are forwarded to the REAL device via
#     plain `IO.write/2` (synchronous -- ordering vs. other writers is
#     serialized by the group leader as usual) and a copy is cast to the
#     Tap. Non-write requests are forwarded verbatim to the real device
#     owner, which replies directly to the requester.
#   * Raw input bytes come from InlineDriver's `:raw_sink` seam (the Tap
#     pid receives `{:inline_raw_input, binary}` pre-parse chunks).
#   * Session events come from a direct SessionStreamer subscription
#     (same `{:session_event, sid, %Contract.Event{}}` feed the driver's
#     forwarder consumes -- the Tap is just one more subscriber).
#   * The Tap batches: PubSub broadcast at most every 100ms, carrying
#     the new entries plus the latest tree and the set of changed node
#     ids (for the devtools-style change flash).
#   * The web side is one Phoenix endpoint + one LiveView, configured
#     via Application.put_env immediately before this file is compiled
#     (the demo's `maybe_start_debug_web/0` sets the endpoint env, THEN
#     Code.require_file's this file). LiveView client JS is served
#     straight out of the phoenix / phoenix_live_view dep priv/static
#     dirs -- no asset pipeline.

defmodule Raxol.Examples.HarnessDebug.Format do
  @moduledoc false

  @doc """
  Hex/name-escape control bytes, keep printable text (incl. multibyte
  UTF-8) readable. Valid strings go through inspect's escaping (which
  renders `\\e`, `\\r`, `\\n`, ...); invalid binaries fall back to
  per-byte hex so nothing unrenderable ever reaches the page.
  """
  def escape_bytes(bin) when is_binary(bin) do
    if String.valid?(bin) do
      bin
      |> inspect(printable_limit: :infinity, limit: :infinity)
      |> String.slice(1..-2//1)
    else
      bin
      |> :binary.bin_to_list()
      |> Enum.map_join(fn b ->
        "\\x" <> String.pad_leading(Integer.to_string(b, 16), 2, "0")
      end)
    end
  end

  def escape_bytes(other), do: inspect(other)

  def truncate(text, max \\ 400)

  def truncate(text, max) when is_binary(text) do
    if String.length(text) > max do
      String.slice(text, 0, max) <> " …(#{String.length(text)} chars)"
    else
      text
    end
  end

  def truncate(other, max), do: truncate(inspect(other), max)
end

defmodule Raxol.Examples.HarnessDebug.TreeBuilder do
  @moduledoc false
  # `to_debug_tree`: the ONE contract between the Surface model and the
  # devtools tree pane. Input: the LiveSessionDriver's loop state (via
  # its `:debug_state_probe` seam). Output: a plain nested node map --
  #   %{id, label, attrs: [{name, value}], lines: [String], children: []}
  # -- ids are stable paths so the LiveView can diff/flash/collapse.

  alias Raxol.Examples.HarnessDebug.Format

  @max_block_lines 30

  def build(%{model: model} = driver_state) do
    node(
      "root",
      "Surface",
      [
        {"mode", inspect(model.mode)},
        {"size", "#{model.width}x#{model.rows}"},
        {"footer_rows", to_string(model.footer_rows)},
        {"stream_open?", inspect(model.stream_open?)},
        {"composing?", inspect(model.composing?)}
      ],
      [],
      [
        history_node(model),
        footer_node(model),
        session_node(driver_state, model)
      ]
    )
  end

  def build(_other), do: nil

  @doc "Ids of nodes whose attrs/lines changed between two trees."
  def changed_ids(nil, _new), do: MapSet.new()

  def changed_ids(old, new) do
    old_index = index(old, %{})
    collect_changed(new, old_index, MapSet.new())
  end

  defp index(nil, acc), do: acc

  defp index(node, acc) do
    acc = Map.put(acc, node.id, {node.attrs, node.lines})
    Enum.reduce(node.children, acc, &index/2)
  end

  defp collect_changed(node, old_index, acc) do
    acc =
      case Map.get(old_index, node.id) do
        {attrs, lines} when attrs == node.attrs and lines == node.lines -> acc
        _changed_or_new -> MapSet.put(acc, node.id)
      end

    Enum.reduce(node.children, acc, &collect_changed(&1, old_index, &2))
  end

  # -- history -----------------------------------------------------------------

  defp history_node(model) do
    blocks = model.projection.blocks
    painted = model.painted_count

    children =
      blocks
      |> Enum.with_index()
      |> Enum.map(fn {block, i} -> block_node(block, i, painted, model) end)

    node(
      "history",
      "history",
      [
        {"blocks", to_string(length(blocks))},
        {"painted/sealed", to_string(painted)},
        {"damaged?", inspect(model.projection.damaged)},
        {"revealed_events", to_string(model.revealed)}
      ],
      [],
      children
    )
  end

  defp block_node(block, i, painted, model) do
    lines = block_lines(block)
    held? = i >= painted

    fold =
      Map.get(model.fold_overrides, block.event_refs, nil) || block.fold

    node(
      "history.#{i}",
      "block[#{i}] #{block.kind}",
      [
        {"seal", inspect(block.seal)},
        {"held?", inspect(held?)},
        {"fold", inspect(fold)},
        {"outcome", inspect(block.outcome)},
        {"lines", to_string(length(lines))}
      ] ++ focus_attr(model, i),
      Enum.take(lines, @max_block_lines),
      []
    )
  end

  defp focus_attr(%{focused_index: i}, i) when is_integer(i),
    do: [{"focused", "true"}]

  defp focus_attr(_model, _i), do: []

  defp block_lines(%{content: content}) do
    text =
      content[:text] || content["text"] || content[:summary] ||
        inspect(content, limit: 30, printable_limit: 600, pretty: true)

    text
    |> to_string()
    |> String.split("\n")
    |> Enum.map(&Format.truncate(&1, 200))
  end

  # -- footer (children in paint order) -----------------------------------------

  defp footer_node(model) do
    children =
      [
        status_node(model.status),
        notice_node("footer.lane_notice", "lane_notice", model.lane_notice),
        overlay_node(model.overlay),
        expansion_node(model.expansion),
        unread_node(model.unread),
        pending_node(model),
        composer_node(model),
        notice_node("footer.stub_notice", "stub_notice", model.stub_notice)
      ]
      |> Enum.reject(&is_nil/1)

    node("footer", "footer", [], [], children)
  end

  defp status_node(status) when is_map(status) do
    attrs =
      status
      |> Enum.sort()
      |> Enum.map(fn {k, v} -> {to_string(k), Format.truncate(inspect(v), 80)} end)

    node("footer.status", "status_strip", attrs, [], [])
  end

  defp status_node(_), do: nil

  defp notice_node(_id, _label, nil), do: nil

  defp notice_node(id, label, notice) do
    lines = notice |> List.wrap() |> Enum.map(&Format.truncate(&1, 200))
    node(id, label, [{"lines", to_string(length(lines))}], lines, [])
  end

  defp overlay_node(nil), do: nil

  defp overlay_node(%{mod: mod, picker: picker}) do
    attrs =
      [{"mod", short_mod(mod)}] ++
        picked_attrs(picker, [:filter, :query, :cursor, :selected, :items])

    node("footer.overlay", "overlay", attrs, [], [])
  end

  defp expansion_node(nil), do: nil

  defp expansion_node(expansion) do
    node(
      "footer.expansion",
      "expansion",
      picked_attrs(expansion, [:total, :offset, :view_rows, :width]),
      [],
      []
    )
  end

  defp unread_node(unread) do
    node(
      "footer.unread",
      "unread_divider",
      picked_attrs(unread, [:attention, :boundary, :span]),
      [],
      []
    )
  end

  defp pending_node(%{projection: %{tail: tail}}) when map_size(tail) > 0 do
    lines =
      Enum.map(tail, fn {{turn_id, item_id}, entry} ->
        chunks = entry.chunks

        Format.truncate(
          "#{inspect(turn_id)}/#{inspect(item_id)} #{entry.item_type} " <>
            "(#{length(chunks)} chunks): #{List.last(chunks) || ""}",
          200
        )
      end)

    node(
      "footer.pending",
      "pending_preview",
      [{"tail_entries", to_string(length(lines))}],
      lines,
      []
    )
  end

  defp pending_node(_model), do: nil

  defp composer_node(model) do
    value = Raxol.UI.Components.Harness.Composer.value(model.composer)

    # composer is a plain map; mli may be a struct -- no Access there.
    cursor =
      case Map.get(model.composer, :mli) do
        %{cursor_pos: pos} -> pos
        _ -> nil
      end

    node(
      "footer.composer",
      "composer",
      [
        {"cursor", inspect(cursor)},
        {"chars", to_string(String.length(value))},
        {"focused", inspect(model.composing?)}
      ],
      if(value == "",
        do: [],
        else: Enum.map(String.split(value, "\n"), &Format.truncate(&1, 200))
      ),
      []
    )
  end

  # -- session ------------------------------------------------------------------

  defp session_node(driver_state, model) do
    node(
      "session",
      "session",
      [
        {"current_turn_id", Format.truncate(inspect(driver_state.current_turn_id), 40)},
        {"session_over?", inspect(driver_state.session_over?)},
        {"stream_open?", inspect(model.stream_open?)},
        {"steer_in_flight?", inspect(driver_state.steer_task != nil)},
        {"cadence_alive?", inspect(alive?(driver_state.cadence))},
        {"forwarder_alive?", inspect(alive?(driver_state.forwarder))}
      ],
      [],
      []
    )
  end

  defp alive?(pid) when is_pid(pid), do: Process.alive?(pid)
  defp alive?(_), do: false

  # -- helpers -------------------------------------------------------------------

  defp node(id, label, attrs, lines, children) do
    %{id: id, label: label, attrs: attrs, lines: lines, children: children}
  end

  defp picked_attrs(map, keys) when is_map(map) do
    for key <- keys, Map.has_key?(map, key) do
      {to_string(key), Format.truncate(inspect(Map.get(map, key)), 80)}
    end
  end

  defp picked_attrs(_other, _keys), do: []

  defp short_mod(mod), do: mod |> Module.split() |> List.last()
end

defmodule Raxol.Examples.HarnessDebug.DeviceTee do
  @moduledoc false
  # Erlang I/O-protocol proxy: forwards writes to the real device AND
  # copies them to the Tap. See header notes.

  alias Raxol.Examples.HarnessDebug.Tap

  def start_link(real_device, tap) do
    pid = spawn_link(fn -> loop(real_device, tap) end)
    {:ok, pid}
  end

  defp loop(real, tap) do
    receive do
      {:io_request, from, reply_as, req} ->
        handle_request(req, from, reply_as, real, tap)
        loop(real, tap)

      _other ->
        loop(real, tap)
    end
  end

  defp handle_request({:put_chars, _enc, chars}, from, reply_as, real, tap) do
    write_and_tee(chars, real, tap)
    io_reply(from, reply_as, :ok)
  end

  defp handle_request({:put_chars, chars}, from, reply_as, real, tap) do
    write_and_tee(chars, real, tap)
    io_reply(from, reply_as, :ok)
  end

  defp handle_request({:put_chars, _enc, mod, fun, args}, from, reply_as, real, tap) do
    write_and_tee(apply(mod, fun, args), real, tap)
    io_reply(from, reply_as, :ok)
  rescue
    _ -> io_reply(from, reply_as, {:error, :put_chars})
  end

  defp handle_request({:requests, reqs}, from, reply_as, real, tap) do
    Enum.each(reqs, fn req ->
      handle_request(req, self(), make_ref(), real, tap)
    end)

    # Drain our own synthetic replies so they never leak.
    drain_own_replies(length(reqs))
    io_reply(from, reply_as, :ok)
  end

  # Reads / geometry / everything else: hand the whole request to the
  # real device's owner process, which will reply straight to `from`.
  defp handle_request(other, from, reply_as, real, _tap) do
    send(device_pid(real), {:io_request, from, reply_as, other})
  end

  defp drain_own_replies(0), do: :ok

  defp drain_own_replies(n) do
    receive do
      {:io_reply, _ref, _res} -> drain_own_replies(n - 1)
    after
      0 -> :ok
    end
  end

  defp write_and_tee(chars, real, tap) do
    bin = IO.iodata_to_binary([chars])
    IO.write(real, bin)
    Tap.device_write(tap, bin)
  end

  defp io_reply(from, reply_as, result) when is_pid(from),
    do: send(from, {:io_reply, reply_as, result})

  defp io_reply(_from, _reply_as, _result), do: :ok

  defp device_pid(:stdio), do: Process.group_leader()
  defp device_pid(:standard_io), do: Process.group_leader()
  defp device_pid(pid) when is_pid(pid), do: pid
  defp device_pid(atom) when is_atom(atom), do: Process.whereis(atom) || Process.group_leader()
end

defmodule Raxol.Examples.HarnessDebug.Tap do
  @moduledoc false
  # The collector: monotonic seq numbers + timestamps on every entry,
  # snapshot pulls off the LiveSessionDriver, 100ms-batched PubSub
  # broadcasts. See header notes.

  use GenServer

  alias Raxol.Examples.HarnessDebug.Format
  alias Raxol.Examples.HarnessDebug.TreeBuilder

  @flush_ms 100
  @snapshot_debounce_ms 40
  @max_entries 1_000
  @topic "harness_debug"
  @pubsub Raxol.Examples.HarnessDebug.PubSub

  def topic, do: @topic
  def pubsub, do: @pubsub

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  @doc "Point the tap at the running LiveSessionDriver (snapshot source)."
  def attach_driver(tap, driver), do: GenServer.call(tap, {:attach_driver, driver})

  @doc "Subscribe the tap itself to the SessionStreamer feed."
  def subscribe_session(tap, session_id),
    do: GenServer.call(tap, {:subscribe_session, session_id})

  @doc "Called by the DeviceTee with each teed write."
  def device_write(tap, bytes), do: GenServer.cast(tap, {:device_write, bytes})

  @doc "Called by the demo per keypress with the full input-path story."
  def input(tap, event, norm, resolution),
    do: GenServer.cast(tap, {:input, event, norm, resolution})

  @doc "Free-form effect/notice entry (demo lifecycle markers etc.)."
  def note(tap, label, detail \\ ""),
    do: GenServer.cast(tap, {:note, label, detail})

  @doc "Current tree + recent entries, for LiveView mount."
  def dump(tap), do: GenServer.call(tap, :dump)

  # -- server ----------------------------------------------------------------

  @impl true
  def init(_opts) do
    Process.send_after(self(), :flush, @flush_ms)

    {:ok,
     %{
       seq: 0,
       entries: [],
       pending: [],
       tree: nil,
       changed: MapSet.new(),
       tree_dirty?: false,
       driver: nil,
       snap_timer: nil
     }}
  end

  @impl true
  def handle_call({:attach_driver, driver}, _from, state) do
    {:reply, :ok, schedule_snapshot(%{state | driver: driver})}
  end

  def handle_call({:subscribe_session, session_id}, _from, state) do
    # subscribe/1 registers the CALLING process -- must run in here.
    :ok = Raxol.Agent.SessionStreamer.subscribe(session_id)
    {:reply, :ok, state}
  end

  def handle_call(:dump, _from, state) do
    {:reply,
     %{
       tree: state.tree,
       entries: Enum.reverse(state.entries),
       changed: state.changed
     }, state}
  end

  @impl true
  def handle_cast({:device_write, bytes}, state) do
    entry =
      entry(state, :device, "write #{byte_size(bytes)}B", Format.escape_bytes(bytes))

    {:noreply, state |> push(entry) |> schedule_snapshot()}
  end

  def handle_cast({:input, event, norm, resolution}, state) do
    label =
      case resolution do
        :passthrough -> "key → passthrough"
        command -> "key → #{inspect(command)}"
      end

    detail =
      "event: #{Format.truncate(inspect(event_data(event)), 200)}\n" <>
        "normalized: kind=#{inspect(norm[:kind])} char=#{inspect(norm[:char])} " <>
        "key=#{inspect(norm[:key])} mods=#{inspect(norm[:mods])}\n" <>
        "keymap: #{inspect(resolution)} (mirror context: composing, no overlay)"

    {:noreply, push(state, entry(state, :input, label, detail))}
  end

  def handle_cast({:note, label, detail}, state) do
    {:noreply, push(state, entry(state, :effect, label, detail))}
  end

  @impl true
  # Raw pre-parse tty bytes (InlineDriver :raw_sink seam).
  def handle_info({:inline_raw_input, data}, state) do
    entry =
      entry(state, :raw_input, "tty bytes (#{byte_size(data)}B)", Format.escape_bytes(data))

    {:noreply, push(state, entry)}
  end

  # SessionStreamer feed -- %Raxol.Agent.Contract.Event{} or legacy tuples.
  def handle_info({:session_event, _sid, event}, state) do
    {label, detail} = describe_session_event(event)
    {:noreply, state |> push(entry(state, :session, label, detail)) |> schedule_snapshot()}
  end

  def handle_info(:snapshot, state) do
    state = %{state | snap_timer: nil}
    {:noreply, take_snapshot(state)}
  end

  def handle_info(:flush, state) do
    Process.send_after(self(), :flush, @flush_ms)

    if state.pending == [] and not state.tree_dirty? do
      {:noreply, state}
    else
      payload = %{
        entries: Enum.reverse(state.pending),
        tree: state.tree,
        changed: state.changed
      }

      Phoenix.PubSub.broadcast(@pubsub, @topic, {:harness_debug_batch, payload})
      {:noreply, %{state | pending: [], tree_dirty?: false}}
    end
  end

  def handle_info(_other, state), do: {:noreply, state}

  # -- internals ---------------------------------------------------------------

  defp entry(state, kind, label, detail) do
    %{
      seq: state.seq + 1,
      ts_us: System.system_time(:microsecond),
      kind: kind,
      label: label,
      detail: detail
    }
  end

  defp push(state, entry) do
    %{
      state
      | seq: entry.seq,
        entries: Enum.take([entry | state.entries], @max_entries),
        pending: [entry | state.pending]
    }
  end

  defp schedule_snapshot(%{driver: nil} = state), do: state
  defp schedule_snapshot(%{snap_timer: t} = state) when t != nil, do: state

  defp schedule_snapshot(state) do
    %{state | snap_timer: Process.send_after(self(), :snapshot, @snapshot_debounce_ms)}
  end

  defp take_snapshot(%{driver: nil} = state), do: state

  # LiveSessionDriver is a plain receive loop (not a GenServer), so the
  # snapshot uses its `:debug_state_probe` observability seam rather
  # than `:sys.get_state/1`.
  defp take_snapshot(state) do
    ref = make_ref()
    send(state.driver, {:debug_state_probe, self(), ref})

    receive do
      {:debug_state_reply, ^ref, driver_state} ->
        case TreeBuilder.build(driver_state) do
          nil ->
            state

          tree ->
            changed = TreeBuilder.changed_ids(state.tree, tree)
            %{state | tree: tree, changed: changed, tree_dirty?: true}
        end
    after
      500 -> state
    end
  end

  defp event_data(%{type: type, data: data}), do: {type, data}
  defp event_data(other), do: other

  defp describe_session_event(%{type: type, tier: tier, turn_id: turn_id, payload: payload}) do
    label = "#{type} [#{tier}] turn=#{Format.truncate(inspect(turn_id), 24)}"
    {label, Format.truncate(inspect(payload, limit: 20, printable_limit: 300), 500)}
  end

  defp describe_session_event(event),
    do: {"session event", Format.truncate(inspect(event), 300)}
end

defmodule Raxol.Examples.HarnessDebug.Layouts do
  @moduledoc false
  use Phoenix.Component

  def root(assigns) do
    ~H"""
    <!DOCTYPE html>
    <html lang="en">
      <head>
        <meta charset="utf-8" />
        <meta name="csrf-token" content={Phoenix.Controller.get_csrf_token()} />
        <title>harness devtools</title>
        <style>
          :root { color-scheme: dark; }
          * { box-sizing: border-box; }
          body {
            margin: 0; background: #1e1f22; color: #bcbec4;
            font: 12px/1.45 "SF Mono", Menlo, Consolas, monospace;
          }
          .panes { display: flex; height: 100vh; }
          .pane { flex: 1; overflow: auto; padding: 8px 10px; min-width: 0; }
          .pane + .pane { border-left: 1px solid #393b40; }
          .pane h2 {
            font-size: 11px; text-transform: uppercase; letter-spacing: .08em;
            color: #6f737a; margin: 0 0 6px;
            position: sticky; top: -8px; background: #1e1f22; padding: 8px 0 4px;
          }
          /* tree pane */
          .node { margin-left: 14px; }
          .node.root { margin-left: 0; }
          .node-line { cursor: pointer; white-space: nowrap; }
          .node-line:hover { background: #2b2d30; }
          .caret { display: inline-block; width: 10px; color: #6f737a; }
          .tag { color: #d5b778; }
          .attr-name { color: #56a8f5; }
          .attr-val { color: #6aab73; }
          .leafline { color: #bcbec4; margin-left: 24px; white-space: pre; }
          .flash > .node-line { animation: flash 0.9s ease-out; }
          @keyframes flash { from { background: #43494a; } to { background: transparent; } }
          /* event pane */
          .filters { margin-bottom: 6px; color: #9da0a8; }
          .filters label { margin-right: 10px; cursor: pointer; }
          .evt { border-left: 3px solid #393b40; padding: 1px 6px; margin: 1px 0; }
          .evt .seq { color: #6f737a; margin-right: 6px; }
          .evt .lbl { color: #d5b778; }
          .evt pre {
            margin: 2px 0 2px 0; white-space: pre-wrap; word-break: break-all;
            color: #9da0a8; max-height: 8em; overflow: auto;
          }
          .evt.session { border-left-color: #6aab73; }
          .evt.input { border-left-color: #56a8f5; }
          .evt.raw_input { border-left-color: #4682b4; }
          .evt.device { border-left-color: #c77dbb; }
          .evt.effect { border-left-color: #d5b778; }
          .log { height: calc(100vh - 90px); overflow: auto; }
        </style>
      </head>
      <body>
        {@inner_content}
        <script src="/assets/phoenix.min.js"></script>
        <script src="/assets/phoenix_live_view.min.js"></script>
        <script>
          const Hooks = {
            Autoscroll: {
              mounted() { this.el.scrollTop = this.el.scrollHeight; },
              updated() {
                if (!this.el.matches(":hover")) {
                  this.el.scrollTop = this.el.scrollHeight;
                }
              }
            }
          };
          const csrf = document
            .querySelector("meta[name='csrf-token']")
            .getAttribute("content");
          const liveSocket = new window.LiveView.LiveSocket(
            "/live",
            window.Phoenix.Socket,
            { params: { _csrf_token: csrf }, hooks: Hooks }
          );
          liveSocket.connect();
        </script>
      </body>
    </html>
    """
  end
end

defmodule Raxol.Examples.HarnessDebug.DebugLive do
  @moduledoc false
  use Phoenix.LiveView

  alias Raxol.Examples.HarnessDebug.Tap

  @kinds [:session, :input, :raw_input, :device, :effect]
  @max_rendered 400

  @impl true
  def mount(_params, _session, socket) do
    tap = Application.get_env(:raxol_agent, :harness_debug_tap)

    dump =
      if tap && Process.alive?(tap),
        do: Tap.dump(tap),
        else: %{tree: nil, entries: [], changed: MapSet.new()}

    if connected?(socket) do
      Phoenix.PubSub.subscribe(Tap.pubsub(), Tap.topic())
    end

    {:ok,
     socket
     |> assign(
       tree: dump.tree,
       changed: dump.changed,
       collapsed: MapSet.new(),
       filters: MapSet.new(@kinds),
       kinds: @kinds
     )
     |> assign(entries: Enum.take(dump.entries, -@max_rendered))}
  end

  @impl true
  def handle_info({:harness_debug_batch, %{entries: new, tree: tree, changed: changed}}, socket) do
    entries = Enum.take(socket.assigns.entries ++ new, -@max_rendered)

    {:noreply,
     assign(socket,
       entries: entries,
       tree: tree || socket.assigns.tree,
       changed: changed
     )}
  end

  @impl true
  def handle_event("toggle", %{"id" => id}, socket) do
    collapsed = socket.assigns.collapsed

    collapsed =
      if MapSet.member?(collapsed, id),
        do: MapSet.delete(collapsed, id),
        else: MapSet.put(collapsed, id)

    {:noreply, assign(socket, collapsed: collapsed)}
  end

  def handle_event("filter", %{"kind" => kind}, socket) do
    kind = String.to_existing_atom(kind)
    filters = socket.assigns.filters

    filters =
      if MapSet.member?(filters, kind),
        do: MapSet.delete(filters, kind),
        else: MapSet.put(filters, kind)

    {:noreply, assign(socket, filters: filters)}
  end

  def handle_event("clear", _params, socket),
    do: {:noreply, assign(socket, entries: [])}

  @impl true
  def render(assigns) do
    ~H"""
    <div class="panes">
      <div class="pane">
        <h2>surface state</h2>
        <%= if @tree do %>
          <.tree_node node={@tree} collapsed={@collapsed} changed={@changed} root?={true} />
        <% else %>
          <div>waiting for first paint…</div>
        <% end %>
      </div>
      <div class="pane">
        <h2>
          event stream
          <button phx-click="clear" style="float:right">clear</button>
        </h2>
        <div class="filters">
          <label :for={kind <- @kinds}>
            <input
              type="checkbox"
              checked={MapSet.member?(@filters, kind)}
              phx-click="filter"
              phx-value-kind={kind}
            /> {kind}
          </label>
        </div>
        <div class="log" id="event-log" phx-hook="Autoscroll">
          <div
            :for={entry <- @entries}
            :if={MapSet.member?(@filters, entry.kind)}
            class={"evt #{entry.kind}"}
          >
            <span class="seq">#{entry.seq}</span>
            <span class="lbl">{entry.label}</span>
            <pre :if={entry.detail != ""}>{entry.detail}</pre>
          </div>
        </div>
      </div>
    </div>
    """
  end

  defp tree_node(assigns) do
    node = assigns.node
    collapsed? = MapSet.member?(assigns.collapsed, node.id)
    has_children? = node.children != [] or node.lines != []

    assigns =
      assign(assigns,
        collapsed?: collapsed?,
        has_children?: has_children?,
        n: node,
        flash?: MapSet.member?(assigns.changed, node.id)
      )

    ~H"""
    <div class={"node #{if @root?, do: "root"} #{if @flash?, do: "flash"}"}>
      <div class="node-line" phx-click={@has_children? && "toggle"} phx-value-id={@n.id}>
        <span class="caret">{caret(@has_children?, @collapsed?)}</span>
        <span class="tag">{@n.label}</span>
        <span :for={{name, value} <- @n.attrs}>
          <span class="attr-name">{name}</span>=<span class="attr-val">{value}</span>
        </span>
      </div>
      <%= unless @collapsed? do %>
        <div :for={line <- @n.lines} class="leafline">{line}</div>
        <.tree_node
          :for={child <- @n.children}
          node={child}
          collapsed={@collapsed}
          changed={@changed}
          root?={false}
        />
      <% end %>
    </div>
    """
  end

  defp caret(false, _), do: ""
  defp caret(true, true), do: "▸"
  defp caret(true, false), do: "▾"
end

defmodule Raxol.Examples.HarnessDebug.ErrorHTML do
  @moduledoc false
  def render(template, _assigns),
    do: Phoenix.Controller.status_message_from_template(template)
end

defmodule Raxol.Examples.HarnessDebug.Router do
  @moduledoc false
  use Phoenix.Router
  import Plug.Conn
  import Phoenix.Controller
  import Phoenix.LiveView.Router

  pipeline :browser do
    plug(:accepts, ["html"])
    plug(:fetch_session)
    plug(:protect_from_forgery)
    plug(:put_root_layout, html: {Raxol.Examples.HarnessDebug.Layouts, :root})
  end

  scope "/" do
    pipe_through(:browser)
    live("/", Raxol.Examples.HarnessDebug.DebugLive)
  end
end

defmodule Raxol.Examples.HarnessDebug.Endpoint do
  @moduledoc false
  use Phoenix.Endpoint, otp_app: :raxol_agent

  @session_options [
    store: :cookie,
    key: "_harness_debug",
    signing_salt: "harness-debug-demo",
    same_site: "Lax"
  ]

  socket("/live", Phoenix.LiveView.Socket,
    websocket: [connect_info: [session: @session_options]],
    longpoll: [connect_info: [session: @session_options]]
  )

  plug(:dep_assets)
  plug(Plug.Session, @session_options)
  plug(Raxol.Examples.HarnessDebug.Router)

  # LiveView client JS straight from the dep packages -- no asset build.
  defp dep_assets(%Plug.Conn{path_info: ["assets", name]} = conn, _opts)
       when name in ["phoenix.min.js", "phoenix_live_view.min.js"] do
    app = if name == "phoenix.min.js", do: :phoenix, else: :phoenix_live_view
    path = Application.app_dir(app, Path.join("priv/static", name))

    conn
    |> Plug.Conn.put_resp_content_type("text/javascript")
    |> Plug.Conn.send_file(200, path)
    |> Plug.Conn.halt()
  end

  defp dep_assets(conn, _opts), do: conn
end

defmodule Raxol.Examples.HarnessDebug do
  @moduledoc false
  # Facade the demo calls. See file header for the architecture map.

  alias Raxol.Examples.HarnessDebug.DeviceTee
  alias Raxol.Examples.HarnessDebug.Endpoint
  alias Raxol.Examples.HarnessDebug.Tap

  @doc """
  Start PubSub + Tap + DeviceTee + Endpoint. Returns
  `{:ok, %{tap: pid, device: pid, url: String.t()}}`.

  The caller (demo) is expected to have called `put_web_env!/1` BEFORE
  `Code.require_file`-ing this file, wire `device` into the
  LiveSessionDriver, `tap` into InlineDriver's `:raw_sink`, and call
  `Tap.attach_driver/2` + `Tap.subscribe_session/2` once those exist.
  """
  def start(opts) do
    real_device = Keyword.get(opts, :real_device, :stdio)
    port = Keyword.fetch!(opts, :port)

    {:ok, _} = Application.ensure_all_started(:phoenix)
    {:ok, _} = Application.ensure_all_started(:phoenix_live_view)
    {:ok, _} = Application.ensure_all_started(:plug_cowboy)

    {:ok, _pubsub} =
      Phoenix.PubSub.Supervisor.start_link(name: Raxol.Examples.HarnessDebug.PubSub)

    {:ok, tap} = Tap.start_link([])
    Application.put_env(:raxol_agent, :harness_debug_tap, tap)

    {:ok, device} = DeviceTee.start_link(real_device, tap)
    {:ok, _endpoint} = Endpoint.start_link([])

    {:ok, %{tap: tap, device: device, url: "http://localhost:#{port}/"}}
  end

  @doc """
  Endpoint config -- MUST run before this file is compiled (Phoenix
  endpoints read pieces of their config at compile time), so the demo
  calls this via the tiny bootstrap in `harness_debug_env.exs`.
  """
  def resolve_port do
    case System.get_env("RAXOL_DEV_PORT") do
      nil -> 4001
      explicit -> String.to_integer(explicit)
    end
  end
end
