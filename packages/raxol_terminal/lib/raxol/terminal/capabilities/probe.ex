defmodule Raxol.Terminal.Capabilities.Probe do
  @moduledoc """
  Pure probe reducer -- the clock seam (04 design §1b).

  `step(state, event)` where `event` is `{:input, bytes}`, `{:clock,
  monotonic_ms}`, or `:start`. **No time is read inside `step`** and no
  process sleeps anywhere: the silence timeout is driven entirely by
  injected clock events, so every timing case is a table row, not a
  flake. The real driver wraps this with a `receive/after` loop feeding
  `System.monotonic_time(:millisecond)` as `{:clock, now}` events.

  Sentinel discipline (F0 §2): the batched query ends with Primary DA
  (`CSI c`). Every VT-class terminal answers DA1, so read-to-sentinel
  converts "did it ignore me?" into a bounded wait -- any wanted reply
  that did not arrive before the sentinel is unsupported. Silence past
  the deadline is the failure mode, answered with a conservative default.

  Deadline policy (F0 §7 step 3): ~100 ms local, ~1 s when `$SSH_*` is
  present; extended AT MOST ONCE when a first byte is seen but the
  sentinel is not. After the sentinel, one drain window stays open until
  the next clock event so reordered replies (a documented terminal bug)
  are still parsed; after `:done`, late replies are drained, never
  reclassified, and never leaked as keystrokes.
  """

  alias Raxol.Terminal.Capabilities
  alias Raxol.Terminal.Capabilities.{Classifier, ReplyScanner}

  @local_budget_ms 100
  @ssh_budget_ms 1000
  @ssh_env_keys ["SSH_TTY", "SSH_CONNECTION", "SSH_CLIENT"]

  # One batched write (F0 §3 order, 2026 slice; native-palette-riding
  # amendment A1 adds OSC 10 next to OSC 11), DA1 sentinel LAST:
  # OSC 11 background - OSC 10 foreground - kitty keyboard - DECRQM 2026
  # - XTVERSION - DA1.
  @query "\e]11;?\a\e]10;?\a\e[?u\e[?2026$p\e[>0q\e[c"

  # tmux passthrough payload (F0 §7 step 4): identity + color queries
  # only, kept well under the ~60 char truncation limit.
  @passthrough_payload "\e]11;?\a\e]10;?\a\e[>0q"

  @type event :: :start | {:input, binary()} | {:clock, integer()}
  @type action ::
          {:write, iodata()}
          | {:passthrough, iodata()}
          | {:extend_deadline, non_neg_integer()}
          | {:leak_free, binary()}
          | {:done, Capabilities.t()}

  @type phase :: :init | :awaiting | :draining | :done

  @type t :: %__MODULE__{
          scanner: ReplyScanner.t(),
          env: map(),
          opts: keyword(),
          phase: phase(),
          budget_ms: pos_integer(),
          extend_ms: pos_integer(),
          deadline: integer() | nil,
          extended?: boolean(),
          seen_input?: boolean(),
          tty?: boolean(),
          now0: integer(),
          caps: Capabilities.t() | nil
        }

  defstruct scanner: nil,
            env: %{},
            opts: [],
            phase: :init,
            budget_ms: @local_budget_ms,
            extend_ms: @local_budget_ms,
            deadline: nil,
            extended?: false,
            seen_input?: false,
            tty?: true,
            now0: 0,
            caps: nil

  @doc "The exact batched query the probe emits on `:start`."
  @spec query_sequence() :: binary()
  def query_sequence, do: @query

  @doc """
  Builds a probe from the env seed.

  Options:

    * `:budget_ms` -- override the silence deadline (default ~100 ms
      local, ~1 s when any `$SSH_*` var is present)
    * `:extend_ms` -- the one-time extension budget (default = budget)
    * `:now_ms` -- clock origin the deadline is computed from (default 0;
      the driver passes `System.monotonic_time(:millisecond)`)
    * `:tty?` -- `false` = non-TTY path: Core-minus, ZERO queries emitted
    * `:tmux_passthrough?` -- re-issue identity/color queries wrapped for
      the outer terminal (only meaningful when `$TMUX` is set)
    * `:platform` -- forwarded to the classifier (`:windows` gates)
  """
  @spec new(map(), keyword()) :: t()
  def new(env, opts \\ []) when is_map(env) do
    budget = Keyword.get(opts, :budget_ms, default_budget(env))

    %__MODULE__{
      scanner: ReplyScanner.new(),
      env: env,
      opts: opts,
      budget_ms: budget,
      extend_ms: Keyword.get(opts, :extend_ms, budget),
      tty?: Keyword.get(opts, :tty?, true),
      now0: Keyword.get(opts, :now_ms, 0)
    }
  end

  @doc "Probe outcome: `:pending` or `{:done, %Capabilities{}}`."
  @spec result(t()) :: :pending | {:done, Capabilities.t()}
  def result(%__MODULE__{phase: :done, caps: caps}), do: {:done, caps}
  def result(%__MODULE__{}), do: :pending

  @doc """
  Advances the reducer by one event. Returns `{state, actions}`.
  """
  @spec step(t(), event()) :: {t(), [action()]}
  def step(%__MODULE__{phase: :init} = p, :start) do
    if p.tty? do
      actions = [{:write, @query} | passthrough_actions(p)]
      {%{p | phase: :awaiting, deadline: p.now0 + p.budget_ms}, actions}
    else
      # CAP-P-12: not a TTY -> Core-minus from the env seed alone,
      # zero bytes written (F0 §7 step 0).
      finalize(%{p | phase: :awaiting}, [])
    end
  end

  # an empty chunk is not a "first byte": no scan, no extension
  def step(%__MODULE__{} = p, {:input, <<>>}), do: {p, []}

  def step(%__MODULE__{phase: :awaiting} = p, {:input, bytes}) do
    {scanner, leak} = ReplyScanner.scan(bytes, p.scanner)
    p = %{p | scanner: scanner}

    {p, extend_actions} =
      if not p.seen_input? and not scanner.sentinel_seen? and not p.extended? do
        {%{
           p
           | seen_input?: true,
             extended?: true,
             deadline: p.deadline + p.extend_ms
         }, [{:extend_deadline, p.extend_ms}]}
      else
        {%{p | seen_input?: true}, []}
      end

    p = if scanner.sentinel_seen?, do: %{p | phase: :draining}, else: p
    {p, leak_actions(leak) ++ extend_actions}
  end

  def step(%__MODULE__{phase: :awaiting} = p, {:clock, now}) do
    if now >= p.deadline, do: finalize(p, []), else: {p, []}
  end

  # Drain window: replies arriving after the sentinel (same window) are
  # still parsed by grammar -- reorder is a documented terminal bug
  # (CAP-N-02). The window closes on the next clock event.
  def step(%__MODULE__{phase: :draining} = p, {:input, bytes}) do
    {scanner, leak} = ReplyScanner.scan(bytes, p.scanner)
    {%{p | scanner: scanner}, leak_actions(leak)}
  end

  def step(%__MODULE__{phase: :draining} = p, {:clock, _now}) do
    finalize(p, [])
  end

  # After :done: late replies are drained (classification is immutable),
  # interleaved keystrokes still pass through (CAP-N-03).
  def step(%__MODULE__{phase: :done} = p, {:input, bytes}) do
    {_scanner, leak} = ReplyScanner.scan(bytes, ReplyScanner.new())
    {p, leak_actions(leak)}
  end

  def step(%__MODULE__{phase: :done} = p, _event), do: {p, []}

  # a stray :start in any later phase is a no-op (idempotence)
  def step(%__MODULE__{} = p, :start), do: {p, []}

  # ---- internals ----

  defp finalize(p, extra_actions) do
    caps =
      Classifier.classify(p.scanner, p.env,
        tty?: p.tty?,
        platform: Keyword.get(p.opts, :platform)
      )

    # the parked partial (if any) is dropped here: a half-reply at
    # timeout is DRAINED, never leaked to the key parser (CAP-N-08)
    p = %{p | phase: :done, caps: caps}
    {p, extra_actions ++ [{:done, caps}]}
  end

  defp leak_actions(""), do: []
  defp leak_actions(leak), do: [{:leak_free, leak}]

  defp passthrough_actions(p) do
    if tmux?(p.env) and Keyword.get(p.opts, :tmux_passthrough?, false) do
      [{:passthrough, wrap_passthrough(@passthrough_payload)}]
    else
      []
    end
  end

  # DCS tmux ; <ESC-doubled payload> ST (F0 §7 step 4)
  defp wrap_passthrough(payload) do
    "\ePtmux;" <> String.replace(payload, "\e", "\e\e") <> "\e\\"
  end

  defp tmux?(env), do: (Map.get(env, "TMUX") || "") != ""

  defp default_budget(env) do
    ssh? =
      Enum.any?(@ssh_env_keys, fn key -> (Map.get(env, key) || "") != "" end)

    if ssh?, do: @ssh_budget_ms, else: @local_budget_ms
  end
end
