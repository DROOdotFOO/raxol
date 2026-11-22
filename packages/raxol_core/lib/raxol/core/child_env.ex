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
        * a `_`-separated segment, anywhere in the name, of `KEY`, `KEYS`,
          `APIKEY`, `APIKEYS`, `PRIVKEY`, `TOKEN`, `TOKENS`, `SECRET`,
          `SECRETS`, `PASSWORD`, `PASSWD`, `PASS`, `PASSPHRASE`, `MNEMONIC`,
          `SEEDPHRASE`, `DSN`, `CREDENTIAL` or `CREDENTIALS`, or of the
          two-word `SEED_PHRASE`, `WALLET_SEED`, `MASTER_SEED`, `HD_SEED` or
          `TOTP_SEED`; a segment may end in a digit (so
          `ANTHROPIC_API_KEY`, `OPENAI_API_KEY_2`, `GH_TOKEN`,
          `AWS_ACCESS_KEY_ID`, `SECRET_KEY_BASE`, `OPENAI_APIKEY`, `SMTP_PASS`,
          `DB_PASS1`, `WALLET_SEED_PHRASE`, `SENTRY_DSN`, a bare `TOKEN` or
          `SEED_PHRASE`; not `KEYBOARD`, `TOKENIZERS_PARALLELISM`,
          `SSH_ASKPASS`, a random-number `SEED` or `RANDOM_SEED`, or the
          shell's `PWD`). A `PASS` or `DSN` segment also catches names that
          hold no secret, such as `PASS_THROUGH`, `FIRST_PASS` or an ODBC
          `ODBC_DSN` naming a data source; give such a variable back through
          `pass:` or the spawn's `env`;
        * a password-manager session token: 1Password's `OP_SESSION_<account>`
          (at the start of the name), Bitwarden's `BW_SESSION` and LastPass's
          `LPASS_SESSION`, which unlock the operator's vault;
        * a database or broker URL, which carries its password:
          `DATABASE_URL` (also `DATABASE_URL_UNPOOLED`, `REPO_DATABASE_URL`),
          and the same for `POSTGRES`, `POSTGRESQL`, `MYSQL`, `REDIS`,
          `MONGO`, `MONGODB`, `AMQP` and `RABBITMQ`, as `_URL` or `_URI`;
        * `PGPASSWORD` and any other `PG...PASSWORD` (`PGADMIN_PASSWORD`,
          `MY_PGPASSWORD`);
        * `RPC` anywhere in the name (`ETH_RPC`, `BASE_RPC_URL`, `RPC_BASE`,
          `MAINNETRPC`), since a provider RPC URL embeds its API key -- except
          as part of `GRPC`, whose variables are gRPC library settings (so
          `JSONRPC_PORT` goes too);
    * the names in `secrets/0`, matched case-insensitively: raxol's own
      variables, the web endpoint's
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
  The config must be a keyword list with no keys but `:pass` and
  `:extra_secrets`, each at most once, both lists of variable names (strings
  matching `[A-Za-z_][A-Za-z0-9_]*`); anything else, a misspelt key
  included, raises an `ArgumentError` naming the key at the next spawn,
  instead of scrubbing less than the operator meant. The error shows the
  offending value's type and size, never its contents:

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
  (`ALCHEMY_URL`), `MYSQL_PWD`, `GITHUB_PAT`. A name that is not valid
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

  # Credential words as whole `_`-separated segments anywhere in the name
  # (`OPENAI_API_KEY`, `ANTHROPIC_API_KEY_2`, `AWS_ACCESS_KEY_ID`, `API_KEYS`,
  # `GH_TOKEN`, `SECRET_KEY_BASE`, `SMTP_PASS`, `SENTRY_DSN`), a 1Password CLI
  # session, a database or broker URL, a `PG...PASSWORD`, or `RPC` anywhere
  # but in `GRPC`; case-insensitive. A superset of the suffix-only pattern
  # raxol-agent's `Raxol.AgentClientProtocol.Transport.Stdio` keeps, and,
  # since 2.9.1, of the `_PASS` / `_SEED_PHRASE` / `_DSN` / `SEED_PHRASE` /
  # `OP_SESSION_` gaps `Raxol.Agent.ChildEnv` added on top of 2.9.0; it can
  # drop those once it requires raxol_core ~> 2.9.1. `PWD`, the shell's
  # working directory, is no segment here on purpose, and `PASS` is a whole
  # segment, so `SSH_ASKPASS` (a program path) is not matched. A bare `SEED`
  # is a random-number seed far more often than a wallet's, so only the
  # wallet shapes are listed. A segment may end in a digit (`DB_PASS1`).
  @credential ~r/
    (\A|_)(APIKEYS?|KEYS?|PRIVKEY|TOKENS?|SECRETS?|PASSWORD|PASSWD|PASS|PASSPHRASE|MNEMONIC|SEEDPHRASE|SEED_PHRASE|(WALLET|MASTER|HD|TOTP)_SEED|DSN|CREDENTIALS?)(_|\d|\z)
    | \AOP_SESSION_
    | (\A|_)(BW|LPASS)_SESSION(_|\z)
    | (\A|_)(DATABASE|POSTGRES|POSTGRESQL|MYSQL|REDIS|MONGO|MONGODB|AMQP|RABBITMQ)_UR[LI]
    | (\A|_)PG\w*PASSWORD
    | (?<!G)RPC
  /xi

  @doc """
  The credential-name pattern (case-insensitive). A package that keeps its
  own copy, because it cannot depend on `raxol_core` at runtime, can check
  that copy against this one in a test.
  """
  @spec credential_pattern() :: Regex.t()
  def credential_pattern, do: @credential

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
  def secret?(name) when is_binary(name), do: denied?(config!(), name)

  # The named set is matched case-insensitively too, so `ssh_auth_sock` is
  # denied like `SSH_AUTH_SOCK`; `pass:` stays exact.
  @spec denied?(config(), String.t()) :: boolean()
  defp denied?(%{pass: pass} = config, name) do
    name not in pass and
      (String.upcase(name) in Enum.map(named(config), &String.upcase/1) or
         Regex.match?(@credential, name))
  end

  @spec named(config()) :: [String.t()]
  defp named(%{pass: pass, extra_secrets: extra}) do
    (@secrets ++ extra)
    |> Enum.uniq()
    |> Enum.reject(&(&1 in pass))
  end

  # Every name a child must not inherit: the named set (`pass:` already out),
  # set or not, plus each of the `present` names (the node's variables) that
  # is denied.
  @spec unset_names(config(), [String.t()]) :: [String.t()]
  defp unset_names(config, present) do
    Enum.uniq(named(config) ++ Enum.filter(present, &denied?(config, &1)))
  end

  @spec unset_names() :: [String.t()]
  defp unset_names, do: unset_names(config!(), System.get_env() |> Map.keys())

  @keys [:pass, :extra_secrets]

  # The whole config, validated, so every entry point raises on any bad
  # value, an unknown key (a misspelt `extra_secret:` would scrub less) or a
  # repeated one (only the first would be read).
  @spec config!() :: config()
  defp config! do
    config = Application.get_env(:raxol_core, __MODULE__, [])

    cond do
      not (is_list(config) and Keyword.keyword?(config)) ->
        invalid!("must be a keyword list", shape(config))

      (stray = Keyword.keys(config) -- @keys) != [] ->
        invalid!("unknown or repeated keys (expected #{inspect(@keys)}, once each)", stray)

      true ->
        %{pass: names!(config, :pass), extra_secrets: names!(config, :extra_secrets)}
    end
  end

  @spec names!(keyword(), :pass | :extra_secrets) :: [String.t()]
  defp names!(config, key) do
    case Keyword.get(config, key, []) do
      names when is_list(names) ->
        Enum.each(names, &name!(&1, key))
        names

      names ->
        invalid!("#{inspect(key)} must be a list of variable names", shape(names))
    end
  end

  @spec name!(term(), :pass | :extra_secrets) :: :ok
  defp name!(name, key) do
    if is_binary(name) and name =~ ~r/\A[A-Za-z_][A-Za-z0-9_]*\z/,
      do: :ok,
      else: invalid!("#{inspect(key)} must be a list of variable names", shape(name))
  end

  # What an error shows of the operator's input: its type and size, never its
  # contents, which may be the key itself pasted where its name belongs. An
  # error here can reach a log or a model (an MCP spawn returns it).
  @spec shape(term()) :: term()
  defp shape(term) when is_binary(term), do: {:string, byte_size(term), :bytes}
  defp shape(term) when is_list(term), do: {:list, length(term), :items}
  defp shape(term) when is_map(term), do: {:map, map_size(term), :entries}
  defp shape(term) when is_tuple(term), do: {:tuple, tuple_size(term), :elements}
  defp shape(term) when is_atom(term) or is_number(term), do: term
  defp shape(_term), do: :other

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
