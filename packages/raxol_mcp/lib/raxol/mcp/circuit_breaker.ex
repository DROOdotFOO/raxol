defmodule Raxol.MCP.CircuitBreaker do
  @moduledoc """
  Lightweight ETS-backed circuit breaker for MCP tool/resource callbacks.

  Tracks failure counts per key and transitions through three states:

  - **closed** -- normal operation, failures below threshold
  - **open** -- callback blocked after repeated failures, returns `{:error, :circuit_open}`
  - **half_open** -- recovery probe allowed after cooldown; success resets, failure re-opens

  No GenServer -- all state lives in a public ETS table with atomic counter
  updates. The table is created by the owning process (typically `MCP.Registry`),
  and it lives exactly as long as that process: a caller that creates its own
  gets a breaker nobody else can see, which for a failover gate means failover
  never trips.

  ## Keys

  A key names what is being guarded. `{:tool, _}`, `{:resource, _}` and
  `{:prompt, _}` are MCP callbacks; `{:origin, _}` is an outbound upstream,
  used by `raxol_web3`'s guarded client so a challenge-serving or hard-down
  explorer is not retried on every call. Nothing here is MCP-specific but the
  module's home, which is why the type widened rather than a second breaker
  being written.

  ## Configuration

  Defaults can be overridden via application env or per-call opts:

      config :raxol_mcp, :circuit_breaker,
        failure_threshold: 5,
        recovery_ms: 30_000
  """

  @type state :: :closed | :open | :half_open
  @type key ::
          {:tool, String.t()}
          | {:resource, String.t()}
          | {:prompt, String.t()}
          | {:origin, String.t()}

  @default_failure_threshold 5
  @default_recovery_ms 30_000

  @doc "Create a new circuit breaker ETS table."
  @spec new(atom()) :: :ets.tid()
  def new(name \\ :raxol_mcp_breakers) do
    :ets.new(name, [:set, :public, read_concurrency: true, write_concurrency: true])
  end

  @doc """
  Check the circuit state for a key.

  Returns `:closed` (proceed), `:open` (block), or `:half_open` (probe).
  Automatically transitions from open to half_open after the recovery period.
  """
  @spec check(:ets.tid(), key(), keyword()) :: state()
  def check(table, key, opts \\ []) do
    recovery_ms = get_opt(opts, :recovery_ms)

    case :ets.lookup(table, key) do
      [] ->
        :closed

      [{^key, :closed, _failures, _opened_at}] ->
        :closed

      [{^key, :open, _failures, opened_at}] ->
        if now_ms() - opened_at >= recovery_ms do
          # Transition to half_open: allow one probe
          :ets.insert(table, {key, :half_open, 0, opened_at})
          :half_open
        else
          :open
        end

      [{^key, :half_open, _failures, _opened_at}] ->
        :half_open
    end
  end

  @doc "Record a successful callback invocation. Resets the circuit to closed."
  @spec record_success(:ets.tid(), key()) :: :ok
  def record_success(table, key) do
    :ets.insert(table, {key, :closed, 0, 0})
    :ok
  end

  @doc """
  Record a failed callback invocation.

  Increments the failure counter. Transitions to open when the threshold is reached.
  In half_open state, a single failure re-opens the circuit.
  """
  @spec record_failure(:ets.tid(), key(), keyword()) :: :ok
  def record_failure(table, key, opts \\ []) do
    threshold = get_opt(opts, :failure_threshold)

    case :ets.lookup(table, key) do
      [] ->
        # First failure
        if threshold <= 1 do
          :ets.insert(table, {key, :open, 1, now_ms()})
        else
          :ets.insert(table, {key, :closed, 1, 0})
        end

      [{^key, :half_open, _failures, _opened_at}] ->
        # Probe failed, re-open
        :ets.insert(table, {key, :open, 1, now_ms()})

      [{^key, :closed, failures, _opened_at}] ->
        new_count = failures + 1

        if new_count >= threshold do
          :ets.insert(table, {key, :open, new_count, now_ms()})
        else
          :ets.insert(table, {key, :closed, new_count, 0})
        end

      [{^key, :open, failures, opened_at}] ->
        # Already open, just bump the count
        :ets.insert(table, {key, :open, failures + 1, opened_at})
    end

    :ok
  end

  @doc "Manually reset a circuit to closed."
  @spec reset(:ets.tid(), key()) :: :ok
  def reset(table, key) do
    :ets.delete(table, key)
    :ok
  end

  @doc "Reset all circuit breaker state."
  @spec reset_all(:ets.tid()) :: :ok
  def reset_all(table) do
    :ets.delete_all_objects(table)
    :ok
  end

  @doc "Get the current status of a circuit."
  @spec status(:ets.tid(), key()) :: %{state: state(), failures: non_neg_integer()}
  def status(table, key) do
    case :ets.lookup(table, key) do
      [] -> %{state: :closed, failures: 0}
      [{^key, state, failures, _opened_at}] -> %{state: state, failures: failures}
    end
  end

  # -- Private -----------------------------------------------------------------

  defp get_opt(opts, :failure_threshold) do
    Keyword.get_lazy(opts, :failure_threshold, fn ->
      config()[:failure_threshold] || @default_failure_threshold
    end)
  end

  defp get_opt(opts, :recovery_ms) do
    Keyword.get_lazy(opts, :recovery_ms, fn ->
      config()[:recovery_ms] || @default_recovery_ms
    end)
  end

  defp config do
    Application.get_env(:raxol_mcp, :circuit_breaker, [])
  end

  defp now_ms, do: System.monotonic_time(:millisecond)
end
