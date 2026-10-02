defmodule Raxol.Core.ChildEnv do
  @moduledoc """
  The environment a spawned OS process gets: the node's own, minus the secrets
  the BEAM consumes.

  An Erlang port inherits the whole environment of the node. Every place raxol
  spawns something a model or a third party chose -- a shell command, a
  background job, a directive, an LSP server, an MCP stdio server, a vendor
  agent CLI, a Symphony runner or workspace hook, a benchmarked agent package
  -- would otherwise hand that process the Sleuth key the `fx` tool spends, a
  share-link secret, a signing key or a bearer token, for a prompt-injected
  `printenv` to read.

  `port_env/1` builds the `{:env, _}` value for `Port.open/2`: the caller's own
  variables, plus each secret the caller did not set, mapped to `false`, which
  unsets it in the child. A caller that passes a secret explicitly keeps it,
  and a caller's own `false` is passed through as Port's unset marker.

  ## Configuration

  Read when a child is spawned, so a runtime change applies to the next one:

      config :raxol_core, Raxol.Core.ChildEnv,
        # More names to unset, e.g. a custom `Wallets.Env` `env_var:`.
        extra_secrets: ["MY_WALLET_KEY"],
        # Names to let through after all. A raxol node started from a raxol
        # shell or as an MCP stdio server needs RAXOL_SLEUTH_API_KEY to boot
        # with `fx:` configured.
        pass: ["RAXOL_SLEUTH_API_KEY"]

  ## Using it

  Port honours only the LAST `{:env, _}` in its options, so `port_env/1` must
  be the only one, or the last: a later `{:env, _}` drops the scrub silently.

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
    XOCHI_AUTH_TOKEN
  )

  @doc "The variables unset in every child: the built-in set plus `:extra_secrets`, minus `:pass`."
  @spec secrets() :: [String.t()]
  def secrets do
    config = Application.get_env(:raxol_core, __MODULE__, [])
    pass = Keyword.get(config, :pass, [])

    (@secrets ++ Keyword.get(config, :extra_secrets, []))
    |> Enum.uniq()
    |> Enum.reject(&(&1 in pass))
  end

  @doc """
  A `Port.open/2` `:env` value: `env` (names and values as strings or
  charlists, or `false` to unset) followed by every secret it does not name,
  unset.
  """
  @spec port_env([{String.t() | charlist(), String.t() | charlist() | false}]) ::
          [{charlist(), charlist() | false}]
  def port_env(env \\ []) do
    given = Enum.map(env, fn {name, value} -> {to_charlist(name), value(value)} end)

    unset =
      for name <- secrets(),
          name = String.to_charlist(name),
          not List.keymember?(given, name, 0),
          do: {name, false}

    given ++ unset
  end

  defp value(false), do: false
  defp value(value), do: to_charlist(value)
end
