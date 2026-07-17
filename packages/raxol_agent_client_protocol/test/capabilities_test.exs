# Fail-closed capability gate (W17-caps; delete/close/auth leaves closed by
# W7a / parked review item 5). Two tiers:
#
#   1. Pure-predicate matrix over `Capabilities.negotiated?/2` and the
#      `MethodTable` capability column: no-requirement methods always pass;
#      gated methods deny on absent/false/nil caps; the (now closed)
#      session/delete|close|logout oracle-divergence rows gate live on real
#      leaves instead of failing closed unconditionally; snapshot
#      immutability; drift guard on `cap_fields/1`.
#   2. One end-to-end Paired integration: a client that never advertised
#      `terminal` rejects the agent's `terminal/create` with `-32601`, BEFORE
#      decode (proven by decode-invalid params still yielding -32601, not
#      -32602). `Connection`/`Client`/`Agent` are sibling-wave modules; the
#      integration `describe` skips (not fails) if they have not landed.
defmodule Raxol.AgentClientProtocol.CapabilitiesTest do
  use ExUnit.Case, async: true

  alias Raxol.AgentClientProtocol.Capabilities
  alias Raxol.AgentClientProtocol.MethodTable

  alias Raxol.AgentClientProtocol.Schema.AgentTypes.AgentAuthCapabilities
  alias Raxol.AgentClientProtocol.Schema.AgentTypes.AgentCapabilities
  alias Raxol.AgentClientProtocol.Schema.AgentTypes.LogoutCapabilities
  alias Raxol.AgentClientProtocol.Schema.AgentTypes.SessionCapabilities
  alias Raxol.AgentClientProtocol.Schema.AgentTypes.SessionCloseCapabilities
  alias Raxol.AgentClientProtocol.Schema.AgentTypes.SessionDeleteCapabilities
  alias Raxol.AgentClientProtocol.Schema.ClientTypes.ClientCapabilities
  alias Raxol.AgentClientProtocol.Schema.ClientTypes.FileSystemCapability
  alias Raxol.AgentClientProtocol.Schema.Unstable.SessionListCapabilities
  alias Raxol.AgentClientProtocol.Schema.Unstable.SessionResumeCapabilities

  # -- baseline (no-requirement) methods ----------------------------------

  @baseline_methods [
    "initialize",
    "authenticate",
    "session/new",
    "session/set_mode",
    "session/set_config_option",
    "session/prompt",
    "session/cancel",
    "session/request_permission",
    "session/update"
  ]

  describe "no-requirement methods are always available" do
    test "pass for every caps snapshot, including nil (pre-handshake)" do
      snapshots = [
        nil,
        %ClientCapabilities{},
        %ClientCapabilities{terminal: true},
        %AgentCapabilities{},
        %AgentCapabilities{load_session: true}
      ]

      for method <- @baseline_methods, caps <- snapshots do
        assert Capabilities.negotiated?(caps, method),
               "expected #{method} negotiated for #{inspect(caps)}"
      end
    end

    test "every baseline method really has capability: nil in the table" do
      for method <- @baseline_methods do
        assert MethodTable.capability_for(method) == :none
      end
    end
  end

  # -- client-side gate: terminal + fs ------------------------------------

  describe "terminal capability (client)" do
    @terminal_methods ~w(terminal/create terminal/output terminal/release
                         terminal/wait_for_exit terminal/kill)

    test "denied when the client omitted terminal (default false)" do
      caps = %ClientCapabilities{terminal: false}

      for method <- @terminal_methods do
        refute Capabilities.negotiated?(caps, method), "#{method} must be denied"
      end
    end

    test "denied when caps is nil (fail closed pre-handshake)" do
      for method <- @terminal_methods do
        refute Capabilities.negotiated?(nil, method)
      end
    end

    test "allowed when the client advertised terminal: true" do
      caps = %ClientCapabilities{terminal: true}

      for method <- @terminal_methods do
        assert Capabilities.negotiated?(caps, method), "#{method} must be allowed"
      end
    end
  end

  describe "filesystem capability (client) — read-only advertisement" do
    setup do
      # readTextFile only: write must be denied, read must pass.
      caps = %ClientCapabilities{
        file_system: %FileSystemCapability{read_text_file: true, write_text_file: false}
      }

      {:ok, caps: caps}
    end

    test "fs/read_text_file passes", %{caps: caps} do
      assert Capabilities.negotiated?(caps, "fs/read_text_file")
    end

    test "fs/write_text_file is denied", %{caps: caps} do
      refute Capabilities.negotiated?(caps, "fs/write_text_file")
    end

    test "both denied when file_system is absent (nil) — fail closed" do
      caps = %ClientCapabilities{file_system: nil}
      refute Capabilities.negotiated?(caps, "fs/read_text_file")
      refute Capabilities.negotiated?(caps, "fs/write_text_file")
    end

    test "both allowed when both flags true" do
      caps = %ClientCapabilities{
        file_system: %FileSystemCapability{read_text_file: true, write_text_file: true}
      }

      assert Capabilities.negotiated?(caps, "fs/read_text_file")
      assert Capabilities.negotiated?(caps, "fs/write_text_file")
    end
  end

  # -- agent-side gate: load_session + nested session caps ----------------

  describe "agent capabilities" do
    test "session/load gates on load_session (boolean leaf)" do
      refute Capabilities.negotiated?(%AgentCapabilities{load_session: false}, "session/load")
      refute Capabilities.negotiated?(%AgentCapabilities{}, "session/load")
      assert Capabilities.negotiated?(%AgentCapabilities{load_session: true}, "session/load")
    end

    test "session/list gates on session_capabilities.list (nested presence)" do
      absent = %AgentCapabilities{session_capabilities: nil}
      refute Capabilities.negotiated?(absent, "session/list")

      empty_sc = %AgentCapabilities{session_capabilities: %SessionCapabilities{list: nil}}
      refute Capabilities.negotiated?(empty_sc, "session/list")

      present = %AgentCapabilities{
        session_capabilities: %SessionCapabilities{list: %SessionListCapabilities{}}
      }

      assert Capabilities.negotiated?(present, "session/list")
    end
  end

  # -- closed oracle divergences: delete/close/auth leaves (W17-caps / parked --
  # -- review item 5) now gate live instead of failing closed unconditionally --

  describe "logout gates on auth.logout (closed oracle-divergence gap)" do
    test "logout is no longer :never in the table" do
      assert MethodTable.capability_for("logout") == {:agent, [:auth, :logout]}
    end

    test "denied when auth is absent (nil), even with other caps present" do
      for caps <- [nil, %AgentCapabilities{}, %AgentCapabilities{load_session: true}] do
        refute Capabilities.negotiated?(caps, "logout")
      end
    end

    test "denied when auth is present but logout is absent" do
      caps = %AgentCapabilities{auth: %AgentAuthCapabilities{logout: nil}}
      refute Capabilities.negotiated?(caps, "logout")
    end

    test "allowed when auth.logout is present" do
      caps = %AgentCapabilities{auth: %AgentAuthCapabilities{logout: %LogoutCapabilities{}}}
      assert Capabilities.negotiated?(caps, "logout")
    end
  end

  describe "session/delete and session/close gate on session_capabilities.{delete,close} (closed oracle-divergence gap)" do
    test "the table resolves real paths, not :never" do
      assert MethodTable.capability_for("session/delete") ==
               {:agent, [:session_capabilities, :delete]}

      assert MethodTable.capability_for("session/close") ==
               {:agent, [:session_capabilities, :close]}
    end

    test "denied when session_capabilities is present but delete/close are absent" do
      caps = %AgentCapabilities{
        session_capabilities: %SessionCapabilities{
          list: %SessionListCapabilities{},
          modes: true
        }
      }

      refute Capabilities.negotiated?(caps, "session/delete")
      refute Capabilities.negotiated?(caps, "session/close")
    end

    test "allowed when session_capabilities.delete/close are present" do
      caps = %AgentCapabilities{
        session_capabilities: %SessionCapabilities{
          delete: %SessionDeleteCapabilities{},
          close: %SessionCloseCapabilities{}
        }
      }

      assert Capabilities.negotiated?(caps, "session/delete")
      assert Capabilities.negotiated?(caps, "session/close")
    end

    test "each leaf gates independently (delete present, close absent, and vice versa)" do
      delete_only = %AgentCapabilities{
        session_capabilities: %SessionCapabilities{delete: %SessionDeleteCapabilities{}}
      }

      assert Capabilities.negotiated?(delete_only, "session/delete")
      refute Capabilities.negotiated?(delete_only, "session/close")

      close_only = %AgentCapabilities{
        session_capabilities: %SessionCapabilities{close: %SessionCloseCapabilities{}}
      }

      refute Capabilities.negotiated?(close_only, "session/delete")
      assert Capabilities.negotiated?(close_only, "session/close")
    end
  end

  # I18 (CORE, session-method capability parity — see test/INVARIANTS.md):
  # session/resume gates fail-closed on session_capabilities.resume, exactly
  # like the delete/close leaves above. Coverage gap closed (was schema-only).
  describe "I18 session/resume gates on session_capabilities.resume (fail-closed)" do
    test "the table resolves the real path, not :never" do
      assert MethodTable.capability_for("session/resume") ==
               {:agent, [:session_capabilities, :resume]}
    end

    test "denied when caps is nil (pre-handshake, fail closed)" do
      refute Capabilities.negotiated?(nil, "session/resume")
    end

    test "denied when session_capabilities is present but resume is absent" do
      caps = %AgentCapabilities{
        session_capabilities: %SessionCapabilities{
          list: %SessionListCapabilities{},
          modes: true
        }
      }

      refute Capabilities.negotiated?(caps, "session/resume")
    end

    test "allowed when session_capabilities.resume is present" do
      caps = %AgentCapabilities{
        session_capabilities: %SessionCapabilities{resume: %SessionResumeCapabilities{}}
      }

      assert Capabilities.negotiated?(caps, "session/resume")
    end

    test "the resume leaf gates independently of list (resume present, list absent)" do
      resume_only = %AgentCapabilities{
        session_capabilities: %SessionCapabilities{resume: %SessionResumeCapabilities{}}
      }

      assert Capabilities.negotiated?(resume_only, "session/resume")
      refute Capabilities.negotiated?(resume_only, "session/list")
    end
  end

  # -- unknown method is not a capability denial --------------------------

  test "unknown method is negotiated? true (decode, not the gate, -32601s it)" do
    assert MethodTable.capability_for("does/not/exist") == :unknown_method
    assert Capabilities.negotiated?(%ClientCapabilities{}, "does/not/exist")
  end

  # -- snapshot immutability ----------------------------------------------

  describe "snapshot immutability" do
    test "negotiated? is a pure function of the passed snapshot" do
      denied = %ClientCapabilities{terminal: false}
      granted = %ClientCapabilities{terminal: true}

      # The old snapshot keeps gating exactly as captured; a separately built
      # (\"mutated\") snapshot does not retroactively re-gate the original ref.
      refute Capabilities.negotiated?(denied, "terminal/create")
      assert Capabilities.negotiated?(granted, "terminal/create")
      # re-check the original: unchanged, deterministic
      refute Capabilities.negotiated?(denied, "terminal/create")
    end
  end

  # -- drift guard: MethodTable.cap_fields/1 vs. real struct shape ---------

  describe "cap_fields/1 mirrors the actual struct shape (invariant-7 drift guard)" do
    test "agent" do
      real =
        AgentCapabilities.__struct__()
        |> Map.keys()
        |> Kernel.--([:__struct__, :_meta])
        |> Enum.sort()

      assert Enum.sort(MethodTable.cap_fields(:agent)) == real
    end

    test "client" do
      real =
        ClientCapabilities.__struct__()
        |> Map.keys()
        |> Kernel.--([:__struct__, :_meta])
        |> Enum.sort()

      assert Enum.sort(MethodTable.cap_fields(:client)) == real
    end

    test "every gated row's first path segment is a real top-level cap field" do
      for row <- MethodTable.rows(), match?({_, _}, row.capability) do
        {side, [first | _]} = row.capability

        assert first in MethodTable.cap_fields(side),
               "#{row.wire} → #{first} not a #{side} cap field"
      end
    end
  end

  # -- end-to-end over Transport.Paired -----------------------------------

  describe "Paired integration: agent terminal/create against a no-terminal client" do
    setup do
      if Code.ensure_loaded?(Raxol.AgentClientProtocol.Connection) and
           Code.ensure_loaded?(Raxol.AgentClientProtocol.Agent) and
           Code.ensure_loaded?(Raxol.AgentClientProtocol.Client) do
        :ok
      else
        {:skip, "Connection/Agent/Client sibling-wave modules have not landed yet"}
      end
    end

    defmodule GateAgent do
      @moduledoc false
      use Raxol.AgentClientProtocol.Agent

      alias Raxol.AgentClientProtocol.Schema.AgentTypes.InitializeResponse

      @impl true
      def initialize(_req, _ctx), do: {:ok, InitializeResponse.new(1)}
    end

    defmodule GateClient do
      @moduledoc false
      use Raxol.AgentClientProtocol.Client

      alias Raxol.AgentClientProtocol.Schema.ClientTypes.CreateTerminalResponse

      # Overridden so a gate-PASS is distinguishable from a gate-DENY (both a
      # denied gate and the default callback would otherwise return -32601).
      @impl true
      def create_terminal(_req, _ctx), do: {:ok, CreateTerminalResponse.new("term-ok")}
    end

    setup do
      alias Raxol.AgentClientProtocol.Agent
      alias Raxol.AgentClientProtocol.Client
      alias Raxol.AgentClientProtocol.Transport

      {agent_handle, client_handle} = Transport.Paired.create_pair()

      {:ok, agent_sup} = Agent.start_link(GateAgent, transport: {Transport.Paired, agent_handle})

      {:ok, client_sup} =
        Client.start_link(GateClient, transport: {Transport.Paired, client_handle})

      on_exit(fn ->
        catch_exit(Supervisor.stop(agent_sup, :normal, 500))
        catch_exit(Supervisor.stop(client_sup, :normal, 500))
      end)

      {:ok, agent_conn: connection_pid(agent_sup), client_conn: connection_pid(client_sup)}
    end

    test "no-terminal client rejects terminal/create with -32601 BEFORE decode", ctx do
      alias Raxol.AgentClientProtocol.Connection
      alias Raxol.AgentClientProtocol.Error
      alias Raxol.AgentClientProtocol.Schema.AgentTypes.InitializeRequest
      alias Raxol.AgentClientProtocol.Schema.ClientTypes.ClientCapabilities

      # Client advertises terminal: false.
      init_req = %InitializeRequest{
        protocol_version: 1,
        client_capabilities: %ClientCapabilities{terminal: false}
      }

      assert {:ok, _} = Connection.request(ctx.client_conn, "initialize", init_req, 5_000)

      # No barrier needed here: `phase: :initialized` is committed inside the
      # SAME GenServer reduction that replies to this `request/4` call (see
      # `handle_inbound_response/2` -> `maybe_client_initialized/3` in
      # connection.ex) — the reply is sent before the state update, but both
      # happen with no yield point in between, so OTP's single-process
      # mailbox serialization guarantees any later message reaching this
      # connection (including the terminal/create below) observes the
      # post-commit phase. A polling wait here would be a no-op: the state it
      # waits for is already true by the time the wait could run. If this
      # test flakes again under load, the cause is NOT capability-ordering —
      # diagnose fresh (candidate: request timeout or process-start latency
      # under CPU starvation), don't paper over it with a wait.

      # Decode-INVALID params (missing sessionId/command). If the gate ran
      # AFTER decode we would see -32602; -32601 proves the gate ran first.
      assert {:error, %Error{code: -32_601}} =
               Connection.request(ctx.agent_conn, "terminal/create", %{"bogus" => true}, 5_000)
    end

    test "terminal-advertising client dispatches terminal/create (gate passes)", ctx do
      alias Raxol.AgentClientProtocol.Connection
      alias Raxol.AgentClientProtocol.Schema.AgentTypes.InitializeRequest
      alias Raxol.AgentClientProtocol.Schema.ClientTypes.ClientCapabilities
      alias Raxol.AgentClientProtocol.Schema.ClientTypes.CreateTerminalRequest

      init_req = %InitializeRequest{
        protocol_version: 1,
        client_capabilities: %ClientCapabilities{terminal: true}
      }

      assert {:ok, _} = Connection.request(ctx.client_conn, "initialize", init_req, 5_000)

      # No barrier needed — see the comment in the sibling test above:
      # `phase: :initialized` is already committed by the time this call
      # returns (single-process mailbox serialization in Connection).

      assert {:ok, %{terminal_id: "term-ok"}} =
               Connection.request(
                 ctx.agent_conn,
                 "terminal/create",
                 CreateTerminalRequest.new("sess-x", "ls"),
                 5_000
               )
    end

    defp connection_pid(sup) do
      sup
      |> Supervisor.which_children()
      |> Enum.find_value(fn
        {Raxol.AgentClientProtocol.Connection, pid, _type, _mods} -> pid
        _other -> nil
      end)
    end
  end
end
