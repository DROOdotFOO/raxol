defmodule Raxol.Broker.Login do
  @moduledoc """
  Sign in to Robinhood in the browser and store the credential encrypted.

  `run/1` is `Raxol.Agent.Auth.Flow.run(:robinhood, auth_opts)` followed by
  `Raxol.Broker.CredentialStore.put/2`; `Raxol.Broker.MCP.Client` then reads
  the stored credential. Nothing is stored unless the whole sign-in
  succeeded, and a store that cannot hold the key (no 1Password, no
  keychain) fails the login rather than writing plaintext.

  Options: `:auth` (passed to the flow: `:browser_fn`, `:http_fn`,
  `:timeout`) and `:store` (passed to the store: `:path`, `:key_provider`).
  """

  alias Raxol.Agent.Auth.Flow
  alias Raxol.Broker.CredentialStore

  @spec run(keyword()) :: :ok | {:error, term()}
  def run(opts \\ []) do
    with {:ok, credential} <- Flow.run(:robinhood, Keyword.get(opts, :auth, [])) do
      CredentialStore.put(credential, Keyword.get(opts, :store, []))
    end
  end
end
