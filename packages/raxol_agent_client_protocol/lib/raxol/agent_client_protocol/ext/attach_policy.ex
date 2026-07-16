defmodule Raxol.AgentClientProtocol.Ext.AttachPolicy.Grant do
  @moduledoc """
  A successful attach grant (`acp-attachpolicy-design.md` §2.2, CDI-3).

  The value the bus records at registration. `%Grant{}` is the ONLY structural
  shape the `Runner` (the fail-closed funnel) admits — a policy cannot "mostly"
  grant. The Runner enforces well-formedness (`acp-attachpolicy-design.md` §3.3):

    * `actor` — a map carrying a **binary `"id"`** `[G5:S5]` (audit identity, never
      empty). For a token grant this is the token's `act` claim; for LocalNode a
      synthesized local identity.
    * `scope` — an atom in the Runner's allow-list (v1 `[:attach]`) `[G5:S4]`.
    * `session_id` — binary, MUST `==` `ctx.session_id` (the Runner denies a
      mismatch `[G5:X1]`).
    * `via` — non-nil provenance for audit (`:local_node | {:token, kid}`).
    * `expires_at` — token `exp` (unix seconds) or nil. CONSUMED by the CDI-6
      mid-attach expiry timer (owned by the bus/reattach layer, not this package):
      a held live tail is force-closed at `expires_at`.
    * `lens` — RESERVED (frozen §6): a grow-only redaction transform threaded
      opaquely by the bus, NEVER interpreted. v1: always nil.
  """

  @enforce_keys [:actor, :scope, :session_id, :via]
  defstruct actor: nil,
            scope: :attach,
            session_id: nil,
            via: nil,
            expires_at: nil,
            lens: nil

  @type t :: %__MODULE__{
          actor: map(),
          scope: atom(),
          session_id: String.t(),
          via: :local_node | {:token, String.t()} | term(),
          expires_at: integer() | nil,
          lens: term() | nil
        }
end

defmodule Raxol.AgentClientProtocol.Ext.AttachPolicy do
  @moduledoc """
  Fail-closed attach admission behaviour (`acp-attachpolicy-design.md` §2.1;
  frozen `harness-bus-protocol.md` §3).

  An attach grants **read access to a session's full durable record stream** —
  history from an offset plus the live tail (one decision gates both, frozen §3).
  Records carry prompts, tool output, file contents; admission is security-core.

  A policy module implements `authorize_attach/1`. It is **never trusted to be
  well-behaved**: every invocation is wrapped by
  `Raxol.AgentClientProtocol.Ext.AttachPolicy.Runner` (the SOLE funnel, CDI-1),
  which isolates it in a `Task.Supervisor.async_nolink` task with a bounded
  `Task.yield` + `Task.shutdown(:brutal_kill)`, so a hostile policy can neither
  block nor crash the bus, and every non-`{:ok, %Grant{}}` outcome denies.

  ## ctx (attach context) — CDI-2 `[G5:X3, S17]`

  `transport` is a REQUIRED key (its value MAY be nil). It is sourced ONLY from
  Connection-side knowledge, NEVER from a peer-asserted field — a peer does not
  get to claim `kind: :process`. `LocalNode` (the default) consults it and denies
  a nil transport; `Token` ignores it.

  ## The default policy

  Unconfigured ⇒ `LocalNode` (deny-by-default). There is **no `AllowAll` module**
  in this package — the absent module is the guarantee (`INV-AP3`).
  """

  alias Raxol.AgentClientProtocol.Ext.AttachPolicy.Grant
  alias Raxol.AgentClientProtocol.Ext.AttachPolicy.LocalNode

  @typedoc """
  Attach context (CDI-2). A grow-only map — a policy MUST tolerate unknown keys
  and pattern-match only what it needs.
  """
  @type ctx :: %{
          required(:session_id) => String.t(),
          required(:actor) => map() | nil,
          required(:surface) => atom(),
          required(:capability) => binary() | nil,
          required(:from_offset) => non_neg_integer(),
          required(:transport) => %{kind: atom(), peer: term()} | nil
        }

  @doc """
  Authorize an attach. A **plain, pure-ish** function on the policy module,
  wrapped by the Runner. MUST return a well-formed `%Grant{}` inside `{:ok, _}`
  to admit; anything else (incl. `{:error, _}`, a raise, a hang) denies.
  """
  @callback authorize_attach(ctx()) :: {:ok, Grant.t()} | {:error, reason :: term()}

  @doc """
  The configured attach policy, or `LocalNode` when unconfigured
  (`acp-attachpolicy-design.md` §3.1). Never an allow-all.
  """
  @spec default_policy() :: module()
  def default_policy do
    Application.get_env(
      :raxol_agent_client_protocol,
      :attach_policy,
      LocalNode
    )
  end
end

defmodule Raxol.AgentClientProtocol.Ext.AttachPolicy.Runner do
  @moduledoc """
  THE single fail-closed admission funnel (`acp-attachpolicy-design.md` §3.3,
  CDI-1 `[G5:X1]`). There is exactly ONE funnel: `authorize/2`. No second
  `try/catch` wrapper exists anywhere — a second funnel with weaker
  timeout/crash semantics is the exact dual-ownership hole G5 closes.

  `authorize/2 :: {:ok, %Grant{}} | {:denied, reason_atom}`. The bus/reattach
  layer treats ANY `{:denied, _}` as deny and answers with the CDI-5 wire
  envelope (`-32000 "attach denied"`, NO `data`); the specific reason atom goes
  to telemetry/`Logger` ONLY — a remote attacker gets one bit (anti-oracle,
  `INV-AP10`).

  ## The exhaustive outcome table (each row a red test, §9)

  | Policy did… | Runner returns |
  |---|---|
  | `{:ok, %Grant{}}` well-formed (`actor["id"]` binary, scope `:attach`), sid match | `{:ok, grant}` |
  | `{:ok, %Grant{}}` `session_id != ctx.session_id` | `{:denied, :grant_session_mismatch}` |
  | `{:ok, %Grant{}}` scope ∉ `[:attach]` `[G5:S4]` | `{:denied, :scope_not_allowed}` |
  | `{:ok, %Grant{}}` `actor` w/o binary `"id"` `[G5:S5]` | `{:denied, :malformed_grant}` |
  | `{:ok, not-a-Grant / nil field}` | `{:denied, :malformed_grant}` |
  | `{:error, _}` | `{:denied, :policy_error}` |
  | any other term | `{:denied, :non_conforming_return}` |
  | raised / threw / exited | `{:denied, :policy_crash}` |
  | hung past `policy_timeout_ms` | `{:denied, :policy_timeout}` (task brutally killed) |
  | Task.Supervisor missing/dead `[G5:S18]` | `{:denied, :policy_infra}` (never raises) |
  """

  require Logger

  alias Raxol.AgentClientProtocol.Ext.AttachPolicy.Grant

  @default_timeout_ms 5_000
  @default_supervisor Raxol.AgentClientProtocol.Ext.AttachPolicy.TaskSupervisor

  # v1 scope allow-list [G5:S4] — grow deliberately, never widen a grant by
  # accepting an unlisted scope.
  @allowed_scopes [:attach]

  @doc """
  Run `policy.authorize_attach(ctx)` inside the fail-closed funnel.

  Options:

    * `:task_supervisor` — the `Task.Supervisor` name/pid (default the
      package-level `#{inspect(@default_supervisor)}`, overridable per endpoint
      via `config :raxol_agent_client_protocol, :attach_task_supervisor`).
    * `:timeout_ms` — the bounded policy timeout (default #{@default_timeout_ms};
      `config :raxol_agent_client_protocol, :attach_policy_timeout_ms`).
  """
  @spec authorize(module(), map()) :: {:ok, Grant.t()} | {:denied, atom()}
  def authorize(policy, ctx), do: authorize(policy, ctx, [])

  @spec authorize(module(), map(), keyword()) :: {:ok, Grant.t()} | {:denied, atom()}
  def authorize(policy, ctx, opts) when is_atom(policy) and is_map(ctx) do
    sup = Keyword.get(opts, :task_supervisor, supervisor())
    timeout = Keyword.get(opts, :timeout_ms, timeout_ms())

    result =
      case start_task(sup, policy, ctx) do
        {:ok, task} ->
          classify(
            Task.yield(task, timeout) ||
              (Task.shutdown(task, :brutal_kill) && nil),
            ctx
          )

        # [G5:S18] a missing/dead Task.Supervisor denies, never raises out of the
        # attach path — the funnel fails closed on its own infrastructure too.
        :error ->
          {:denied, :policy_infra}
      end

    report(result, ctx)
  end

  @doc """
  The canonical CDI-5 wire projection of a deny. ALL `{:denied, _}` reasons
  collapse to this single frame (`-32000 "attach denied"`, no `data`) so the
  wire observable is byte-identical across reasons (anti-oracle, `INV-AP10`).
  The transport layer owns emitting it; exposed here so the collapse is provable
  in one place.
  """
  @spec deny_wire() :: %{code: integer(), message: String.t()}
  def deny_wire, do: %{code: -32_000, message: "attach denied"}

  # -- internals --------------------------------------------------------------

  @spec start_task(GenServer.server(), module(), map()) :: {:ok, Task.t()} | :error
  defp start_task(sup, policy, ctx) do
    {:ok, Task.Supervisor.async_nolink(sup, fn -> policy.authorize_attach(ctx) end)}
  catch
    # async_nolink calls into the (possibly absent) supervisor; absorb its exit.
    :exit, _ -> :error
  end

  # ALLOW is the ONLY structural exit: %Grant{} with a binary actor "id" [G5:S5],
  # an ALLOW-LISTED scope [G5:S4], a binary session_id, a non-nil via — AND the
  # grant's session_id matching ctx.
  @spec classify(
          {:ok, term()} | {:exit, term()} | nil,
          map()
        ) :: {:ok, Grant.t()} | {:denied, atom()}
  defp classify(
         {:ok, {:ok, %Grant{actor: a, scope: s, session_id: sid, via: v} = grant}},
         ctx
       )
       when is_map(a) and is_map_key(a, "id") and
              is_binary(:erlang.map_get("id", a)) and
              is_atom(s) and s in @allowed_scopes and
              is_binary(sid) and not is_nil(v) do
    if sid == ctx.session_id,
      do: {:ok, grant},
      else: {:denied, :grant_session_mismatch}
  end

  # a well-formed Grant carrying a non-allow-listed scope denies distinctly [G5:S4]
  defp classify({:ok, {:ok, %Grant{scope: s}}}, _ctx)
       when is_atom(s) and s not in @allowed_scopes do
    {:denied, :scope_not_allowed}
  end

  defp classify({:ok, {:ok, _malformed}}, _ctx), do: {:denied, :malformed_grant}
  defp classify({:ok, {:error, _reason}}, _ctx), do: {:denied, :policy_error}
  defp classify({:ok, _other_term}, _ctx), do: {:denied, :non_conforming_return}
  defp classify({:exit, _reason}, _ctx), do: {:denied, :policy_crash}
  defp classify(nil, _ctx), do: {:denied, :policy_timeout}

  @spec report({:ok, Grant.t()} | {:denied, atom()}, map()) ::
          {:ok, Grant.t()} | {:denied, atom()}
  defp report({:ok, grant} = ok, ctx) do
    telemetry(
      [:raxol, :acp, :attach, :granted],
      %{},
      %{
        session_id: ctx[:session_id],
        surface: ctx[:surface],
        via: grant.via
      }
    )

    ok
  end

  defp report({:denied, reason} = deny, ctx) do
    # Reason to telemetry + Logger (stderr) ONLY — never to the wire (anti-oracle).
    Logger.warning(
      "acp attach denied: #{inspect(reason)} " <>
        "session=#{inspect(ctx[:session_id])} surface=#{inspect(ctx[:surface])}"
    )

    telemetry(
      [:raxol, :acp, :attach, :denied],
      %{},
      %{
        session_id: ctx[:session_id],
        surface: ctx[:surface],
        reason: reason
      }
    )

    deny
  end

  # Emit telemetry only when :telemetry is available; apply/3 keeps it an
  # optional, un-declared dependency (no compile-time reference).
  @spec telemetry([atom()], map(), map()) :: :ok
  defp telemetry(event, measurements, metadata) do
    if Code.ensure_loaded?(:telemetry) do
      apply(:telemetry, :execute, [event, measurements, metadata])
    end

    :ok
  end

  @spec supervisor() :: GenServer.server()
  defp supervisor do
    Application.get_env(
      :raxol_agent_client_protocol,
      :attach_task_supervisor,
      @default_supervisor
    )
  end

  @spec timeout_ms() :: pos_integer()
  defp timeout_ms do
    Application.get_env(
      :raxol_agent_client_protocol,
      :attach_policy_timeout_ms,
      @default_timeout_ms
    )
  end
end
