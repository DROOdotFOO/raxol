defmodule Raxol.Payments.Xochi.SettlementState do
  @moduledoc false

  alias Raxol.Payments.Checkpoint
  alias Raxol.Payments.Xochi.ReadTokenStore

  @terminal_ttl_seconds 86_400

  @spec principal(map(), module() | String.t() | nil) :: String.t() | nil
  def principal(context, wallet \\ nil)

  def principal(%{agent_id: id}, _wallet) when is_binary(id) and id != "",
    do: "agent:" <> id

  def principal(%{agent_id: id}, _wallet) when is_atom(id) and not is_nil(id),
    do: "agent:" <> Atom.to_string(id)

  def principal(%{wallet: wallet}, nil), do: principal(%{}, wallet)

  def principal(_context, wallet) when is_atom(wallet) and not is_nil(wallet) do
    if function_exported?(wallet, :address, 0), do: principal(%{}, wallet.address())
  end

  def principal(_context, wallet) when is_binary(wallet) and wallet != "",
    do: "wallet:" <> String.downcase(wallet)

  def principal(_context, _wallet), do: nil

  @spec fingerprint(term()) :: String.t()
  def fingerprint(term) do
    term
    |> :erlang.term_to_binary([:deterministic])
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  @spec bind(
          Checkpoint.store() | nil,
          String.t(),
          String.t(),
          String.t(),
          integer() | nil,
          integer(),
          keyword()
        ) :: :ok
  def bind(store, base_url, principal, intent_id, deadline, now, opts \\ []) do
    sweep(store, now)

    record = %{
      kind: :xochi_owner,
      principal: principal,
      intent_id: intent_id,
      deadline: deadline,
      expires_at: max(deadline || now, now) + @terminal_ttl_seconds
    }

    record =
      case Keyword.get(opts, :dispatch_key) do
        key when is_binary(key) -> Map.put(record, :dispatch_key, key)
        _ -> record
      end

    Checkpoint.put(store, owner_key(base_url, principal, intent_id), record)
  end

  @spec owner(Checkpoint.store() | nil, String.t(), String.t() | nil, String.t(), integer()) ::
          {:ok, map()} | :error
  def owner(_store, _base_url, nil, _intent_id, _now), do: :error

  def owner(store, base_url, principal, intent_id, now) do
    sweep(store, now)

    case Checkpoint.fetch(store, owner_key(base_url, principal, intent_id)) do
      {:ok, %{kind: :xochi_owner, principal: ^principal, intent_id: ^intent_id} = record} ->
        {:ok, record}

      _ ->
        :error
    end
  end

  @spec forget(Checkpoint.store() | nil, String.t(), String.t(), String.t()) :: :ok
  def forget(store, base_url, principal, intent_id) do
    Checkpoint.delete(store, owner_key(base_url, principal, intent_id))
  end

  @spec commit_terminal(
          Checkpoint.store() | nil,
          String.t(),
          String.t(),
          String.t(),
          term(),
          integer()
        ) :: :ok
  def commit_terminal(store, base_url, principal, intent_id, result, now) do
    Checkpoint.put(store, terminal_key(base_url, principal, intent_id), %{
      kind: :xochi_terminal,
      principal: principal,
      intent_id: intent_id,
      result: result,
      expires_at: now + @terminal_ttl_seconds
    })

    ReadTokenStore.delete(store, base_url, principal, intent_id)
  end

  @spec terminal(Checkpoint.store() | nil, String.t(), String.t() | nil, String.t(), integer()) ::
          {:ok, term()} | :error
  def terminal(_store, _base_url, nil, _intent_id, _now), do: :error

  def terminal(store, base_url, principal, intent_id, now) do
    sweep(store, now)

    case Checkpoint.fetch(store, terminal_key(base_url, principal, intent_id)) do
      {:ok, %{kind: :xochi_terminal, principal: ^principal, result: result}} ->
        ReadTokenStore.delete(store, base_url, principal, intent_id)
        {:ok, result}

      _ ->
        :error
    end
  end

  @spec sweep(Checkpoint.store() | nil, integer()) :: :ok
  def sweep(store, now), do: Checkpoint.sweep_expired(store, now)

  @spec owner_key(String.t(), String.t(), String.t()) :: Checkpoint.key()
  def owner_key(base_url, principal, intent_id) do
    Checkpoint.derive_key([:xochi_owner, ReadTokenStore.origin(base_url), principal, intent_id])
  end

  @spec terminal_key(String.t(), String.t(), String.t()) :: Checkpoint.key()
  def terminal_key(base_url, principal, intent_id) do
    Checkpoint.derive_key([
      :xochi_terminal,
      ReadTokenStore.origin(base_url),
      principal,
      intent_id
    ])
  end
end
