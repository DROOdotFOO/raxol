defmodule Raxol.Broker.KeyProvider do
  @moduledoc """
  Where the 256-bit key that wraps the stored brokerage credential lives.

  The key is never written beside the ciphertext. `resolve/1` picks, in
  order: an explicit `:key_provider` option (`{module, opts}`), 1Password when
  the `op` CLI is installed (`Raxol.Broker.KeyProvider.OnePassword`), and the
  macOS login keychain (`Raxol.Broker.KeyProvider.Keychain`). Anywhere else
  there is no key store, so there is no credential store either:
  `{:error, {:keychain_unavailable, :unsupported_os}}`, never plaintext.
  """

  alias Raxol.Agent.Backend.Credentials

  @typedoc "A 32-byte AES-256 key."
  @type key :: <<_::256>>

  @doc "Read the existing key: `{:ok, key}`, `:none` if there is none yet, or `{:error, reason}`."
  @callback load_key(keyword()) :: {:ok, key()} | :none | {:error, term()}

  @doc """
  Create and store a new key, or return the one another writer stored first.
  Never replaces an existing key: that would orphan every ciphertext under it.
  """
  @callback create_key(keyword()) :: {:ok, key()} | {:error, term()}

  @doc "The provider for `opts`, as `{module, provider_opts}`."
  @spec resolve(keyword()) :: {:ok, {module(), keyword()}} | {:error, term()}
  def resolve(opts) do
    case Keyword.fetch(opts, :key_provider) do
      {:ok, {module, provider_opts}} when is_atom(module) and is_list(provider_opts) ->
        {:ok, {module, provider_opts}}

      :error ->
        default()
    end
  end

  defp default do
    cond do
      Credentials.op_available?() -> {:ok, {__MODULE__.OnePassword, []}}
      match?({:unix, :darwin}, :os.type()) -> {:ok, {__MODULE__.Keychain, []}}
      true -> {:error, {:keychain_unavailable, :unsupported_os}}
    end
  end

  @doc false
  # A key read back from a store is checked before it is used: a wrong-length
  # value would reach `:crypto` as a badarg whose stack frame carries it.
  @spec decode_hex(String.t()) :: {:ok, key()} | :error
  def decode_hex(text) when is_binary(text) do
    case Base.decode16(String.trim(text), case: :mixed) do
      {:ok, <<_::256>> = key} -> {:ok, key}
      _invalid -> :error
    end
  end
end
