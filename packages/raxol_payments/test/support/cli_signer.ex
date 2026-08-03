defmodule Raxol.Payments.Test.CliSigner do
  @moduledoc """
  Spawn the `riddler-client` CLI as a black-box signing oracle.

  The CLI emits a single `RESULT_JSON: { ... }` line on stdout for the
  sign-only and ACP buyer-auth subcommands; this module spawns the CLI
  via `System.cmd/3`, sets `PRIVATE_KEY` (and any other env vars the
  caller passes), and parses the last `RESULT_JSON:` line into a map.

  Used by raxol_payments conformance and integration tests, and by
  raxol_earn end-to-end tests that exercise the buyer-side authorization
  path.

  ## Resolving the CLI repo

  Lookup order:

  1. `opts[:cwd]`
  2. `System.get_env("RIDDLER_CLI_DIR")`
  3. Sibling-directory fallback assuming `riddler-client` is
     checked out beside this monorepo's parent.

  If neither `cwd` nor `RIDDLER_CLI_DIR` is set and the sibling fallback
  doesn't exist, every call raises `Raxol.Payments.Test.CliSigner.CliNotFoundError`.

  ## Example

      iex> {:ok, %{result_json: result}} =
      ...>   Raxol.Payments.Test.CliSigner.acp_buyer_auth(
      ...>     [
      ...>       job_id: "12345",
      ...>       buyer: "0x7E5F4552091A69125d5DfCb7b8C2659029395Bdf",
      ...>       seller: "0xc6E555dfcC47e4A3bfecd6879570044ADc0270ff",
      ...>       amount: "1000000",
      ...>       chain: "base",
      ...>       token: "usdc",
      ...>       auth_type: "erc3009",
      ...>       deadline: "1900000000"
      ...>     ],
      ...>     private_key: "0x0000...0001"
      ...>   )
      iex> result["auth_type"]
      "erc3009"
  """

  defmodule CliNotFoundError do
    defexception [:message]
  end

  @result_json_regex ~r/^RESULT_JSON:\s*(\{.*\})\s*$/m

  # Path (relative to the riddler-client repo root) of the CLI entry point.
  @cli_entry "packages/sdk-taker/src/cli.ts"

  @type flag :: {atom() | String.t(), String.t() | integer() | boolean()}
  @type opts :: [
          private_key: String.t(),
          env: %{optional(String.t()) => String.t()} | [{String.t(), String.t()}],
          cwd: Path.t(),
          timeout_ms: pos_integer()
        ]
  @type result :: %{
          stdout: String.t(),
          result_json: map() | nil,
          exit_code: non_neg_integer()
        }

  @doc """
  Run an arbitrary CLI subcommand.

  `flags` is a list of `{name, value}` tuples. Atom names are converted to
  `--snake_case`. Boolean `true` values become a bare flag; `false` is
  dropped. Other values are stringified.

  Returns `{:ok, %{stdout, result_json, exit_code}}` on exit 0, or
  `{:error, {:cli_failed, exit_code, stdout}}` on any non-zero exit.
  """
  @spec run(String.t(), [flag()], opts()) ::
          {:ok, result()} | {:error, {:cli_failed, integer(), String.t()}}
  def run(subcommand, flags, opts \\ []) do
    cwd = resolve_cwd(opts)
    # riddler-client is now a monorepo; the CLI lives in the riddler-sdk package
    # and is TypeScript, so it is run from source via tsx (no build step needed).
    args = ["tsx", @cli_entry, subcommand | encode_flags(flags)]
    env = build_env(opts)

    {stdout, exit_code} = System.cmd("npx", args, cd: cwd, env: env, stderr_to_stdout: true)

    case exit_code do
      0 ->
        {:ok,
         %{
           stdout: stdout,
           result_json: parse_result_json(stdout),
           exit_code: 0
         }}

      _ ->
        {:error, {:cli_failed, exit_code, stdout}}
    end
  end

  @doc "Convenience wrapper for `acp-buyer-auth`."
  @spec acp_buyer_auth([flag()], opts()) ::
          {:ok, result()} | {:error, term()}
  def acp_buyer_auth(flags, opts \\ []) do
    run("acp-buyer-auth", flags, opts)
  end

  @doc "Convenience wrapper for `sign-erc3009`."
  @spec sign_erc3009(quote_json :: map(), chain :: String.t(), opts()) ::
          {:ok, result()} | {:error, term()}
  def sign_erc3009(quote_json, chain, opts \\ []) do
    run("sign-erc3009", [chain: chain, quote: Jason.encode!(quote_json)], opts)
  end

  @doc "Convenience wrapper for `sign-permit2`."
  @spec sign_permit2(quote_json :: map(), chain :: String.t(), opts()) ::
          {:ok, result()} | {:error, term()}
  def sign_permit2(quote_json, chain, opts \\ []) do
    run("sign-permit2", [chain: chain, quote: Jason.encode!(quote_json)], opts)
  end

  @doc "Convenience wrapper for `xochi-flow`."
  @spec xochi_flow([flag()], opts()) :: {:ok, result()} | {:error, term()}
  def xochi_flow(flags, opts \\ []) do
    run("xochi-flow", flags, opts)
  end

  # -- Internals --

  defp resolve_cwd(opts) do
    cwd =
      opts[:cwd] ||
        System.get_env("RIDDLER_CLI_DIR") ||
        sibling_default()

    if cwd && File.dir?(cwd) && File.exists?(Path.join([cwd | Path.split(@cli_entry)])) do
      cwd
    else
      raise CliNotFoundError,
        message:
          "Could not locate riddler-client CLI. Set RIDDLER_CLI_DIR or pass cwd: ... " <>
            "(tried #{inspect(cwd)})"
    end
  end

  # Best-effort fallback: ../../riddler-client relative to the
  # raxol monorepo root. Works for the common dev layout where both repos
  # live side-by-side under ~/CODE/.
  defp sibling_default do
    Path.expand("../../../../riddler-client", __DIR__)
  end

  defp encode_flags(flags) do
    Enum.flat_map(flags, fn
      {_name, false} ->
        []

      {name, true} ->
        ["--#{normalize_flag_name(name)}"]

      {name, value} ->
        ["--#{normalize_flag_name(name)}", to_string(value)]
    end)
  end

  defp normalize_flag_name(name) when is_atom(name), do: Atom.to_string(name)
  defp normalize_flag_name(name) when is_binary(name), do: name

  defp build_env(opts) do
    base = System.get_env() |> Enum.to_list()

    user_env =
      case opts[:env] do
        nil -> []
        env when is_map(env) -> Map.to_list(env)
        env when is_list(env) -> env
      end

    extra =
      if opts[:private_key],
        do: [{"PRIVATE_KEY", opts[:private_key]} | user_env],
        else: user_env

    # System.cmd takes a list of {key, value}; later entries override earlier ones.
    base ++ extra
  end

  defp parse_result_json(stdout) do
    Regex.scan(@result_json_regex, stdout)
    |> List.last()
    |> case do
      nil -> nil
      [_, json] -> Jason.decode!(json)
    end
  end
end
