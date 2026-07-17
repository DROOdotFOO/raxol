# SPIKE — react-devtools FRONTEND simulator (graduate or delete after V
# verdict).
#
# Speaks the standalone react-devtools 7.0.1 frontend's side of the wire
# (per the protocol notes in react_devtools_bridge.exs) so the bridge can
# be verified end-to-end in an environment where the Electron app cannot
# be interacted with. It:
#
#   1. listens as a WS SERVER (default port 8123, --port to override);
#   2. on `backendInitialized` sends the same startup volley the real
#      Store sends: getBridgeProtocol / getBackendVersion /
#      getIfHasUnsupportedRendererVersion / getHookSettings /
#      getProfilingStatus;
#   3. decodes every `operations` frame with store.js semantics (via the
#      bridge's own Ops.decode — the encoder and decoder are exercised
#      against each other) and logs the reconstructed tree;
#   4. once it has seen a Composer node and an assistant/user block, it
#      sends `highlightHostInstance` for each (hover simulation), then
#      `clearHostInstanceHighlight`, then `inspectElement` on the block;
#   5. logs the `inspectedElement` reply and every other message as JSON
#      lines to --log (default /tmp/raxol_devtools_sim.log).
#
# Run (from packages/raxol_agent):
#
#   mix run --no-start examples/spike/devtools_frontend_sim.exs \
#     --port 8123 --duration 30000

Code.require_file("react_devtools_bridge.exs", __DIR__)

defmodule Raxol.Spike.ReactDevtools.FrontendSim do
  @moduledoc false

  alias Raxol.Spike.ReactDevtools.Ops
  alias Raxol.Spike.ReactDevtools.Wire

  def run(argv) do
    {:ok, _} = Application.ensure_all_started(:crypto)

    {opts, _, _} =
      OptionParser.parse(argv,
        strict: [port: :integer, duration: :integer, log: :string]
      )

    port = Keyword.get(opts, :port, 8123)
    duration = Keyword.get(opts, :duration, 30_000)
    log = Keyword.get(opts, :log, "/tmp/raxol_devtools_sim.log")
    File.write!(log, "")

    {:ok, listener} =
      :gen_tcp.listen(port, [
        :binary,
        active: false,
        reuseaddr: true,
        nodelay: true
      ])

    log_line(log, "sim listening on ws://localhost:#{port}")
    deadline = System.monotonic_time(:millisecond) + duration

    case accept_with_deadline(listener, deadline) do
      {:ok, sock} ->
        case Wire.server_accept_upgrade(sock) do
          {:ok, leftover} ->
            log_line(log, "backend connected; ws upgrade complete")
            :ok = :inet.setopts(sock, active: true)

            state = %{
              sock: sock,
              log: log,
              buf: leftover,
              frag: nil,
              nodes: %{},
              highlighted: MapSet.new(),
              inspected?: false,
              inspected_ok?: false,
              handshake: MapSet.new()
            }

            state = loop(state, deadline)
            verdict(state)

          {:error, reason} ->
            log_line(log, "ws upgrade failed: #{inspect(reason)}")
            System.halt(2)
        end

      :timeout ->
        log_line(log, "VERDICT: no backend connected within #{duration}ms")
        System.halt(3)
    end
  end

  defp accept_with_deadline(listener, deadline) do
    remaining = max(deadline - System.monotonic_time(:millisecond), 0)

    case :gen_tcp.accept(listener, remaining) do
      {:ok, sock} -> {:ok, sock}
      {:error, :timeout} -> :timeout
    end
  end

  defp loop(state, deadline) do
    remaining = deadline - System.monotonic_time(:millisecond)

    if remaining <= 0 do
      state
    else
      receive do
        {:tcp, sock, data} when sock == state.sock ->
          {messages, rest, frag} =
            Wire.decode_frames(state.buf <> data, state.frag)

          state = %{state | buf: rest, frag: frag}
          state = Enum.reduce(messages, state, &handle_ws/2)
          loop(state, deadline)

        {:tcp_closed, _} ->
          log_line(state.log, "backend closed the connection")
          state

        _other ->
          loop(state, deadline)
      after
        remaining -> state
      end
    end
  end

  defp handle_ws({:text, raw}, state) do
    case Jason.decode(raw) do
      {:ok, %{"event" => event} = msg} ->
        handle_event(event, Map.get(msg, "payload"), state)

      _ ->
        log_line(state.log, "undecodable frame: #{String.slice(raw, 0, 200)}")
        state
    end
  end

  defp handle_ws({:ping, payload}, state) do
    :gen_tcp.send(state.sock, Wire.encode_pong(payload, false))
    state
  end

  defp handle_ws(_other, state), do: state

  # The real Store arms on backendInitialized — mimic its startup volley.
  defp handle_event("backendInitialized", _p, state) do
    log_line(
      state.log,
      "<- backendInitialized (sending frontend startup volley)"
    )

    state
    |> send_wall("getBridgeProtocol", nil)
    |> send_wall("getBackendVersion", nil)
    |> send_wall("getIfHasUnsupportedRendererVersion", nil)
    |> send_wall("getHookSettings", nil)
    |> send_wall("getProfilingStatus", nil)
  end

  defp handle_event("bridgeProtocol", %{"version" => v} = p, state) do
    log_line(state.log, "<- bridgeProtocol #{Jason.encode!(p)}")

    if v == 2 do
      %{state | handshake: MapSet.put(state.handshake, :bridge_protocol)}
    else
      log_line(state.log, "UNEXPECTED bridge protocol version #{v}")
      state
    end
  end

  defp handle_event("backendVersion", p, state) do
    log_line(state.log, "<- backendVersion #{inspect(p)}")
    %{state | handshake: MapSet.put(state.handshake, :backend_version)}
  end

  defp handle_event("hookSettings", p, state) do
    log_line(state.log, "<- hookSettings #{Jason.encode!(p)}")
    %{state | handshake: MapSet.put(state.handshake, :hook_settings)}
  end

  defp handle_event("profilingStatus", p, state) do
    log_line(state.log, "<- profilingStatus #{inspect(p)}")
    %{state | handshake: MapSet.put(state.handshake, :profiling_status)}
  end

  defp handle_event("operations", frame, state) when is_list(frame) do
    decoded = Ops.decode(frame)

    state =
      Enum.reduce(decoded.ops, state, fn
        {:add_root, id}, st ->
          log_line(st.log, "op ADD root ##{id}")
          put_in(st.nodes[id], %{name: "(root)", key: nil})

        {:add, %{id: id, name: name, key: key, parent_id: parent}}, st ->
          log_line(
            st.log,
            "op ADD ##{id} #{name} key=#{inspect(key)} parent=##{parent}"
          )

          put_in(st.nodes[id], %{name: name, key: key})

        {:remove, ids}, st ->
          log_line(st.log, "op REMOVE #{inspect(ids)}")
          %{st | nodes: Map.drop(st.nodes, ids)}

        {:reorder, id, children}, st ->
          log_line(st.log, "op REORDER ##{id} -> #{inspect(children)}")
          st

        {:undecodable_tail, tail}, st ->
          log_line(st.log, "DECODE FAILURE, tail: #{inspect(tail)}")
          st
      end)

    log_line(
      state.log,
      "tree now: " <>
        (state.nodes
         |> Enum.sort()
         |> Enum.map_join(", ", fn {id, n} -> "##{id}:#{n.name}" end))
    )

    state |> maybe_hover("Composer") |> maybe_hover_block() |> maybe_inspect()
  end

  defp handle_event("inspectedElement", p, state) do
    ok? = p["type"] == "full-data" and is_map(p["value"])

    log_line(
      state.log,
      "<- inspectedElement type=#{p["type"]} props=" <>
        Jason.encode!(get_in(p, ["value", "props", "data"]) || %{})
    )

    %{state | inspected_ok?: state.inspected_ok? or ok?}
  end

  defp handle_event(event, payload, state) do
    log_line(state.log, "<- #{event} #{String.slice(inspect(payload), 0, 200)}")
    state
  end

  # -- hover / inspect drivers ------------------------------------------------

  defp maybe_hover(state, name) do
    case find_node(state, name) do
      {id, node} ->
        if MapSet.member?(state.highlighted, id) do
          state
        else
          log_line(
            state.log,
            "SIM hover -> highlightHostInstance ##{id} (#{name})"
          )

          state
          |> send_wall("highlightHostInstance", %{
            "displayName" => node.name,
            "hideAfterTimeout" => 2000,
            "id" => id,
            "openBuiltinElementsPanel" => false,
            "rendererID" => 1,
            "scrollIntoView" => false
          })
          |> Map.update!(:highlighted, &MapSet.put(&1, id))
        end

      nil ->
        state
    end
  end

  defp maybe_hover_block(state) do
    case find_node(state, "AssistantMessage") || find_node(state, "UserPrompt") do
      {_id, node} -> maybe_hover(state, node.name)
      nil -> state
    end
  end

  defp maybe_inspect(%{inspected?: true} = state), do: state

  defp maybe_inspect(state) do
    case find_node(state, "AssistantMessage") do
      {id, _node} ->
        log_line(state.log, "SIM select -> inspectElement ##{id}")

        state
        |> send_wall("clearHostInstanceHighlight", nil)
        |> send_wall("inspectElement", %{
          "forceFullData" => true,
          "id" => id,
          "path" => nil,
          "rendererID" => 1,
          "requestID" => 1
        })
        |> Map.put(:inspected?, true)

      nil ->
        state
    end
  end

  defp find_node(state, name) do
    Enum.find(state.nodes, fn {_id, n} -> n.name == name end)
  end

  # -- verdict -----------------------------------------------------------------

  defp verdict(state) do
    handshake_ok? =
      MapSet.subset?(
        MapSet.new([:bridge_protocol, :backend_version, :hook_settings]),
        state.handshake
      )

    tree_ok? = map_size(state.nodes) > 0 and find_node(state, "Composer") != nil
    hover_ok? = MapSet.size(state.highlighted) > 0

    log_line(
      state.log,
      "VERDICT handshake=#{handshake_ok?} tree=#{tree_ok?} " <>
        "hover_sent=#{hover_ok?} inspect_ok=#{state.inspected_ok?}"
    )

    if handshake_ok? and tree_ok?, do: System.halt(0), else: System.halt(1)
  end

  # -- wire helpers --------------------------------------------------------------

  defp send_wall(state, event, payload) do
    json = Jason.encode!(%{"event" => event, "payload" => payload})
    # Server->client frames are UNMASKED per RFC6455.
    :ok = :gen_tcp.send(state.sock, Wire.encode_text(json, false))
    log_line(state.log, "-> #{event}")
    state
  end

  defp log_line(log, text) do
    ts = DateTime.utc_now() |> DateTime.to_iso8601()
    File.write!(log, "#{ts} #{text}\n", [:append])
  end
end

Raxol.Spike.ReactDevtools.FrontendSim.run(System.argv())
