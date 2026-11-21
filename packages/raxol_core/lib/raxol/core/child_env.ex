defmodule Raxol.Core.ChildEnv do
  @moduledoc """
  The environment a spawned OS process gets: the node's own, minus the
  credentials in it.

  An Erlang port inherits the whole environment of the node. Every place raxol
  spawns something a model or a third party chose -- a directive's shell
  command, an MCP stdio server, a benchmarked agent package -- would otherwise
  hand that process the Sleuth key the `fx` tool spends, a provider API key, a
  share-link secret, a signing key or a bearer token, for a prompt-injected
  `printenv` to read.

  ## What is unset

    * every variable set in the node whose name looks like a credential
      (case-insensitive):
        * a suffix of `_KEY`, `_KEY_ID`, `_TOKEN`, `_PRIVKEY`, `_SECRET`,
          `_PASSWORD`, `_PASSPHRASE`, `_MNEMONIC`, `_CREDENTIALS` or
          `_APIKEY` (so `ANTHROPIC_API_KEY`, `GH_TOKEN`,
          `RAXOL_ACP_AGENT_PRIVATE_KEY`, `AWS_ACCESS_KEY_ID`,
          `AWS_SECRET_ACCESS_KEY`, `OPENAI_APIKEY`);
        * `DATABASE_URL`, alone or as a suffix (`REPO_DATABASE_URL`), which
          carries the database password;
        * `PGPASSWORD` and any other `PG...PASSWORD` (`PGADMIN_PASSWORD`);
        * `RPC` anywhere in the name (`ETH_RPC`, `BASE_RPC_URL`, `RPC_BASE`,
          `MAINNETRPC`), since a provider RPC URL embeds its API key -- except
          as part of `GRPC`, whose variables are gRPC library settings;
    * the names in `secrets/0`: raxol's own variables, the web endpoint's
      `SECRET_KEY_BASE`, the release's `RELEASE_COOKIE` (which lets its
      holder join the node over distribution), `SSH_AUTH_SOCK` (which hands
      the child the operator's ssh-agent) and the configured
      `:extra_secrets`, unset whether or not the node has them now, so one
      exported after the env was built is still covered when the child starts;
    * minus `pass/0`, the operator's allowlist, which reaches the child after
      all.

  `secret?/1` says whether a child is denied one name.

  Tools that read a credential from the environment lose it too: `npx`
  resolving `${NPM_TOKEN}` in an `.npmrc`, `NODE_AUTH_TOKEN`, or the file path
  in `GOOGLE_APPLICATION_CREDENTIALS`. Give such a variable to the one child
  that needs it through that spawn's `env` (an `.mcp.json` server's `env`),
  or to every child through `pass:`.

  `port_env/1` builds the `{:env, _}` value for `Port.open/2`: the caller's own
  variables, plus each credential the caller did not set, mapped to `false`,
  which unsets it in the child. A caller that passes a credential explicitly
  keeps it, and a caller's own `false` is passed through as Port's unset
  marker. `cmd_env/1` is the same for `System.cmd/3`'s `:env` option, whose
  unset marker is `nil`.

  ## Configuration

  Read when a child is spawned, so a runtime change applies to the next one.
  The config must be a keyword list and both keys lists of variable names
  (strings matching `[A-Za-z_][A-Za-z0-9_]*`); anything else raises an
  `ArgumentError` naming the key at the next spawn, instead of scrubbing less
  than the operator meant:

      config :raxol_core, Raxol.Core.ChildEnv,
        # More names to unset, e.g. a custom `Wallets.Env` `env_var:` whose
        # name no pattern catches.
        extra_secrets: ["MY_WALLET"],
        # Names to let through after all, to EVERY child (see below).
        pass: ["GH_TOKEN"]

  `pass:` is exact and case-sensitive, and global: a passed name reaches
  every child the node spawns -- directive shell commands, MCP stdio servers,
  the earn bench's agent packages -- not only the one that needs it. A nested
  raxol node that needs the Sleuth key should get it from its own
  `config :raxol_agent, :web3, fx: [sleuth_api_key:
  ...]` instead; a single spawn site that must hand one child a credential
  names it in that call's `env` (`port_env/1` keeps an explicitly given
  one), as an `.mcp.json` server's `env` does.

  ## Using it

  Port honours only the LAST `{:env, _}` in its options, so `port_env/1` must
  be the only one, or the last: a later `{:env, _}` drops the scrub silently.
  For `System.cmd/3`, pass `cmd_env/1` as `:env`, never `port_env/1`: it
  takes `nil`, not `false`, as the unset marker.

  ## What this does not do

  It stops inheritance, not every read. A process running as the same user
  can still read the node's launch environment (`ps -E` on macOS,
  `/proc/<pid>/environ` on Linux, including the port helper's via `$PPID`).
  Keeping a secret away from those means not putting it in the node's
  environment at all: a config provider, a 0600 file or `op`.

  A credential under a name no pattern catches is inherited unless it is in
  `:extra_secrets`: a provider URL with a key in it under another name
  (`ALCHEMY_URL`), `MYSQL_PWD`, a bare `TOKEN`. A name that is not valid
  UTF-8 is also missed: the BEAM reads it re-encoded, so the unset names a
  different variable.

  Nor does it hide what a caller hands a child on purpose: a variable named
  in a spawn's `env` is readable by everything that child runs.
  """

  # Raxol's own credentials, plus the BEAM's: the web endpoint's signing key
  # and the release cookie, which lets anything holding it join the node over
  # distribution and run code in it; and the operator's ssh-agent socket. No
  # pattern catches those three.
  @secrets ~w(
    RAXOL_SLEUTH_API_KEY
    RAXOL_SHARE_SECRET
    RAXOL_SESSION_STREAM_TOKEN
    RAXOL_WALLET_KEY
    RAXOL_ACP_AGENT_PRIVATE_KEY
    XOCHI_AUTH_TOKEN
    SECRET_KEY_BASE
    RELEASE_COOKIE
    SSH_AUTH_SOCK
  )

  # A name ending like a credential, a `DATABASE_URL`, a `PG...PASSWORD`, or
  # `RPC` anywhere but in `GRPC`; matched case-insensitively. This is a
  # superset of the pattern raxol-agent's `Raxol.Agent.ChildEnv` and
  # `Raxol.AgentClientProtocol.Transport.Stdio` keep (as of raxol_core 2.8.0:
  # no `_APIKEY`, `DATABASE_URL` or `PG...PASSWORD`, and `RPC` only as an
  # `RPC_` segment); they move to `credential_pattern/0` when they require
  # raxol_core ~> 2.9. Held as source and compiled per call (once per spawn,
  # not per variable), so no compiled regex is baked into the module.
  @credential_source ~S"(_KEY|_KEY_ID|_TOKEN|_PRIVKEY|_SECRET|_PASSWORD|_PASSPHRASE|_MNEMONIC|_CREDENTIALS|_APIKEY)\z|(\A|_)DATABASE_URL\z|\APG\w*PASSWORD\z|(?<!G)RPC"

  @doc """
  The credential-name pattern, compiled with its case-insensitive flag. A
  package that keeps its own copy (one that cannot depend on `raxol_core` at
  runtime) checks it against this in a test, comparing `Regex.source/1` and
  `Regex.opts/1`.
  """
  @spec credential_pattern() :: Regex.t()
  def credential_pattern, do: Regex.compile!(@credential_source, "i")

  @typep config :: %{pass: [String.t()], extra_secrets: [String.t()]}

  @doc """
  The names unset in every child whether or not the node has them: the
  built-in set plus `:extra_secrets`, minus `:pass`. Pattern matches are on
  top of these; see `secret?/1`.
  """
  @spec secrets() :: [String.t()]
  def secrets, do: named(config!())

  @doc """
  The operator's `pass:` list: names that reach every child even though they
  are credentials. Raises `ArgumentError` on a malformed config.
  """
  @spec pass() :: [String.t()]
  def pass, do: config!().pass

  @doc """
  Whether a child is denied `name`: it is in `secrets/0` (which already
  leaves out `pass/0`), or it matches the credential pattern and is not in
  `pass/0`. `port_env/1` and `cmd_env/1` unset exactly the variables of the
  node for which this is true, plus `secrets/0` whether set or not.
  """
  @spec secret?(String.t()) :: boolean()
  def secret?(name) when is_binary(name) do
    config = config!()
    name in named(config) or (credential?(credential_pattern(), name) and name not in config.pass)
  end

  @spec credential?(Regex.t(), String.t()) :: boolean()
  defp credential?(pattern, name), do: Regex.match?(pattern, name)

  @spec named(config()) :: [String.t()]
  defp named(%{pass: pass, extra_secrets: extra}) do
    (@secrets ++ extra)
    |> Enum.uniq()
    |> Enum.reject(&(&1 in pass))
  end

  # Every name a child must not inherit: the named set (`pass:` already out),
  # plus each of the `present` names (the node's variables) that matches the
  # pattern and is not passed.
  @spec unset_names(config(), [String.t()]) :: [String.t()]
  defp unset_names(%{pass: pass} = config, present) do
    pattern = credential_pattern()
    matching = Enum.filter(present, &(credential?(pattern, &1) and &1 not in pass))
    Enum.uniq(named(config) ++ matching)
  end

  @spec unset_names() :: [String.t()]
  defp unset_names, do: unset_names(config!(), System.get_env() |> Map.keys())

  # The whole config, validated, so every entry point raises on any bad key.
  @spec config!() :: config()
  defp config! do
    case Application.get_env(:raxol_core, __MODULE__, []) do
      config when is_list(config) ->
        if Keyword.keyword?(config),
          do: %{pass: names!(config, :pass), extra_secrets: names!(config, :extra_secrets)},
          else: invalid!("must be a keyword list", config)

      config ->
        invalid!("must be a keyword list", config)
    end
  end

  @spec names!(keyword(), :pass | :extra_secrets) :: [String.t()]
  defp names!(config, key) do
    case Keyword.get(config, key, []) do
      names when is_list(names) ->
        Enum.each(names, &name!(&1, key))
        names

      names ->
        invalid!("#{inspect(key)} must be a list of variable names", names)
    end
  end

  @spec name!(term(), :pass | :extra_secrets) :: :ok
  defp name!(name, key) do
    if is_binary(name) and name =~ ~r/\A[A-Za-z_][A-Za-z0-9_]*\z/,
      do: :ok,
      else: invalid!("#{inspect(key)} must be a list of variable names", redact(name))
  end

  # A string that is not a variable name may be the value an operator pasted
  # in its place (a key), so the error names its size, not its contents.
  @spec redact(term()) :: term()
  defp redact(name) when is_binary(name), do: {:string, byte_size(name), :bytes}
  defp redact(name), do: name

  @spec invalid!(String.t(), term()) :: no_return()
  defp invalid!(problem, got) do
    raise ArgumentError,
          "config :raxol_core, Raxol.Core.ChildEnv: #{problem}, got: #{inspect(got)}"
  end

  @doc """
  A `Port.open/2` `:env` value: `env` (names and values as strings or
  charlists, or `false` to unset) followed by every credential it does not
  name, mapped to `false` (unset).
  """
  @spec port_env([{String.t() | charlist(), String.t() | charlist() | false}]) ::
          [{charlist(), charlist() | false}]
  def port_env(env \\ []) do
    given =
      Enum.map(env, fn {name, value} -> {to_charlist(name), value(value)} end)

    unset =
      for name <- unset_names(),
          name = String.to_charlist(name),
          not List.keymember?(given, name, 0),
          do: {name, false}

    given ++ unset
  end

  @spec value(String.t() | charlist() | false) :: charlist() | false
  defp value(false), do: false
  defp value(value), do: to_charlist(value)

  @doc """
  A `System.cmd/3` `:env` value: `env` (string names and values, or `nil` to
  unset) followed by every credential it does not name, mapped to `nil`.
  """
  @spec cmd_env([{String.t(), String.t() | nil}]) :: [{String.t(), String.t() | nil}]
  def cmd_env(env \\ []) do
    unset = for name <- unset_names(), not List.keymember?(env, name, 0), do: {name, nil}
    env ++ unset
  end
end
