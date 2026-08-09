defmodule Raxol.Agent.Setup do
  @moduledoc """
  Non-TUI provider setup: the logic behind `mix raxol.setup`.

  The coding TUI's `/login` is the interactive way to connect an LLM
  provider, but it needs a terminal. This module is the headless twin —
  store a provider's 1Password reference (or turn a raw key into one) and
  validate it — for CI, scripts, and remote/headless boxes where the TUI is
  not reachable. It reuses the same `Raxol.Agent.Backend.{Credentials,
  Resolver}` front door, so a provider connected here is picked up
  identically by every surface that resolves through them.

  Nothing here holds a secret at rest: a raw key is turned into a
  `op://...` reference via `Credentials.create_item/3` (1Password), and only
  the reference is written to `~/.raxol/providers.json`.

  The `:validator` and `:creator` seams are injectable so the store/validate
  logic is testable without a network call or the `op` CLI.
  """

  alias Raxol.Agent.Backend.Credentials
  alias Raxol.Agent.Backend.HTTP
  alias Raxol.Agent.Backend.Resolver
  alias Raxol.Agent.Backend.Selector

  @type validation ::
          :valid
          | {:rejected, non_neg_integer()}
          | {:reachable_error, non_neg_integer()}
          | :unreachable
          | :unsupported
          | {:no_key, atom()}
          | :no_provider

  @doc """
  A point-in-time detection snapshot: the `op` CLI state plus each provider's
  availability. Delegates to `Resolver.diagnostics/0`.
  """
  @spec status() :: %{op: atom(), providers: [map()]}
  def status, do: Resolver.diagnostics()

  @doc """
  Store an `op://...` reference (plus optional `:model`/`:base_url`) for a
  provider, then validate that the credential resolves and authorizes.

  Returns `{:ok, harness, validation}` or `{:error, reason}`. `attrs` must
  carry a non-empty `:op_ref`.
  """
  @spec connect_ref(atom() | String.t(), map() | keyword(), keyword()) ::
          {:ok, atom(), validation()} | {:error, term()}
  def connect_ref(harness, attrs, opts \\ []) do
    attrs = Map.new(attrs)

    with {:ok, provider} <- resolve_harness(harness),
         {:ok, ref} <- require_op_ref(attrs),
         :ok <- Credentials.put(provider, ref_entry(ref, attrs)) do
      {:ok, provider, validate(provider, opts)}
    end
  end

  @doc """
  Turn a raw `key` into a 1Password item, store its reference for the
  provider, then validate. Requires the `op` CLI (the `:creator` seam
  defaults to `Credentials.create_item/3`).

  `:vault` and `:timeout_ms` reach the creator; the latter is for callers
  whose user is looking somewhere else when 1Password raises its prompt.

  Returns `{:ok, harness, op_ref, validation}` or `{:error, reason}`.
  """
  @spec connect_key(atom() | String.t(), String.t(), keyword()) ::
          {:ok, atom(), String.t(), validation()} | {:error, term()}
  def connect_key(harness, key, opts \\ []) do
    creator = Keyword.get(opts, :creator, &Credentials.create_item/3)
    attrs = Map.new(Keyword.take(opts, [:model, :base_url]))

    with {:ok, provider} <- resolve_harness(harness),
         {:ok, ref} <-
           creator.(provider, key, Keyword.take(opts, [:vault, :timeout_ms])),
         :ok <- Credentials.put(provider, ref_entry(ref, attrs)) do
      {:ok, provider, ref, validate(provider, opts)}
    end
  end

  @doc "Remove a provider's stored reference. Returns `{:ok, harness}` or `{:error, reason}`."
  @spec remove(atom() | String.t()) :: {:ok, atom()} | {:error, term()}
  def remove(harness) do
    with {:ok, provider} <- resolve_harness(harness),
         :ok <- Credentials.delete(provider) do
      {:ok, provider}
    end
  end

  # -- validation -------------------------------------------------------------

  defp validate(provider, opts) do
    validator = Keyword.get(opts, :validator, &default_validate/1)
    validator.(provider)
  end

  # Resolve the stored reference to a live executor and hit the provider's
  # auth-check endpoint (no tokens spent). A resolution that yields no key or
  # no provider is surfaced verbatim so the caller can report it.
  defp default_validate(provider) do
    case Resolver.resolve(harness: provider) do
      {:ok, executor, _source} -> check_credential(executor)
      other -> other
    end
  end

  # Route through `Selector` rather than assembling backend opts here: it is
  # the single source of truth for which wire dialect and base URL a harness
  # speaks. Passing `executor.backend` as `:provider` looked equivalent only
  # because the four original providers are named after their dialect. For
  # openrouter, lm_studio, llm7 and longcat -- all of which speak `:openai` at
  # their own base URL -- it named a dialect `Backend.HTTP` has never heard of,
  # so each one silently validated as `:unsupported` and a dead credential
  # reported "stored" instead of failing.
  #
  # Only the HTTP backend has an auth-check endpoint; Lumo, Native and Mock
  # have nothing to hit, so they stay honestly unsupported.
  defp check_credential(executor) do
    case Selector.select(executor) do
      {:ok, HTTP, opts} -> HTTP.check_auth(opts)
      {:ok, _module, _opts} -> :unsupported
      {:error, _reason} -> :unsupported
    end
  end

  # -- helpers ----------------------------------------------------------------

  defp resolve_harness(harness) when is_atom(harness), do: {:ok, harness}

  defp resolve_harness(harness) when is_binary(harness) do
    case Resolver.harness_from_string(harness) do
      {:ok, provider} -> {:ok, provider}
      :error -> {:error, {:unknown_provider, harness}}
    end
  end

  defp require_op_ref(attrs) do
    case Map.get(attrs, :op_ref) do
      "op://" <> _ = ref -> {:ok, ref}
      _ -> {:error, :not_an_op_ref}
    end
  end

  defp ref_entry(ref, attrs) do
    %{op_ref: ref}
    |> maybe_put(:model, Map.get(attrs, :model))
    |> maybe_put(:base_url, Map.get(attrs, :base_url))
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, _key, ""), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
