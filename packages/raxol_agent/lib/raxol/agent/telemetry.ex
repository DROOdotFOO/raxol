defmodule Raxol.Agent.Telemetry do
  @moduledoc """
  The registry of every `:telemetry` event `raxol_agent` emits, each classified
  as exactly one of `:invariant`, `:peer` or `:operational`.

  ## Why this exists

  This package already detected its own impossible states and then did nothing
  about them: a signal was emitted, a warning was logged, and the defect
  shipped anyway because no test ever asserted on the event. A telemetry event
  is only a guard if something fails when it fires. That is what the
  classification buys:

    * `:invariant` -- can only fire if RAXOL ITSELF is wrong. Enforced:
      `Raxol.Agent.Test.InvariantSentinel` fails any test in which one fires
      unless the test declares it with `@tag expect_invariant:`.
    * `:peer` -- caused by the remote agent/client misbehaving (malformed
      frame, unknown notification, duplicate id). Expected in negative tests,
      so not enforced.
    * `:operational` -- normal life (cache hit, policy applied, sandbox
      denied, journal write refused by the filesystem, idle reap). Not
      enforced.

  ## The criterion, applied literally

  If a peer, the network, the filesystem, the clock, or a user can cause it, it
  is NOT an invariant. Err toward `:peer`/`:operational`: a false invariant
  makes the suite flaky, and a flaky guard gets deleted, which is strictly
  worse than a missed one. That criterion is why several alarming-looking
  events below are `:operational` -- `:write_failed` and `:damaged` are the
  filesystem talking, and this package has a deliberate chmod-0500 fault test
  that drives them on purpose.

  This package emits no `:peer` events: it is the agent-side library, and the
  peer-facing wire lives in `raxol_agent_client_protocol`, which carries its
  own registry. The vocabulary is shared but the registries are deliberately
  separate, because the packages publish separately and
  `raxol_agent_client_protocol` must not grow a dependency edge for a test
  helper.

  ## Completeness is asserted, not trusted

  `test/raxol/agent/telemetry_registry_test.exs` parses this package's `lib/`
  for `[:raxol, ...]` event literals and fails if any of them is missing from
  `events/0`. That is the whole point of the design: a new event cannot be
  added without someone classifying it.
  """

  @typedoc "How a fired event should be read."
  @type classification :: :invariant | :peer | :operational

  # Each entry carries WHY it lands where it does. The verdicts were read off
  # the emit sites, not guessed from the event names.
  @events %{
    # INVARIANT. `run_interrupt/1` catches raise/throw/exit deliberately
    # broadly, because the cancel path MUST reach the kill-complete fence no
    # matter what the interrupt implementation does. The moduledoc there pays
    # for that broad catch with a promise: "what review flagged as 'hides real
    # defects' is answered by telemetry, not by narrowing the catch". This
    # classification is what converts that promise into enforcement. The
    # default implementation is our own `Raxol.Agent.Interrupt`, so a failure
    # is our staged kill being broken; a test that injects a deliberately
    # failing double declares it with `@tag expect_invariant:`, which pins the
    # bad path instead of muting it.
    [:raxol, :agent, :acp_turn_runner, :interrupt_failed] => :invariant,

    # OPERATIONAL. `FileStore.append/2` refused the record. The cause is the
    # filesystem (full disk, revoked permission, vanished directory), which
    # the criterion puts outside our control.
    [:raxol, :agent, :acp_turn_runner, :journal_failed] => :operational,

    # OPERATIONAL. `Code.App` stopped a running turn because the wired ledger
    # could not answer: the process is down or hung. A host dependency being
    # down, not a defect; split from `:over_limit` because the remedy is
    # infrastructure, not a policy decision (ADR-0036, rule 1).
    [:raxol, :agent, :budget, :halt, :ledger_unreachable] => :operational,

    # OPERATIONAL. `Code.App` stopped a running turn because the ledger and
    # policy refused further spend: `:per_request`, `:session`, `:lifetime`,
    # or the operator's `:frozen` kill switch. Every reason is a user's policy
    # decision; the gate firing is the gate working (ADR-0036).
    [:raxol, :agent, :budget, :halt, :over_limit] => :operational,

    # OPERATIONAL. The fail-closed halt of ADR-0035: a model the tables cannot
    # price burned tokens under a wired ledger and policy. The model name is
    # the user's choice and the missing price is a table gap, not a defect.
    # `app_metering_test.exs` drives it on purpose.
    [:raxol, :agent, :budget, :halt, :unpriced] => :operational,

    # OPERATIONAL. One per metered provider call whose cost resolved. The
    # happy path of the money path; `source:` says which resolution step
    # priced it, which is the whole point (ADR-0036).
    [:raxol, :agent, :cost, :priced] => :operational,

    # OPERATIONAL. A provider call burned tokens and no step could price it:
    # a user-chosen model absent from every table, a peer that reported no
    # cost, or a backend that reports no usage. Fires whether or not the halt
    # is armed, so the single-user configuration can see the hole too.
    [:raxol, :agent, :cost, :unpriced] => :operational,

    # OPERATIONAL, despite looking like a violation. `DoneGate` runs in
    # observe-only mode and is fully fail-closed on v0 producer journals (no
    # tool result can green-light a done yet), so EVERY tool-less turn fires
    # this. It measures a boundary that is deliberately open; enforcing it
    # would fail on the happy path.
    [:raxol, :agent, :done_gate, :ungated_done] => :operational,

    # OPERATIONAL. The rejected refs are derived from journal content shaped by
    # what the model chose to call, so a rejection is a fact about the turn,
    # not about our code.
    [:raxol, :agent, :done_gate, :rejected_evidence] => :operational,

    # OPERATIONAL. Fires on every restore through the surrogate checkpoint
    # backend, which is the normal state when no real backend is registered.
    # It exists so a caller cannot mistake the surrogate fold for real harness
    # state -- a disclosure, not an alarm.
    [:raxol, :agent, :journal, :checkpoint, :surrogate] => :operational,

    # OPERATIONAL. Interior segment corruption found on replay: truncated
    # writes, bit rot, an editor that touched a segment. Filesystem-caused, and
    # driven on purpose by this package's fault-injection suite.
    [:raxol, :agent, :journal, :damaged] => :operational,

    # OPERATIONAL. Same reason as `:damaged`: the write was refused by the OS.
    # There is a deliberate chmod-0500 fault test (tagged `:skip_on_ci`) whose
    # entire job is to make this fire.
    [:raxol, :agent, :journal, :write_failed] => :operational,

    # OPERATIONAL x6. The policy family is the routine bookkeeping of
    # `PolicyApplier`: every wrapped call emits `:applied`, and cache
    # hit/miss, retry and timeout are the policies doing exactly what they
    # were configured to do.
    [:raxol, :agent, :policy, :applied] => :operational,
    [:raxol, :agent, :policy, :cache_hit] => :operational,
    [:raxol, :agent, :policy, :cache_miss] => :operational,
    [:raxol, :agent, :policy, :retry_attempt] => :operational,
    [:raxol, :agent, :policy, :retry_exhausted] => :operational,
    [:raxol, :agent, :policy, :timeout] => :operational,

    # OPERATIONAL. A sandbox refusing an action is the sandbox working. The
    # rules come from the app's `sandbox/0`, i.e. from a user.
    [:raxol, :agent, :sandbox, :denied] => :operational,

    # OPERATIONAL. The `{:session, session_id}` registry key was held by a
    # genuinely-live foreign holder for the whole retry budget. Two causes,
    # both outside this library: a caller reusing a session_id, and scheduler
    # timing under load. Enforcing it would make the suite flaky on a busy
    # machine, which is the exact failure mode the criterion warns about.
    [:raxol, :agent, :session, :register_timeout] => :operational,

    # OPERATIONAL. The name-based secret heuristic redacted a field the app
    # explicitly listed in `persist:`. That is a declaration/outcome mismatch
    # in USER code, made loud on purpose so it is not a silently-empty field
    # on restore.
    [:raxol, :agent, :snapshot, :persist_redacted_by_heuristic] => :operational,

    # OPERATIONAL. The exiting hook is app-supplied code, and the documented
    # shape of this event is a downed app dependency (e.g. a spend-ledger
    # GenServer). Contained like a veto and made observable; not our defect.
    [:raxol, :agent, :tool_call_hook, :exit] => :operational
  }

  @invariant_events @events
                    |> Enum.filter(fn {_event, class} -> class == :invariant end)
                    |> Enum.map(fn {event, _class} -> event end)
                    |> Enum.sort()

  @doc """
  Every telemetry event this package emits, mapped to its classification.
  """
  @spec events() :: %{[atom()] => classification()}
  def events, do: @events

  @doc """
  The events that can only fire if this library is wrong, sorted.

  `Raxol.Agent.Test.InvariantSentinel` arms exactly this list.
  """
  @spec invariant_events() :: [[atom()]]
  def invariant_events, do: @invariant_events

  # Long enough for every identifier this repo mints -- a session key is
  # `sess-<epoch>-<int>`, a trace id is 16 hex characters, a UUID is 36 and a
  # SHA-256 hex digest is exactly 64 -- and short enough that no prompt, tool
  # argument or file body fits.
  @max_identifier_bytes 64

  @doc """
  The largest binary `identifier?/1` accepts, in bytes.
  """
  @spec max_identifier_bytes() :: pos_integer()
  def max_identifier_bytes, do: @max_identifier_bytes

  @doc """
  Whether `value` is shaped like a correlation identifier: an atom, a number,
  or a binary of at most `max_identifier_bytes/0` bytes.

  This is the metadata contract's one enforceable rule (ADR-0036). Metadata
  is context, and two consumers persist it verbatim -- `Raxol.Agent.ThreadLogRouter`
  into a durable audit log, and any host's log or metrics pipeline -- so a
  value that is not an identifier is a value that must not be there. Maps,
  lists, tuples and structs are how content arrives; a binary longer than an
  identifier is content. `Raxol.Agent.PolicyApplier.apply/4` refuses caller
  metadata that fails this, and the router drops any mirrored key whose value
  fails it, so the audit log does not rest on every emitter being careful.
  """
  @spec identifier?(term()) :: boolean()
  def identifier?(value) when is_atom(value) or is_number(value), do: true
  def identifier?(value) when is_binary(value), do: byte_size(value) <= @max_identifier_bytes
  def identifier?(_value), do: false

  # The digest key lives for one VM run and is never persisted, so a digest
  # is a correlation token inside a run and nothing more: two runs digest the
  # same argument differently, on purpose. Generated lazily; two processes
  # racing the first call may briefly hold different keys, which costs one
  # missed join in the first microseconds of a VM and leaks nothing.
  @digest_key {__MODULE__, :digest_key}

  @doc """
  A 16-hex-character correlation token for `term`: the first 8 bytes of an
  HMAC-SHA256 over the term's external format, keyed with a random key that
  is generated once per VM run and never leaves memory.

  Same term, same run: same token, so the events of one operation can be
  joined. The key is what makes it safe to persist: an unkeyed hash of a
  low-entropy argument (a known prompt template with a short secret in it)
  can be confirmed offline by anyone holding the audit log and a guess, and
  a keyed one cannot. The cost of that property is that tokens do not join
  across runs or across nodes, and a term holding a pid, a reference or a
  fun encodes differently each time it is built; both are accepted.

  The whole term is serialized, so this is O(size) with one copy. Measured
  on Apple M1 (ADR-0036): about 3 us for a 1 KB term, 90 us at 100 KB and
  1.1 ms at 1 MB, of which the key costs roughly 40% over an unkeyed hash.
  Call it once per operation, not once per event.
  """
  @spec digest(term()) :: String.t()
  def digest(term) do
    :hmac
    |> :crypto.mac(:sha256, digest_key(), :erlang.term_to_binary(term))
    |> binary_part(0, 8)
    |> Base.encode16(case: :lower)
  end

  defp digest_key do
    case :persistent_term.get(@digest_key, nil) do
      nil ->
        :persistent_term.put(@digest_key, :crypto.strong_rand_bytes(32))
        :persistent_term.get(@digest_key)

      key ->
        key
    end
  end

  # Wide enough to keep the shape of any error reason this repo builds
  # (`{:shell_denied, mode, program}`, `{:http_error, status, _}`), narrow
  # enough that a payload map or a message list cannot ride through.
  @max_bound_depth 3
  @max_bound_elements 8

  @doc """
  A copy of `term` that is safe to put in event metadata.

  Identifiers (`identifier?/1`) pass through. Tuples, lists and maps are
  walked to a depth of #{@max_bound_depth} and a width of
  #{@max_bound_elements}, so the shape of an error reason survives:
  `{:http_error, 500, body}` still begins `{:http_error, 500, ...}`. Every
  other leaf is replaced by a tag that names its shape and nothing else --
  `{:redacted, :binary, 4096}`, `{:redacted, Req.TransportError}`,
  `{:redacted, :pid}` -- because a long binary is content, a struct is a
  container for content, and a pid or fun is meaningless once persisted.

  Emitters call this on any value they did not build themselves (an error
  reason from a wrapped operation, a cache key from a user's `key_fn`), and
  `Raxol.Agent.ThreadLogRouter` calls it on every payload it persists, so a
  new emitter that forgets is still bounded at the audit log.
  """
  @spec bound(term()) :: term()
  def bound(term), do: bound(term, @max_bound_depth)

  defp bound(term, _depth) when is_atom(term) or is_number(term), do: term

  defp bound(term, _depth) when is_binary(term) do
    if byte_size(term) <= @max_identifier_bytes,
      do: term,
      else: {:redacted, :binary, byte_size(term)}
  end

  defp bound(_term, 0), do: {:redacted, :nested}
  defp bound(%struct{}, _depth), do: {:redacted, struct}

  defp bound(term, depth) when is_map(term) do
    if map_size(term) > @max_bound_elements do
      {:redacted, :map, map_size(term)}
    else
      Map.new(term, fn {key, value} -> {bound(key, depth - 1), bound(value, depth - 1)} end)
    end
  end

  defp bound(term, depth) when is_list(term) do
    cond do
      List.improper?(term) -> {:redacted, :improper_list}
      length(term) > @max_bound_elements -> {:redacted, :list, length(term)}
      true -> Enum.map(term, &bound(&1, depth - 1))
    end
  end

  defp bound(term, depth) when is_tuple(term) do
    if tuple_size(term) > @max_bound_elements do
      {:redacted, :tuple, tuple_size(term)}
    else
      term |> Tuple.to_list() |> Enum.map(&bound(&1, depth - 1)) |> List.to_tuple()
    end
  end

  defp bound(term, _depth) when is_pid(term), do: {:redacted, :pid}
  defp bound(term, _depth) when is_reference(term), do: {:redacted, :reference}
  defp bound(term, _depth) when is_function(term), do: {:redacted, :function}
  defp bound(term, _depth) when is_port(term), do: {:redacted, :port}
  defp bound(_term, _depth), do: {:redacted, :other}
end
