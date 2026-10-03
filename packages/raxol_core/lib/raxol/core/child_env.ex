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
  `cmd_env/1` is the same for `System.cmd/3`'s `:env` option, whose unset
  marker is `nil`.

  ## Configuration

  Read when a child is spawned, so a runtime change applies to the next one.
  The config must be a keyword list and both keys lists of variable names
  (strings matching `[A-Za-z_][A-Za-z0-9_]*`); anything else raises an
  `ArgumentError` naming the key at the next spawn, instead of scrubbing less
  than the operator meant:

      config :raxol_core, Raxol.Core.ChildEnv,
        # More names to unset, e.g. a custom `Wallets.Env` `env_var:`.
        extra_secrets: ["MY_WALLET_KEY"],
        # Names to let through after all, to EVERY child (see below).
        pass: ["RAXOL_SLEUTH_API_KEY"]

  `pass:` is global: a passed name reaches every child the node spawns --
  shell commands and jobs, directives, MCP and LSP servers, vendor agent
  CLIs, Symphony runners and hooks, the earn bench's agent packages -- not
  only the one that needs it. A nested raxol node that needs the Sleuth key
  should get it from its own `config :raxol_agent, :web3, fx: [sleuth_api_key:
  ...]` instead; a single spawn site that must hand one child a secret names
  it in that call's `env` (`port_env/1` keeps an explicitly given secret).

  ## Using it

  Port honours only the LAST `{:env, _}` in its options, so `port_env/1` must
  be the only one, or the last: a later `{:env, _}` drops the scrub silently.
  For `System.cmd/3`, pass `cmd_env/1` as `:env`, never `port_env/1`: it
  takes `nil`, not `false`, as the unset marker.

  ## What this does not do

  It stops inheritance, not every read. A process running as the same user
  can still read the node's launch environment (`ps -E` on macOS,
  `/proc/<pid>/environ` on Linux). Keeping a secret away from those means not
  putting it in the node's environment at all: a config provider, a 0600 file
  or `op`.

  Nor does it hide what a caller hands a child on purpose. A vendor agent CLI
  runs its own shell tool as the node's user, so a variable passed to the CLI,
  or written into the MCP config of a server it launches
  (`Raxol.Agent.Backend.Native`'s `:env` and `:mcp_env`), is readable by any
  command the CLI's model runs.
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
    config = config!()
    pass = names!(config, :pass)

    (@secrets ++ names!(config, :extra_secrets))
    |> Enum.uniq()
    |> Enum.reject(&(&1 in pass))
  end

  defp config! do
    case Application.get_env(:raxol_core, __MODULE__, []) do
      config when is_list(config) ->
        if Keyword.keyword?(config),
          do: config,
          else: invalid!("must be a keyword list", config)

      config ->
        invalid!("must be a keyword list", config)
    end
  end

  defp names!(config, key) do
    case Keyword.get(config, key, []) do
      names when is_list(names) ->
        Enum.each(names, &name!(&1, key))
        names

      names ->
        invalid!("#{inspect(key)} must be a list of variable names", names)
    end
  end

  defp name!(name, key) do
    unless is_binary(name) and name =~ ~r/\A[A-Za-z_][A-Za-z0-9_]*\z/ do
      invalid!("#{inspect(key)} must be a list of variable names", name)
    end
  end

  defp invalid!(problem, got) do
    raise ArgumentError,
          "config :raxol_core, Raxol.Core.ChildEnv: #{problem}, got: #{inspect(got)}"
  end

  @doc """
  A `Port.open/2` `:env` value: `env` (names and values as strings or
  charlists, or `false` to unset) followed by every secret it does not name,
  unset.
  """
  @spec port_env([{String.t() | charlist(), String.t() | charlist() | false}]) ::
          [{charlist(), charlist() | false}]
  def port_env(env \\ []) do
    given =
      Enum.map(env, fn {name, value} -> {to_charlist(name), value(value)} end)

    unset =
      for name <- secrets(),
          name = String.to_charlist(name),
          not List.keymember?(given, name, 0),
          do: {name, false}

    given ++ unset
  end

  defp value(false), do: false
  defp value(value), do: to_charlist(value)

  @doc """
  A `System.cmd/3` `:env` value: `env` (string names and values, or `nil` to
  unset) followed by every secret it does not name, mapped to `nil`.
  """
  @spec cmd_env([{String.t(), String.t() | nil}]) :: [{String.t(), String.t() | nil}]
  def cmd_env(env \\ []) do
    unset = for name <- secrets(), not List.keymember?(env, name, 0), do: {name, nil}
    env ++ unset
  end
end
