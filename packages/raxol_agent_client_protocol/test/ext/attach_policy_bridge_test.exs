# Stub policies exercising the bridge's ctx translation + Runner deferral with
# real dependencies (real Runner, real LocalNode, real Task.Supervisor).
defmodule Raxol.AgentClientProtocol.Ext.AttachPolicy.BridgeTest.Stubs do
  @moduledoc false
  alias Raxol.AgentClientProtocol.Ext.AttachPolicy.Grant

  # Grants only when the bridge threaded EVERY expected field into the CDI-2 ctx.
  defmodule RequireFields do
    @moduledoc false
    @behaviour Raxol.AgentClientProtocol.Ext.AttachPolicy
    @impl true
    def authorize_attach(ctx) do
      if ctx.capability == "cap-1" and match?(%{kind: :process}, ctx.transport) and
           ctx.from_offset == 7 and ctx.surface == :beam_local do
        {:ok,
         %Grant{
           actor: ctx.actor || %{"id" => "x"},
           scope: :attach,
           session_id: ctx.session_id,
           via: :test
         }}
      else
        {:error, :missing_fields}
      end
    end
  end

  # A well-formed grant naming a DIFFERENT session — the Runner must deny.
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
end

defmodule Raxol.AgentClientProtocol.Ext.AttachPolicy.BridgeTest do
  use ExUnit.Case, async: true

  alias Raxol.AgentClientProtocol.Ext.AttachPolicy.{Bridge, Grant, LocalNode}
  alias Raxol.AgentClientProtocol.Ext.AttachPolicy.BridgeTest.Stubs

  @sid "sess-bridge-123"

  setup do
    sup = start_supervised!({Task.Supervisor, []})
    {:ok, sup: sup}
  end

  # The exact ctx shape `Raxol.Agent.Reattach.attach/4` builds: session_id,
  # from_offset, the HISTORY policy, and surface: :beam_local. The `policy` key
  # is included to prove the bridge tolerates (drops) it.
  defp beam_ctx(overrides \\ %{}) do
    Map.merge(
      %{session_id: @sid, from_offset: 0, policy: :none, surface: :beam_local},
      overrides
    )
  end

  test "grants via LocalNode over a co-resident :process transport", %{sup: sup} do
    authorize =
      Bridge.authorizer(
        policy: LocalNode,
        transport: %{kind: :process, peer: :self},
        task_supervisor: sup
      )

    assert {:ok, %Grant{scope: :attach, session_id: @sid, via: :local_node}} =
             authorize.(beam_ctx())
  end

  test "denies via the default policy (LocalNode) when transport is absent", %{sup: sup} do
    # No :policy and no :transport -> default LocalNode denies a nil transport.
    authorize = Bridge.authorizer(task_supervisor: sup)

    assert {:denied, _reason} = authorize.(beam_ctx())
  end

  test "threads session_id/from_offset/surface/actor/capability/transport into the CDI-2 ctx",
       %{sup: sup} do
    authorize =
      Bridge.authorizer(
        policy: Stubs.RequireFields,
        capability: "cap-1",
        transport: %{kind: :process, peer: :p},
        actor: %{"id" => "u@local"},
        task_supervisor: sup
      )

    assert {:ok, %Grant{session_id: @sid, actor: %{"id" => "u@local"}}} =
             authorize.(beam_ctx(%{from_offset: 7, surface: :beam_local}))
  end

  test "a missing config field denies (proves the fields are load-bearing)", %{sup: sup} do
    # Same policy, capability omitted -> the stub returns {:error, _} -> deny.
    authorize =
      Bridge.authorizer(
        policy: Stubs.RequireFields,
        transport: %{kind: :process, peer: :p},
        task_supervisor: sup
      )

    assert {:denied, :policy_error} = authorize.(beam_ctx(%{from_offset: 7}))
  end

  test "a grant naming a different session denies (Runner session match)", %{sup: sup} do
    authorize =
      Bridge.authorizer(
        policy: Stubs.SessionMismatch,
        transport: %{kind: :process, peer: :p},
        task_supervisor: sup
      )

    assert {:denied, :grant_session_mismatch} = authorize.(beam_ctx())
  end

  test "the verdict is shape-compatible with the authorize_fun contract", %{sup: sup} do
    # Raxol.Agent.Reattach.attach/4 admits on {:ok, _grant} and denies otherwise.
    grant =
      Bridge.authorizer(
        policy: LocalNode,
        transport: %{kind: :process, peer: :self},
        task_supervisor: sup
      ).(beam_ctx())

    deny = Bridge.authorizer(policy: LocalNode, task_supervisor: sup).(beam_ctx())

    assert match?({:ok, _grant}, grant)
    refute match?({:ok, _grant}, deny)
  end
end
