# Stub policies (top-level modules) exercising every arm of the Runner funnel's
# exhaustive outcome table. Named per the P-BUS4 checklist.
defmodule Raxol.AgentClientProtocol.Ext.AttachPolicyTest.Stubs do
  @moduledoc false
  alias Raxol.AgentClientProtocol.Ext.AttachPolicy.Grant

  defmodule Ok do
    @moduledoc false
    @behaviour Raxol.AgentClientProtocol.Ext.AttachPolicy
    @impl true
    def authorize_attach(ctx) do
      {:ok,
       %Grant{
         actor: %{"id" => "a@local", "kind" => "user"},
         scope: :attach,
         session_id: ctx.session_id,
         via: :test
       }}
    end
  end

  defmodule SessionMismatch do
    @moduledoc false
    @behaviour Raxol.AgentClientProtocol.Ext.AttachPolicy
    @impl true
    def authorize_attach(_ctx) do
      {:ok,
       %Grant{
         actor: %{"id" => "a@local"},
         scope: :attach,
         session_id: "some-other-session",
         via: :test
       }}
    end
  end

  defmodule AdminScope do
    @moduledoc false
    @behaviour Raxol.AgentClientProtocol.Ext.AttachPolicy
    @impl true
    def authorize_attach(ctx) do
      {:ok,
       %Grant{
         actor: %{"id" => "a@local"},
         scope: :admin,
         session_id: ctx.session_id,
         via: :test
       }}
    end
  end

  defmodule ActorNoId do
    @moduledoc false
    @behaviour Raxol.AgentClientProtocol.Ext.AttachPolicy
    @impl true
    def authorize_attach(ctx) do
      {:ok, %Grant{actor: %{}, scope: :attach, session_id: ctx.session_id, via: :test}}
    end
  end

  defmodule ActorNonBinaryId do
    @moduledoc false
    @behaviour Raxol.AgentClientProtocol.Ext.AttachPolicy
    @impl true
    def authorize_attach(ctx) do
      {:ok,
       %Grant{
         actor: %{"id" => 123},
         scope: :attach,
         session_id: ctx.session_id,
         via: :test
       }}
    end
  end

  defmodule NilVia do
    @moduledoc false
    @behaviour Raxol.AgentClientProtocol.Ext.AttachPolicy
    @impl true
    def authorize_attach(ctx) do
      {:ok,
       %Grant{
         actor: %{"id" => "a@local"},
         scope: :attach,
         session_id: ctx.session_id,
         via: nil
       }}
    end
  end

  defmodule NotAGrant do
    @moduledoc false
    @behaviour Raxol.AgentClientProtocol.Ext.AttachPolicy
    @impl true
    def authorize_attach(_ctx), do: {:ok, %{grant: true}}
  end

  defmodule ErrorReturn do
    @moduledoc false
    @behaviour Raxol.AgentClientProtocol.Ext.AttachPolicy
    @impl true
    def authorize_attach(_ctx), do: {:error, :nope}
  end

  defmodule BareOk do
    @moduledoc false
    @behaviour Raxol.AgentClientProtocol.Ext.AttachPolicy
    @impl true
    def authorize_attach(_ctx), do: :ok
  end

  defmodule TrueReturn do
    @moduledoc false
    @behaviour Raxol.AgentClientProtocol.Ext.AttachPolicy
    @impl true
    def authorize_attach(_ctx), do: true
  end

  defmodule TripleOk do
    @moduledoc false
    @behaviour Raxol.AgentClientProtocol.Ext.AttachPolicy
    @impl true
    def authorize_attach(_ctx), do: {:ok, :grant, :extra}
  end

  defmodule Raises do
    @moduledoc false
    @behaviour Raxol.AgentClientProtocol.Ext.AttachPolicy
    @impl true
    def authorize_attach(_ctx), do: raise(ArgumentError, "boom")
  end

  defmodule Throws do
    @moduledoc false
    @behaviour Raxol.AgentClientProtocol.Ext.AttachPolicy
    @impl true
    def authorize_attach(_ctx), do: throw(:yeet)
  end

  defmodule Exits do
    @moduledoc false
    @behaviour Raxol.AgentClientProtocol.Ext.AttachPolicy
    @impl true
    def authorize_attach(_ctx), do: exit(:kaboom)
  end

  defmodule Hangs do
    @moduledoc false
    @behaviour Raxol.AgentClientProtocol.Ext.AttachPolicy
    @impl true
    def authorize_attach(ctx) do
      # Announce liveness, then hang forever — the Runner must brutal-kill us.
      case ctx[:probe] do
        pid when is_pid(pid) -> send(pid, :hang_started)
        _ -> :ok
      end

      Process.sleep(:infinity)
    end
  end
end

defmodule Raxol.AgentClientProtocol.Ext.AttachPolicyTest do
  @moduledoc """
  The fail-closed admission funnel (`acp-attachpolicy-design.md` §3.3, CDI-1).

  Exhaustive deny coverage (`INV-AP1`): EVERY policy outcome — `{:error,_}`,
  raise/throw/exit, timeout, malformed `{:ok,_}`, arbitrary term, scope∉,
  actor-without-id, session-mismatch, missing Task.Supervisor — denies; the ONLY
  allow path is a well-formed `%Grant{}` with matching session_id. Plus the
  LocalNode default (`INV-AP3, AP18`) and the anti-oracle collapse (`INV-AP10`).
  """
  use ExUnit.Case, async: false

  alias Raxol.AgentClientProtocol.Ext.AttachPolicy
  alias Raxol.AgentClientProtocol.Ext.AttachPolicy.Grant
  alias Raxol.AgentClientProtocol.Ext.AttachPolicy.LocalNode
  alias Raxol.AgentClientProtocol.Ext.AttachPolicy.Runner
  alias Raxol.AgentClientProtocol.Ext.AttachPolicyTest.Stubs

  @sid "sess-abc123"

  setup do
    sup = start_supervised!({Task.Supervisor, []})
    {:ok, sup: sup}
  end

  defp ctx(overrides \\ %{}) do
    Map.merge(
      %{
        session_id: @sid,
        actor: nil,
        surface: :tui,
        capability: nil,
        from_offset: 0,
        transport: %{kind: :process, peer: :self}
      },
      overrides
    )
  end

  defp authorize(policy, ctx, sup, opts \\ []) do
    Runner.authorize(policy, ctx, [task_supervisor: sup] ++ opts)
  end

  # -- The one allow path -----------------------------------------------------

  test "well-formed grant with matching session_id is admitted", %{sup: sup} do
    assert {:ok, %Grant{actor: %{"id" => "a@local"}, scope: :attach, session_id: @sid}} =
             authorize(Stubs.Ok, ctx(), sup)
  end

  # -- INV-AP1 exhaustive deny table (T-1..T-6, P-BUS4) ------------------------

  test "grant with mismatched session_id denies (T-6)", %{sup: sup} do
    assert {:denied, :grant_session_mismatch} =
             authorize(Stubs.SessionMismatch, ctx(), sup)
  end

  test "grant with non-allow-listed scope denies (T-25, INV-AP15)", %{sup: sup} do
    assert {:denied, :scope_not_allowed} = authorize(Stubs.AdminScope, ctx(), sup)
  end

  test "grant with actor lacking a binary id denies (T-26, INV-AP16)", %{sup: sup} do
    assert {:denied, :malformed_grant} = authorize(Stubs.ActorNoId, ctx(), sup)

    assert {:denied, :malformed_grant} =
             authorize(Stubs.ActorNonBinaryId, ctx(), sup)
  end

  test "grant with nil via denies (malformed)", %{sup: sup} do
    assert {:denied, :malformed_grant} = authorize(Stubs.NilVia, ctx(), sup)
  end

  test "ok wrapping a non-Grant denies (T-5)", %{sup: sup} do
    assert {:denied, :malformed_grant} = authorize(Stubs.NotAGrant, ctx(), sup)
  end

  test "{:error, _} return denies (T-1)", %{sup: sup} do
    assert {:denied, :policy_error} = authorize(Stubs.ErrorReturn, ctx(), sup)
  end

  test "arbitrary non-conforming terms deny (T-5)", %{sup: sup} do
    assert {:denied, :non_conforming_return} = authorize(Stubs.BareOk, ctx(), sup)
    assert {:denied, :non_conforming_return} = authorize(Stubs.TrueReturn, ctx(), sup)
    assert {:denied, :non_conforming_return} = authorize(Stubs.TripleOk, ctx(), sup)
  end

  test "raise / throw / exit all deny :policy_crash (T-2, T-3)", %{sup: sup} do
    assert {:denied, :policy_crash} = authorize(Stubs.Raises, ctx(), sup)
    assert {:denied, :policy_crash} = authorize(Stubs.Throws, ctx(), sup)
    assert {:denied, :policy_crash} = authorize(Stubs.Exits, ctx(), sup)
  end

  test "hung policy denies :policy_timeout and the task is brutally killed (T-4)",
       %{sup: sup} do
    ctx = ctx(%{probe: self()})
    t0 = System.monotonic_time(:millisecond)
    assert {:denied, :policy_timeout} = authorize(Stubs.Hangs, ctx, sup, timeout_ms: 80)
    elapsed = System.monotonic_time(:millisecond) - t0

    # The policy ran (it announced), yet we returned promptly near the bound.
    assert_received :hang_started
    assert elapsed < 2_000

    # No children linger under the supervisor — the hung task was killed.
    assert Task.Supervisor.children(sup) == []
  end

  test "missing/dead Task.Supervisor denies :policy_infra, never raises (T-30, INV-S18)" do
    assert {:denied, :policy_infra} =
             Runner.authorize(Stubs.Ok, ctx(), task_supervisor: :no_such_supervisor_xyz)
  end

  # -- LocalNode default policy (T-7, T-24; INV-AP3, AP18) --------------------

  test "LocalNode admits :process and :stdio transports", %{sup: sup} do
    assert {:ok, %Grant{via: :local_node}} =
             authorize(LocalNode, ctx(%{transport: %{kind: :process, peer: :self}}), sup)

    assert {:ok, %Grant{via: :local_node}} =
             authorize(LocalNode, ctx(%{transport: %{kind: :stdio, peer: :pipe}}), sup)
  end

  test "LocalNode denies network + nil + absent transport (fail-closed)", %{sup: sup} do
    assert {:denied, :policy_error} =
             authorize(LocalNode, ctx(%{transport: %{kind: :tcp, peer: {1, 2}}}), sup)

    assert {:denied, :policy_error} =
             authorize(LocalNode, ctx(%{transport: %{kind: :websocket, peer: nil}}), sup)

    assert {:denied, :policy_error} =
             authorize(LocalNode, ctx(%{transport: nil}), sup)

    # transport key absent entirely
    absent = ctx() |> Map.delete(:transport)
    assert {:denied, :policy_error} = authorize(LocalNode, absent, sup)
  end

  test "LocalNode decision reads ONLY transport — no peer field widens it (T-24, INV-AP18)",
       %{sup: sup} do
    # A network peer that also injects a local-looking actor + a capability token
    # cannot reach a grant: the transport (Connection-sourced) is the sole gate.
    spoofy =
      ctx(%{
        transport: %{kind: :tcp, peer: {192, 168}},
        actor: %{"id" => "local", "kind" => "local_node"},
        capability: "RXC1.anything.anything"
      })

    assert {:denied, :policy_error} = authorize(LocalNode, spoofy, sup)
  end

  test "LocalNode synthesizes a concrete audit actor when none asserted", %{sup: sup} do
    assert {:ok, %Grant{actor: %{"id" => "local", "kind" => "local_node"}}} =
             authorize(LocalNode, ctx(%{actor: nil}), sup)
  end

  test "LocalNode uses an asserted actor that carries a binary id", %{sup: sup} do
    actor = %{"id" => "v@laptop", "kind" => "user"}

    assert {:ok, %Grant{actor: ^actor}} =
             authorize(LocalNode, ctx(%{actor: actor}), sup)
  end

  test "LocalNode never emits an id-less actor even from a malformed assertion", %{
    sup: sup
  } do
    assert {:ok, %Grant{actor: %{"id" => "local"}}} =
             authorize(LocalNode, ctx(%{actor: %{"kind" => "user"}}), sup)
  end

  test "default_policy is LocalNode when unconfigured, never an allow-all (INV-AP3)" do
    prev = Application.get_env(:raxol_agent_client_protocol, :attach_policy)
    Application.delete_env(:raxol_agent_client_protocol, :attach_policy)

    on_exit(fn ->
      if prev,
        do: Application.put_env(:raxol_agent_client_protocol, :attach_policy, prev),
        else: Application.delete_env(:raxol_agent_client_protocol, :attach_policy)
    end)

    assert AttachPolicy.default_policy() == LocalNode
  end

  # -- Anti-oracle: one wire frame for every deny reason (T-19, INV-AP10) -----

  test "every distinct deny reason collapses to one reasonless wire frame", %{sup: sup} do
    reasons =
      [
        authorize(Stubs.SessionMismatch, ctx(), sup),
        authorize(Stubs.AdminScope, ctx(), sup),
        authorize(Stubs.ActorNoId, ctx(), sup),
        authorize(Stubs.ErrorReturn, ctx(), sup),
        authorize(Stubs.BareOk, ctx(), sup),
        authorize(Stubs.Raises, ctx(), sup)
      ]
      |> Enum.map(fn {:denied, reason} -> reason end)

    # The internal reasons are genuinely distinct (telemetry can tell them apart)…
    assert length(Enum.uniq(reasons)) == length(reasons)

    # …yet the wire projection is byte-identical and carries NO reason / data.
    wire = Runner.deny_wire()
    assert wire == %{code: -32_000, message: "attach denied"}
    refute Map.has_key?(wire, :data)

    for reason <- reasons do
      refute inspect(wire) =~ Atom.to_string(reason)
    end
  end
end
