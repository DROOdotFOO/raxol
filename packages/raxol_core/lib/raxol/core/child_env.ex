defmodule Raxol.Core.ChildEnv do
  @moduledoc """
  The environment a spawned OS process gets: the node's own, minus the secrets
  the BEAM consumes and no child needs.

  An Erlang port inherits the whole environment of the node. Every place raxol
  spawns something a model or a third party chose -- a shell command, a
  background job, a directive, an LSP server, an MCP stdio server, a vendor
  agent CLI -- would otherwise hand that process the Sleuth key the `fx` tool
  spends, a share-link secret or a signing key, for a prompt-injected
  `printenv` to read.

  `port_env/1` builds the `{:env, _}` value for `Port.open/2`: the caller's own
  variables, plus each secret the caller did not set, mapped to `false`, which
  unsets it in the child. A caller that passes a secret explicitly keeps it.

  ## What this does not do

  It stops inheritance, not every read. A process running as the same user
  can still read the node's launch environment (`ps -E` on macOS,
  `/proc/<pid>/environ` on Linux). Keeping a secret away from those means not
  putting it in the node's environment at all: a config provider, a 0600 file
  or `op`.
  """

  @secrets ~w(
    RAXOL_SLEUTH_API_KEY
    RAXOL_SHARE_SECRET
    RAXOL_SESSION_STREAM_TOKEN
    RAXOL_WALLET_KEY
    RAXOL_ACP_AGENT_PRIVATE_KEY
  )

  @doc "The variables unset in every child unless the caller passes them."
  @spec secrets() :: [String.t()]
  def secrets, do: @secrets

  @doc """
  A `Port.open/2` `:env` value: `env` (names and values as strings or
  charlists) followed by every secret it does not name, unset.
  """
  @spec port_env([{String.t() | charlist(), String.t() | charlist()}]) ::
          [{charlist(), charlist() | false}]
  def port_env(env \\ []) do
    given = Enum.map(env, fn {name, value} -> {to_charlist(name), to_charlist(value)} end)

    unset =
      for name <- @secrets,
          name = String.to_charlist(name),
          not List.keymember?(given, name, 0),
          do: {name, false}

    given ++ unset
  end
end
