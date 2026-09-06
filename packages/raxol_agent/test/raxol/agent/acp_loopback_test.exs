defmodule Raxol.Agent.AcpLoopbackTest do
  @moduledoc """
  The ACP loopback (ADR-0034, "Validation"): `bin/raxol-acp` spawned as a REAL
  peer through `Raxol.AgentClientProtocol.Transport.Stdio.start_spawn/3`,
  driven through `Raxol.AgentClientProtocol.Client` (`initialize`,
  `session/new`, `session/prompt`), with the peer's `session/update` frames fed
  into `Raxol.Agent.AcpStreamAdapter` and asserted as an ordered
  `Raxol.Agent.Contract.Event` stream.

  Three things had never met each other before this test. `start_spawn/3`'s
  only spawn coverage drove `cat`, `printf`, `true` and `false`; the adapter's
  751 lines were exercised only by hand-fed frames; and the "stdout is
  protocol-pure" warning at `Transport.Stdio`'s moduledoc had no test at all.
  No third-party install and no network: the `mock` backend is in
  `Raxol.Agent.Backend.Selector`'s table, so `--backend mock` resolves with no
  credential.

  ## What the peer needs in its environment, and why

    * `ELIXIR_ERL_OPTIONS=-noinput` is REQUIRED, not tuning. Without it the
      peer never reads a single frame: erts' own `prim_tty` resource holds
      fd 0, so `Transport.Stdio.start_self/1`'s `Port.open({:fd, 0, 1})` logs
      `driver_select(...) stealing control of fd=0 from resource
      prim_tty:tty` and inbound stdin never reaches the transport. Measured on
      both OTP 26/Elixir 1.18.3 and OTP 29/Elixir 1.20.2: zero replies until
      the client's timeout, versus a full turn in under three seconds with
      `-noinput`. `bin/raxol-acp` does not set it, which is a peer-side defect
      this test works around rather than hides.
    * `MIX_ENV=dev` pins the peer to the same build the `setup_all` pre-warm
      compiles. `bin/raxol-acp` sets no `MIX_ENV`, so dev is what a human
      launching the shim gets; inheriting `test` from the runner would send
      the peer to a different build tree and a different config.
    * `RAXOL_SESSIONS_DIR` keeps the peer's journal out of the real
      `~/.raxol` -- `test_helper.exs` does this for the test BEAM, and the
      peer is a separate OS process that needs its own redirect.

  ## Stdout purity, and the one line our own peer leaks

  `Connection` adopts the Stdio handle as its EXCLUSIVE owner
  (`set_owner/2`), and a non-JSON line is reported only on that owner channel
  (`{:decode_error, reason, raw_line}`), so a second observer cannot exist
  downstream of it. `WireTap` therefore interposes one forwarding process
  between the port reader and the `Connection`: the real `Transport` behaviour,
  the real `Stdio` underneath, one extra hop that copies each inbound event to
  this test. One forwarder means one sender, so the Connection's per-sender
  FIFO delivery invariants are untouched.

  What that measured, and what it fixed: `bin/raxol-acp` used to put non-JSON
  on the protocol pipe on EVERY launch. The shim compiled quietly to stderr
  and then `exec`ed `mix raxol.acp`, but that second Mix invocation re-runs
  loadpaths, where `raxol_terminal`'s `:elixir_make` NIF step is never fresh,
  so Mix printed dep headers (`==> raxol_terminal`, and `Compiling N files`
  when a dep needed work) to stdout before the transport bound. The shim now
  runs the task through `mix run --no-deps-check`, which parses before any
  project loadpaths, and it detaches the compile step from stdin so that step
  cannot swallow the client's first frame either.

  So the assertion is absolute rather than split: NO non-JSON line may reach
  the pipe, before or after frame one. A stray `IO.puts/1` or a `Logger`
  handler on `:user` fails this test, which is the class `Transport.Stdio`
  warns about.

  ## The assistant's answer, and how it got here

  This loopback originally measured ZERO `session/update` frames for a
  mock-backed turn, and that finding was the defect: every ACP turn carries
  the full toolset (`Serve.turn_opts/1`), so it runs
  `Raxol.Agent.Stream.react/2`'s framework loop, which reports the whole
  answer once as `{:done, info}` and never a `{:text_delta, _}` -- and
  `TurnRunner` mapped `{:done, _}` straight to a stop, so the assistant's text
  never became an `agent_message_chunk` for ANY backend. The library said so
  itself on the peer's stderr: "turn completed (stopReason: :end_turn) with
  zero session/update notifications for a non-empty prompt".

  `TurnRunner`'s `{:done, _}` arm now posts that terminal content when the
  turn streamed no deltas, so the answer reaches the client. This test asserts
  it end to end: the middle of the stream must carry a durable assistant
  `:message` item with non-empty content.

  The ordered stream is therefore asserted as an exact PREFIX (the turn
  bracket and the user echo, which the adapter produces from `begin_turn/2`
  alone), a required assistant answer plus a type whitelist in between, and an
  exact terminal (`:turn_completed`, `final: true`). A peer that streams its
  answer as deltas instead of one chunk still passes; a peer that fabricates a
  completion, cancels, errors, or answers nothing fails. The answer's WORDING
  is not pinned -- that belongs to the mock backend, not to this contract.
  `usage` is deliberately unasserted.

  Run with: `mix test test/raxol/agent/acp_loopback_test.exs --include integration`

  ## Invariant sentinel

  Armed here because this is the only test that drives a REAL peer. Note the
  boundary honestly: the peer is a separate OS process, so ITS telemetry stays
  in ITS BEAM. What the sentinel covers is the client side running in this
  BEAM -- the transport, the `Connection`, and the adapter fold -- which is
  where a peer's frames actually get interpreted. The module is already
  `async: false`, which the sentinel requires.
  """

  use ExUnit.Case, async: false
  use Raxol.Agent.Test.InvariantSentinel

  @moduletag :integration
  @moduletag :capture_log

  # The peer is a full BEAM boot behind a Mix task, and `setup_all` pre-warms
  # the build it boots from, so the module budget is minutes even though each
  # request inside a test is bounded in seconds.
  @moduletag timeout: 900_000

  alias Raxol.Agent.AcpStreamAdapter
  alias Raxol.Agent.Contract.Event
  alias Raxol.Agent.SessionStreamer
  alias Raxol.AgentClientProtocol.Client
  alias Raxol.AgentClientProtocol.Connection
  alias Raxol.AgentClientProtocol.Schema.AgentTypes.InitializeRequest
  alias Raxol.AgentClientProtocol.Schema.AgentTypes.InitializeResponse
  alias Raxol.AgentClientProtocol.Schema.AgentTypes.NewSessionRequest
  alias Raxol.AgentClientProtocol.Schema.AgentTypes.NewSessionResponse
  alias Raxol.AgentClientProtocol.Schema.AgentTypes.PromptRequest
  alias Raxol.AgentClientProtocol.Schema.AgentTypes.PromptResponse
  alias Raxol.AgentClientProtocol.Schema.ContentBlock
  alias Raxol.AgentClientProtocol.Transport.Stdio

  @agent_dir Path.expand("../../..", __DIR__)
  @repo_root Path.expand("../..", @agent_dir)
  @peer Path.join(@repo_root, "bin/raxol-acp")

  # Bounded, and deliberately short. A regression must fail in seconds rather
  # than stall CI: the handshake budget covers a BEAM boot plus `app.start`
  # (measured under 3s warm), the prompt budget a mock-backed turn (measured
  # under 300ms).
  @boot_ms 60_000
  @request_ms 15_000
  @turn_ms 30_000
  @event_ms 5_000

  # Content events a streaming peer would add between the user echo and the
  # terminal bracket. Anything else (an `:error` marker, a second
  # `:turn_started`) fails the ordered assertion.
  @content_types [:item_started, :item_delta, :item_completed]
  @terminal_types [:turn_completed, :turn_canceled, :error]

  # ==========================================================================
  # WireTap -- the byte-level observer (see the moduledoc)
  # ==========================================================================

  defmodule WireTap do
    @moduledoc """
    A `Raxol.AgentClientProtocol.Transport` that IS `Transport.Stdio`, with one
    forwarding hop inserted between the port reader and the `Connection` so a
    test can see every inbound transport event -- frames AND the
    `{:decode_error, reason, raw_line}` reports that are the only evidence a
    non-JSON line reached the protocol pipe.

    `:pid` carries the underlying Stdio carrier pid, because `Connection`
    reads exactly that field to resolve the carrier it monitors and to stamp
    `transport_ref`; forwarded events keep the carrier's own tag, so they are
    never mistaken for a stale ref.
    """

    @behaviour Raxol.AgentClientProtocol.Transport

    alias Raxol.AgentClientProtocol.Transport.Stdio

    defstruct [:pid, :stdio, :tap]

    @type t :: %__MODULE__{pid: pid(), stdio: Stdio.t(), tap: pid()}

    @doc "Wrap an Stdio handle, reporting a copy of every inbound event to `report_to`."
    @spec wrap(Stdio.t(), pid()) :: t()
    def wrap(%Stdio{pid: carrier} = stdio, report_to) do
      tap = spawn_link(fn -> await_owner(report_to) end)
      %__MODULE__{pid: carrier, stdio: stdio, tap: tap}
    end

    @impl true
    def send_message(%__MODULE__{stdio: stdio} = handle, message) do
      case Stdio.send_message(stdio, message) do
        {:ok, _stdio} -> {:ok, handle}
        {:error, _reason} = error -> error
      end
    end

    @impl true
    def close(%__MODULE__{stdio: stdio}), do: Stdio.close(stdio)

    @doc "Point the underlying transport at the tap, and the tap at `conn`."
    @spec set_owner(t(), pid()) :: :ok
    def set_owner(%__MODULE__{stdio: stdio, tap: tap}, conn) do
      # Ordered by causality, not by timing: the tap learns its Connection
      # before `set_owner/2` returns, and Stdio flushes its pre-adoption
      # buffer only inside that call, so no frame can overtake the owner.
      send(tap, {:wire_tap_owner, conn})
      Stdio.set_owner(stdio, tap)
    end

    defp await_owner(report_to) do
      receive do
        {:wire_tap_owner, conn} -> forward(conn, report_to)
      end
    end

    defp forward(conn, report_to) do
      receive do
        {:acp_transport, _ref, event} = message ->
          send(report_to, {:wire, event})
          send(conn, message)

        _other ->
          :ok
      end

      forward(conn, report_to)
    end
  end

  # ==========================================================================
  # A client that only needs the generated plumbing
  # ==========================================================================

  defmodule LoopbackClient do
    @moduledoc """
    The whole client role for this loopback: `use Client` keeps the GENERATED
    `session_update/2`, which is the precondition `Client.prompt/3` documents
    (override it and the turn channel silently yields nothing). No `fs_sandbox`
    and no `terminal/*` handlers, because a mock-backed turn makes no tool
    call, so no filesystem or terminal request is ever raised -- an
    unadvertised capability answered `-32601` is the honest default.
    """

    use Raxol.AgentClientProtocol.Client
  end

  # ==========================================================================
  # Setup
  # ==========================================================================

  setup_all do
    unless File.exists?(@peer) do
      flunk("ACP loopback peer missing: #{@peer}")
    end

    # WHY pre-warm: `bin/raxol-acp` compiles quietly to stderr before it
    # `exec`s the task, and on a cold tree that step is MINUTES -- longer than
    # any bounded handshake timeout should be. Doing it here turns "the build
    # was cold or broken" into an explicit setup failure carrying the
    # compiler's own output, instead of a mysterious handshake timeout inside
    # the test. `mix` resolves from this BEAM's environment, the same way the
    # spawned peer resolves it, so both run the same toolchain.
    {output, status} =
      System.cmd("mix", ["compile"],
        cd: @agent_dir,
        env: [{"MIX_ENV", "dev"}, {"MAKEFLAGS", "-s"}],
        stderr_to_stdout: true
      )

    if status != 0 do
      flunk("""
      the loopback peer cannot boot: `MIX_ENV=dev mix compile` failed in #{@agent_dir}

      #{String.slice(output, -4_000, 4_000)}
      """)
    end

    :ok
  end

  setup do
    # `Client.start_link/2` links its ConnectionSupervisor here, and that
    # supervisor is `one_for_all` with `auto_shutdown: :any_significant` over a
    # significant Connection -- so a peer that exits (its own boot failure, or
    # our `close/1` at the end of a passing turn) exits :shutdown INTO this
    # process. `Serve.run/1` traps the same signal for the same reason.
    Process.flag(:trap_exit, true)

    start_supervised!({SessionStreamer, []})

    tmp = Path.join(System.tmp_dir!(), "acp_loopback_#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(tmp, "sessions"))
    on_exit(fn -> File.rm_rf(tmp) end)

    %{tmp: tmp}
  end

  # ==========================================================================
  # The loopback
  # ==========================================================================

  describe "bin/raxol-acp over Transport.Stdio" do
    test "initialize, session/new and session/prompt drive an ordered event stream",
         %{tmp: tmp} do
      peer = spawn_peer(tmp, ["--backend", "mock"])

      {:ok, sup} = Client.start_link(LoopbackClient, transport: {WireTap, peer.handle})
      {:ok, conn} = Client.connection(sup)

      # -- initialize: no other request is legal before it --
      assert {:ok, %InitializeResponse{} = init} =
               Connection.request(conn, "initialize", InitializeRequest.new(1), @boot_ms)

      assert init.protocol_version == 1
      assert %{name: "raxol"} = init.agent_info

      # -- session/new: the peer scopes its fs tools to this cwd --
      assert {:ok, %NewSessionResponse{session_id: acp_session_id}} =
               Connection.request(conn, "session/new", NewSessionRequest.new(tmp), @request_ms)

      assert is_binary(acp_session_id)

      # -- the adapter: one contract session, subscribed before the turn opens --
      contract_session = "acp-loopback-#{System.unique_integer([:positive])}"
      :ok = SessionStreamer.subscribe(contract_session)
      {:ok, adapter} = AcpStreamAdapter.start_link(session_id: contract_session)

      prompt = "say hi"
      {:ok, turn_id} = AcpStreamAdapter.begin_turn(adapter, prompt)

      # -- session/prompt: `prompt_stream/4`'s direct channel, not
      # `subscribe/3`. Both feed the adapter, but only the direct channel
      # guarantees wire order (subscribe fans out through one dispatch task
      # PER notification), and an ordered assertion needs an ordered feed.
      assert {:ok, %PromptResponse{stop_reason: :end_turn} = response} =
               Client.prompt_stream(
                 conn,
                 PromptRequest.new(acp_session_id, [ContentBlock.from_string(prompt)]),
                 &send(adapter, {:acp_session_update, acp_session_id, &1}),
                 @turn_ms
               )

      :ok = AcpStreamAdapter.finish_turn(adapter, response)

      # -- the ordered event stream --
      assert %Event{type: :turn_started, tier: :durable, turn_id: ^turn_id, payload: started} =
               next_event(contract_session)

      assert started == %{prompt: prompt}

      assert %Event{type: :item_started, tier: :durable, payload: %{item_type: :message}} =
               next_event(contract_session)

      assert %Event{type: :item_completed, tier: :durable, payload: echo} =
               next_event(contract_session)

      assert %{item_type: :message, role: :user, content: ^prompt} = echo

      {middle, terminal} = collect_to_terminal(contract_session)

      for event <- middle do
        assert event.type in @content_types,
               "unexpected event between the user echo and the terminal bracket: " <>
                 inspect(event)
      end

      # The answer itself, which is the thing a client is here for. Before
      # TurnRunner posted terminal content this list was empty and the turn
      # delivered a stop reason and nothing else. The adapter seals the
      # accumulated chunks as one durable :message item keyed
      # "<turn_id>-assistant"; the user echo above is the same item_type, so
      # the item_id is what distinguishes the answer from the prompt.
      assistant_id = "#{turn_id}-assistant"

      answers =
        for %Event{type: :item_completed, tier: :durable, payload: payload} <- middle,
            match?(%{item_type: :message, item_id: ^assistant_id}, payload),
            do: payload.content

      assert answers != [],
             "the peer completed the turn without delivering an assistant message: " <>
               inspect(middle)

      assert [answer] = answers
      assert is_binary(answer) and answer != ""

      assert %Event{type: :turn_completed, tier: :durable, turn_id: ^turn_id} = terminal
      assert %{final: true, stop_reason: :end_turn} = terminal.payload

      # The bracket is the end of the stream, not a pause inside it.
      refute_receive {:session_event, ^contract_session, _event}, 100

      # -- stdout purity --
      #
      # Nothing non-JSON at all, preamble included. This used to tolerate a
      # Mix build-chatter preamble, because `bin/raxol-acp` ran the task
      # through `mix <task>`, whose loadpaths pass announces dep work on stdout
      # before the task can install a quiet shell. The shim now runs the task
      # via `mix run --no-deps-check`, so the whole pipe is protocol -- and a
      # strict NDJSON client (which a real editor may well be) has nothing to
      # choke on. Keeping the old tolerance would let that regress unnoticed.
      wire = drain_wire()
      assert Enum.any?(wire, &match?({:message, _}, &1)), "the peer sent no JSON frame at all"

      non_json = for {:decode_error, _reason, raw} <- wire, do: raw

      assert non_json == [],
             "non-JSON lines on the protocol pipe: #{inspect(non_json)}"

      # -- no orphan on the pass path (the failure path is `on_exit`'s belt) --
      :ok = Stdio.close(peer.stdio)
      assert_peer_reaped(peer.os_pid)
    end

    test "a peer that dies at boot resolves the handshake as an error instead of hanging",
         %{tmp: tmp} do
      # `--not-a-real-flag` trips `Serve.run/1`'s strict OptionParser, which
      # prints usage to stderr and exits 64 before any transport binds.
      peer = spawn_peer(tmp, ["--not-a-real-flag"])

      {:ok, sup} = Client.start_link(LoopbackClient, transport: {WireTap, peer.handle})
      {:ok, conn} = Client.connection(sup)

      # A dead peer must resolve the parked request, not park forever. Run it
      # off-process so a Connection that stops mid-call is observed as an exit
      # rather than crashing this test: either resolution is clean, a hang is
      # not.
      task =
        Task.async(fn ->
          Connection.request(conn, "initialize", InitializeRequest.new(1), @boot_ms)
        end)

      outcome = Task.yield(task, @boot_ms) || Task.shutdown(task, :brutal_kill)

      case outcome do
        {:ok, result} ->
          assert match?({:error, _reason}, result),
                 "a dead peer must resolve the handshake as an error, got #{inspect(result)}"

        {:exit, _reason} ->
          # The Connection stopped with the transport before it could reply.
          # Also a resolution, and also bounded.
          :ok

        nil ->
          flunk("the handshake against a dead peer never resolved")
      end

      assert_peer_reaped(peer.os_pid)
    end
  end

  # ==========================================================================
  # Helpers
  # ==========================================================================

  defp spawn_peer(tmp, args) do
    handle =
      case Stdio.start_spawn(@peer, args, cd: tmp, env: peer_env(tmp)) do
        {:ok, handle} ->
          handle

        {:error, :executable_not_found} ->
          flunk("ACP loopback peer is not executable: #{@peer}")
      end

    os_pid = peer_os_pid(handle)

    on_exit(fn ->
      Stdio.close(handle)
      kill_peer(os_pid)
    end)

    %{stdio: handle, handle: WireTap.wrap(handle, self()), os_pid: os_pid}
  end

  # Charlists, not binaries: `:env` goes straight to `Port.open/2`.
  defp peer_env(tmp) do
    [
      {~c"ELIXIR_ERL_OPTIONS", ~c"-noinput"},
      {~c"MIX_ENV", ~c"dev"},
      {~c"MAKEFLAGS", ~c"-s"},
      {~c"RAXOL_SESSIONS_DIR", String.to_charlist(Path.join(tmp, "sessions"))}
    ]
  end

  # The port is owned by the Stdio GenServer, so the OS pid is reachable only
  # through the port table -- and only while the port is open, hence at spawn.
  defp peer_os_pid(%Stdio{pid: carrier}) do
    Enum.find_value(Port.list(), fn port ->
      with {:connected, ^carrier} <- Port.info(port, :connected),
           {:os_pid, os_pid} <- Port.info(port, :os_pid) do
        os_pid
      else
        _other -> nil
      end
    end)
  end

  defp next_event(session_id) do
    assert_receive {:session_event, ^session_id, %Event{} = event}, @event_ms
    event
  end

  defp collect_to_terminal(session_id, acc \\ []) do
    event = next_event(session_id)

    if event.type in @terminal_types do
      {Enum.reverse(acc), event}
    else
      collect_to_terminal(session_id, [event | acc])
    end
  end

  defp drain_wire(acc \\ []) do
    receive do
      {:wire, event} -> drain_wire([event | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  # Closing our end EOFs the peer's stdin, which `Serve.run/1` answers by
  # returning 0 -- so the OS process going away is the assertion, and a
  # surviving one is a leaked BEAM per test run.
  defp assert_peer_reaped(nil), do: flunk("could not resolve the peer's OS pid")

  defp assert_peer_reaped(os_pid) do
    wait_until(fn -> not os_alive?(os_pid) end, "peer OS process #{os_pid} outlived the test")
  end

  defp kill_peer(nil), do: :ok

  defp kill_peer(os_pid) do
    if os_alive?(os_pid), do: System.cmd("kill", ["-9", Integer.to_string(os_pid)])
    :ok
  end

  defp os_alive?(os_pid) do
    {_out, status} =
      System.cmd("kill", ["-0", Integer.to_string(os_pid)], stderr_to_stdout: true)

    status == 0
  end

  # Bounded converge-poll, the shape the ACP package's own integration suite
  # uses. Only ever applied to OS-level state, never to an event assertion --
  # those are `assert_receive` with an explicit budget.
  defp wait_until(fun, message, tries \\ 400) do
    cond do
      fun.() -> :ok
      tries <= 0 -> flunk(message)
      true -> Process.sleep(5) && wait_until(fun, message, tries - 1)
    end
  end
end
