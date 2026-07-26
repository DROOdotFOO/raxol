defmodule Raxol.Payments.Checkpoint do
  @moduledoc """
  Durable idempotency record for an in-flight payment intent.

  Cross-chain settlement is asynchronous: there is a window between dispatching
  an intent (signing and submitting it to the solver) and confirming it landed.
  A crash in that window is where an ungoverned runtime loses money, the
  restarted agent has no memory of the in-flight payment, re-quotes, and signs a
  second time.

  A Checkpoint persists the in-flight intent keyed by a stable idempotency key.
  A resumed Action looks the key up first and polls the existing intent instead
  of starting a new one, so the signature is released exactly once across a
  crash.

  ## Injection

  The store is passed through the Action context under `:checkpoint` as a
  `{module, handle}` pair, where `module` implements this behaviour and `handle`
  is whatever that module needs to address its storage (an ETS table, a pid, a
  bridge to an agent context store). When the context carries no checkpoint the
  recovery path is a no-op and the Action behaves exactly as it did before.

  The store must outlive the calling process for recovery to work: an ETS table
  owned by the agent itself dies with the crash it is meant to survive. Use a
  table owned by a supervisor-level process (see `Raxol.Payments.Checkpoint.ETS`)
  or back it with durable storage for cross-restart recovery.

  ## Record shape

  A record is a plain map whose shape the calling Action defines. The
  load-bearing field is the id a resume polls -- `:intent_id` for the Xochi
  intent, `:transfer_id` for the Relay transfer. Implementations persist whatever
  else the caller stores; both payment Actions store the full result summary so a
  resume can return it without re-deriving anything.
  """

  @type handle :: term()
  @type store :: {module(), handle()}
  @type key :: String.t()
  # Named `entry`, not `record`: `record` shadows a dialyzer built-in type, which
  # makes callers' map patterns/args (e.g. `%{"tx_hash" => _}`) look like they can
  # never match `record()`. `entry` is a plain map alias with no such collision.
  @type entry :: map()

  @doc "Fetch the record stored under `key`, or `:error` if none."
  @callback fetch(handle(), key()) :: {:ok, entry()} | :error

  @doc "Store `record` under `key`, overwriting any existing record."
  @callback put(handle(), key(), entry()) :: :ok

  @doc "Remove any record stored under `key`."
  @callback delete(handle(), key()) :: :ok

  @doc """
  Fetch the in-flight record for `key`.

  Returns `:error` when no store is configured (`nil`), so a caller can treat a
  missing checkpoint and a disabled checkpoint identically.
  """
  @spec fetch(store() | nil, key()) :: {:ok, entry()} | :error
  def fetch(nil, _key), do: :error
  def fetch({module, handle}, key) when is_atom(module), do: module.fetch(handle, key)

  @doc "Store the in-flight record for `key`. No-op when no store is configured."
  @spec put(store() | nil, key(), entry()) :: :ok
  def put(nil, _key, _record), do: :ok
  def put({module, handle}, key, record) when is_atom(module), do: module.put(handle, key, record)

  @doc "Drop the record for `key`. No-op when no store is configured."
  @spec delete(store() | nil, key()) :: :ok
  def delete(nil, _key), do: :ok
  def delete({module, handle}, key) when is_atom(module), do: module.delete(handle, key)

  @doc """
  Derive a stable idempotency key from the canonical fields of a logical payment.

  The same payment (same wallet, route, token, amount, and settlement intent)
  yields the same key, so a resumed Action recognizes it. Two payments that
  share every field collide by design; a caller that needs them treated as
  distinct supplies its own key via `context[:idempotency_key]`.
  """
  @spec derive_key([term()]) :: key()
  def derive_key(fields) when is_list(fields) do
    fields
    |> Enum.map_join("\x1f", &to_string/1)
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end
end
