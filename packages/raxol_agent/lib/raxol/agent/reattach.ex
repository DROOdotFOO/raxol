defmodule Raxol.Agent.Reattach do
  @moduledoc """
  U4 — reattach / replay surface (AD-15 / FI-12). **SKELETON ONLY.**

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

  Not yet implemented. `attach/3` returns `{:error, :not_implemented}`; the U4-R
  red suite (`test/raxol/agent/red/u4_reattach_red_test.exs`) drives this surface
  and goes green when U4 lands. The `@callback` freezes the shape the reds assume.
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

  @doc """
  Attach to `session_id`: replay history per `policy`, then follow the live
  durable stream from `from_offset`.

  `policy`:

    * `{:from_offset, n}` — history = durable records with id in `n..(from_offset−1)`
    * `:tip` — history = the single conversational-tip record (resume point), or
      empty when the branch has no tip
    * `:none` — no history; deliver only the live tail from `from_offset`

  Returns `{:ok, attachment()}` or `{:error, term()}`.
  """
  @callback attach(
              session_id :: String.t(),
              from_offset :: non_neg_integer(),
              policy :: history_policy()
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
  Facade `attach/3` — validates `session_id` (see `valid_session_id?/1`;
  ill-formed ids are rejected as `{:error, :invalid_session_id}` before any
  dispatch), then dispatches to the configured implementation
  (`config :raxol_agent, :reattach_impl`), defaulting to
  `Raxol.Agent.Reattach.NotImplemented` until U4 lands.

  The red suite drives this exact arity/shape; when the concrete reattach
  reader is configured (or replaces the default), the reds turn green with no
  test rewrite.
  """
  @spec attach(String.t(), non_neg_integer(), history_policy()) ::
          {:ok, attachment()} | {:error, term()}
  def attach(session_id, from_offset, policy)
      when is_binary(session_id) and is_integer(from_offset) and from_offset >= 0 do
    if valid_session_id?(session_id) do
      impl().attach(session_id, from_offset, policy)
    else
      {:error, :invalid_session_id}
    end
  end

  defp impl do
    Application.get_env(:raxol_agent, :reattach_impl, __MODULE__.NotImplemented)
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
  def attach(_session_id, _from_offset, _policy), do: {:error, :not_implemented}
end
