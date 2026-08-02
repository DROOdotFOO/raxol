defmodule Raxol.Agent.Reattach do
  @moduledoc """
  U4 — reattach / replay surface (AD-15 / FI-12).

  A client (re)connects to a session and receives, in one coherent stream:

    1. **history** per `history_policy` — from a given offset, from the
       conversational tip, or none; and
    2. the **live** durable tail from `from_offset` onward,

  with **no gap and no duplicate delivered as live** — the replay-closure law
  (P-JS5, `docs/proposals/in-flight/harness-freeze-contracts.md` §1.2):

      read(0..o−1) ++ attach_live(o..) == the full durable record stream

  as a *sequence*. A late subscriber never receives an earlier durable delivered
  as "live"; its first live id is ≥ the requested offset. The publish-ahead
  window this forbids is invariant **I3** (journal-before-publish observability,
  `harness-invariants.md`): the inverse write-order bug (publish the id before
  the durable append/ack) is what the U4-R closure red catches at read time.

  ## Read-side only — MUST work writerless

  Reattach is a **read-side** operation. It MUST succeed against a writerless
  session — a dead BEAM, a replay-only mount, a `tar`'d/rsync'd directory — so it
  is built on the tolerant Reader path, never on the single-writer append path.
  The tip is located by a backward scan under the frozen
  `Raxol.Agent.Journal.Tip.conversational?/1` predicate (branch-aware, skipping
  unknown kinds).

  Per §1.1 there is **no `attach`/`reattach` record kind**: an attach audit event
  is at most a best-effort `kind: "event"`, `family: "meta"` event written only
  when a live Writer exists — no reader, fold, or tip rule may ever depend on its
  presence. A reattach that requires such a marker fails the writerless red.

  ## Status

  Landed. `attach/3` dispatches to the read-side `Raxol.Agent.Reattach.FileReader`
  by default (`config :raxol_agent, :reattach_impl` overrides it), which reads
  durable history via the tolerant Reader and follows the live tail via
  `Raxol.Agent.Reattach.Tailer`. The U4-R suite
  (`test/raxol/agent/red/u4_reattach_red_test.exs`) runs GREEN against it; the
  `@callback` freezes the shape. `Raxol.Agent.Reattach.NotImplemented` remains as
  an explicit opt-out impl.
  """

  @typedoc "How much history to replay before the live tail begins."
  @type history_policy ::
          {:from_offset, non_neg_integer()}
          | :tip
          | :none

  @typedoc "A reattach result: replayed history plus a handle to the live tail."
  @type attachment :: %{
          history: [map()],
          from_offset: non_neg_integer(),
          live: term()
        }

  @typedoc """
  Admission seam (AD-15 second half, OQ-JS6): `ctx -> verdict`. A `{:ok, grant}`
  verdict admits; anything else denies. Run fail-closed BEFORE any read.
  """
  @type authorize_fun :: (map() -> {:ok, term()} | term())

  @typedoc """
  Reattach options (ratified OQ-JS5 arity growth + the admission seam):

    * `:base_dir` — session-dir root override; default = the
      `RAXOL_SESSIONS_DIR`-resolved path `FileStore` honors.
    * `:authorize` — an `authorize_fun/0` gating who may attach; default admits
      (the BEAM-local wire is in-process-trusted). To gate in-process attaches
      through the SAME fail-closed funnel the ACP boundary uses, inject
      `Raxol.AgentClientProtocol.Ext.AttachPolicy.Bridge.authorizer/1` (in
      raxol_agent_client_protocol) — it defers to the AttachPolicy Runner.
    * `:subscriber` — the pid that receives `{:reattach_live, session_id, record}`
      messages; default `self()` (the attaching process). The `attach` command
      wire sets it to the session's client pid.
  """
  @type attach_opts :: [
          base_dir: Path.t(),
          authorize: authorize_fun(),
          subscriber: pid()
        ]

  @doc """
  Attach to `session_id`: replay history per `policy`, then follow the live
  durable stream from `from_offset`.

  `policy`:

    * `{:from_offset, n}` — history = durable records with id in `n..(from_offset−1)`
    * `:tip` — history = the single conversational-tip record (resume point), or
      empty when the branch has no tip
    * `:none` — no history; deliver only the live tail from `from_offset`

  `opts` carries `:base_dir` (session-dir root override) and any impl-specific
  keys; the facade has already run admission before this is called.

  Returns `{:ok, attachment()}` or `{:error, term()}`.
  """
  @callback attach(
              session_id :: String.t(),
              from_offset :: non_neg_integer(),
              policy :: history_policy(),
              opts :: attach_opts()
            ) :: {:ok, attachment()} | {:error, term()}

  # A session_id names an on-disk session directory on the read path, so the
  # facade must reject anything able to escape the sessions base (separators,
  # `.`/`..` traversal, NUL) BEFORE dispatching to any implementation. Same
  # conservative charset as the writer-side rule in
  # `Raxol.Agent.Journal.FileStore`.
  @session_id_re ~r/\A[A-Za-z0-9._-]+\z/

  @doc """
  Whether `session_id` is a legal reattach target name: a single conservative
  path segment (`[A-Za-z0-9._-]+`, never `.` or `..`) — identical to the rule
  `Raxol.Agent.Journal.FileStore` enforces at write time.

  Reattach resolves `session_id` into a filesystem path, so traversal names
  (`"../../other-tenant/session"`) must die at this frozen surface, not in
  each implementation. `attach/3` rejects anything else as
  `{:error, :invalid_session_id}` before reaching the configured impl.
  """
  @spec valid_session_id?(String.t()) :: boolean()
  def valid_session_id?(session_id) when is_binary(session_id) do
    session_id not in [".", ".."] and Regex.match?(@session_id_re, session_id)
  end

  @doc """
  Facade `attach/4` (OQ-JS5 arity; `attach/3` preserved via `opts \\ []`).

  Runs two fail-closed gates BEFORE any read, then dispatches to the configured
  implementation (`config :raxol_agent, :reattach_impl`, default
  `Raxol.Agent.Reattach.FileReader`):

    1. **session-id hygiene** (`valid_session_id?/1`) — an ill-formed id is
       rejected as `{:error, :invalid_session_id}`.
    2. **admission** (AD-15 second half, OQ-JS6) — `opts[:authorize]` is called
       with the attach `ctx`; anything but a `{:ok, grant}` verdict denies with
       `{:error, :attach_denied}` and nothing is read or tailed.

  `opts[:authorize]` defaults to admit: the BEAM-local wire is in-process-trusted
  (a caller can `Reader.scan` the session dir directly, so a gate here is a seam
  for hosts that front reattach with their own transport, not a security
  boundary). The hardened cross-process funnel is
  `Raxol.AgentClientProtocol.Ext.AttachPolicy.Runner` at the ACP boundary, where
  attaches from untrusted peers must present an `RXC1` capability token.

  `ctx` is a grow-only map `%{session_id:, from_offset:, policy:, surface:
  :beam_local}`; an `:authorize` fun MUST tolerate unknown keys.
  """
  @spec attach(String.t(), non_neg_integer(), history_policy(), attach_opts()) ::
          {:ok, attachment()} | {:error, term()}
  def attach(session_id, from_offset, policy, opts \\ [])
      when is_binary(session_id) and is_integer(from_offset) and from_offset >= 0 and
             is_list(opts) do
    with :ok <- validate_session_id(session_id),
         :ok <- authorize(session_id, from_offset, policy, opts) do
      impl().attach(session_id, from_offset, policy, opts)
    end
  end

  defp validate_session_id(session_id) do
    if valid_session_id?(session_id), do: :ok, else: {:error, :invalid_session_id}
  end

  # Fail-closed admission seam: the default admits (in-process trust); a host
  # injects `:authorize` to gate reattach behind its own transport. Any verdict
  # other than `{:ok, grant}` denies — the seam cannot "mostly" admit.
  defp authorize(session_id, from_offset, policy, opts) do
    ctx = %{
      session_id: session_id,
      from_offset: from_offset,
      policy: policy,
      surface: :beam_local
    }

    case Keyword.get(opts, :authorize, &default_authorize/1).(ctx) do
      {:ok, _grant} -> :ok
      _denied -> {:error, :attach_denied}
    end
  end

  defp default_authorize(_ctx), do: {:ok, :in_process}

  defp impl do
    Application.get_env(:raxol_agent, :reattach_impl, __MODULE__.FileReader)
  end
end

defmodule Raxol.Agent.Reattach.NotImplemented do
  @moduledoc """
  The pre-U4 placeholder implementation: every attach is
  `{:error, :not_implemented}`. Exists so the U4-R red suite has a concrete
  callback module to drive (and fail against) before the unit lands.
  """

  @behaviour Raxol.Agent.Reattach

  @impl Raxol.Agent.Reattach
  def attach(_session_id, _from_offset, _policy, _opts), do: {:error, :not_implemented}
end
