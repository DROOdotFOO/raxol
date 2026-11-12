defmodule Raxol.Agent.AcpLoopbackTest do
  @moduledoc """
  `bin/raxol-acp --agent` spawned as a real OS process through
  `Raxol.AgentClientProtocol.Transport.Stdio.start_spawn/3` and driven by
  `Raxol.AgentClientProtocol.Client`: `initialize`, `session/new`, one
  `session/prompt`, then end of input.

  Only a process shows what this asserts:

    * the `initialize` the client writes at spawn, while the peer still
      boots, is answered (the peer reads the `user` device, so nothing it
      was sent early is lost);
    * every line on the peer's stdout is a JSON object. `WireTap` sits
      between the port reader and the `Connection`, which is the only place
      a non-JSON line is reported;
    * closing the peer's stdin ends it, and the agent's journal is whole on
      disk afterwards.

  The peer's environment: `MIX_ENV=dev` pins it to the build `setup_all`
  compiles (the shim sets no `MIX_ENV`, so dev is what a person launching it
  gets), and `RAXOL_SESSIONS_DIR` keeps its journals in the test's directory.

  Run with: `mix test test/raxol/agent/acp_loopback_test.exs --include integration`
  """

  use ExUnit.Case, async: false

  @moduletag :integration
  @moduletag :capture_log

  # The peer is a BEAM booted through Mix, and `setup_all` compiles the build
  # it boots from.
  @moduletag timeout: 900_000

  alias Raxol.Agent.Journal.FileStore
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
  @counter "Raxol.Agent.Reference.Counter"

  # The handshake budget covers a BEAM boot; the others a turn that calls no
  # model.
  @boot_ms 60_000
  @request_ms 15_000
  @turn_ms 30_000

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

  defmodule LoopbackClient do
    @moduledoc "A client with the generated callbacks only: the turn asks it nothing."
    use Raxol.AgentClientProtocol.Client
  end

  setup_all do
    unless File.exists?(@peer) do
      flunk("ACP loopback peer missing: #{@peer}")
    end

    # A cold build takes minutes, longer than a handshake may. Compiling here
    # makes a broken build a setup failure with the compiler's output.
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
    # `Client.start_link/2` links its supervisor here, and it exits
    # `:shutdown` into this process when the peer goes away.
    Process.flag(:trap_exit, true)

    tmp = Path.join(System.tmp_dir!(), "acp_loopback_#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(tmp, "sessions"))
    on_exit(fn -> File.rm_rf(tmp) end)

    %{tmp: tmp, id: "loop#{System.unique_integer([:positive])}"}
  end

  describe "bin/raxol-acp over Transport.Stdio" do
    test "serves a counter agent for one prompt and leaves its journal on disk",
         %{tmp: tmp, id: id} do
      peer = spawn_peer(tmp, ["--agent", "#{@counter}:#{id}"])

      {:ok, sup} = Client.start_link(LoopbackClient, transport: {WireTap, peer.handle})
      {:ok, conn} = Client.connection(sup)

      assert {:ok, %InitializeResponse{} = init} =
               Connection.request(conn, "initialize", InitializeRequest.new(1), @boot_ms)

      assert init.protocol_version == 1
      assert %{name: "raxol"} = init.agent_info

      assert {:ok, %NewSessionResponse{session_id: ^id}} =
               Connection.request(conn, "session/new", NewSessionRequest.new(tmp), @request_ms)

      assert {:ok, {updates, %PromptResponse{stop_reason: :end_turn}}} =
               Client.prompt(
                 conn,
                 PromptRequest.new(id, [ContentBlock.from_string("increment")]),
                 @turn_ms
               )

      assert [{:tool_call, call}, {:tool_call_update, closing}, {:agent_message_chunk, chunk}] =
               updates

      assert call.title == "Run `increment`"
      assert closing.tool_call_id == call.tool_call_id
      assert closing.fields.status == :completed
      assert {:text, %{text: "count: 1"}} = chunk.content

      :ok = Stdio.close(peer.stdio)
      assert_peer_reaped(peer.os_pid)

      wire = drain_wire()
      assert Enum.any?(wire, &match?({:message, _}, &1)), "the peer sent no JSON frame at all"
      non_json = for {:decode_error, _reason, raw} <- wire, do: raw
      assert non_json == [], "non-JSON lines on the protocol pipe: #{inspect(non_json)}"

      assert ["agent_started", "turn_started" | rest] = journal_types(tmp, id)
      assert "turn_completed" in rest
    end

    test "a peer that dies at boot resolves the handshake as an error instead of hanging",
         %{tmp: tmp} do
      # An unknown argument exits 64 before any transport starts.
      peer = spawn_peer(tmp, ["--not-a-real-flag"])

      {:ok, sup} = Client.start_link(LoopbackClient, transport: {WireTap, peer.handle})
      {:ok, conn} = Client.connection(sup)

      # Off-process: a Connection that stops mid-call is then an exit of the
      # task, not of this test.
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
          :ok

        nil ->
          flunk("the handshake against a dead peer never resolved")
      end

      assert_received {:wire, {:closed, {:exit_status, 64}}}
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

  # The documented layout: `<sessions dir>/<first 8 hex of sha256(root)>/<id>`.
  defp journal_types(tmp, id) do
    hash = :sha256 |> :crypto.hash(tmp) |> Base.encode16(case: :lower) |> binary_part(0, 8)
    base = Path.join([tmp, "sessions", hash])
    {:ok, records} = FileStore.read_records(id, base_dir: base)
    Enum.map(records, & &1["type"])
  end

  defp drain_wire(acc \\ []) do
    receive do
      {:wire, event} -> drain_wire([event | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  # Closing our end is end of input for the peer, which then exits: a
  # surviving OS process is a leaked BEAM per test run.
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
