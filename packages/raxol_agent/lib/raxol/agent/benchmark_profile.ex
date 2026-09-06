defmodule Raxol.Agent.BenchmarkProfile do
  @moduledoc """
  The env-driven contract `raxol.p` honors when a benchmark harness (or any
  unattended caller) drives it. All configuration arrives as environment
  variables so the adapter side needs no flags:

    * `RAXOL_MODEL`        — `provider/model` (e.g. `anthropic/claude-sonnet-4-6`);
      the provider segment must be a supported backend
    * `RAXOL_PROFILE`      — `benchmark` activates profile semantics
    * `RAXOL_MAX_TURNS`    — hard turn cap per run; exceeding it exits 2
    * `RAXOL_MAX_COST_USD` — hard spend cap per run; requires
      `RAXOL_COST_PER_MTOK_IN` and `RAXOL_COST_PER_MTOK_OUT` (USD per million
      tokens) so cost can actually be computed from usage — a cap that cannot
      be enforced is refused at boot rather than silently ignored
    * `RAXOL_TRAJECTORY_PATH` — where the trajectory JSON is written on every
      exit path (success, error, timeout, budget, SIGTERM)

  `RAXOL_PROFILE=benchmark` forces, for the run:

    * allow-all tool authorizer + the mutating coding tools (there is no
      human to ask; the task container is the blast radius)
    * skills/self-improvement OFF — task attempts must be independent
    * trajectory capture ON when a path is set

  CLI flags win over env: the human channel outranks the harness channel.
  """

  defstruct active?: false,
            backend: nil,
            model: nil,
            max_turns: nil,
            max_cost_usd: nil,
            cost_per_mtok_in: nil,
            cost_per_mtok_out: nil,
            trajectory_path: nil

  @type t :: %__MODULE__{
          active?: boolean(),
          backend: atom() | nil,
          model: String.t() | nil,
          max_turns: pos_integer() | nil,
          max_cost_usd: float() | nil,
          cost_per_mtok_in: float() | nil,
          cost_per_mtok_out: float() | nil,
          trajectory_path: String.t() | nil
        }

  # The largest integer a float carries exactly. A usage figure arrives from
  # a provider's JSON, a CLI's stdout or an ACP peer's frame, all of which can
  # spell any integer at all, and Jason decodes a 400-digit literal into a
  # bignum that `/ 1_000_000` cannot convert (ArithmeticError). No provider
  # bills nine quadrillion tokens in one call, so past this a figure is
  # garbage and reads as absent, the same tolerant rule that already applies
  # to a negative count. Shared by every usage reader through `is_count/1`.
  @max_count 9_007_199_254_740_992

  @doc "The largest usage figure any reader accepts; see `is_count/1`."
  @spec max_count() :: pos_integer()
  def max_count, do: @max_count

  @doc """
  Whether `n` is a usable token count: a non-negative integer no larger than
  `max_count/0`. Every reader of a provider-raw usage map guards with this so
  a garbage figure is absent everywhere rather than a crash somewhere.
  """
  defguard is_count(n) when is_integer(n) and n >= 0 and n <= @max_count

  @doc """
  Build a profile from an env map (defaults to `System.get_env/0`).

  Returns `{:error, message}` on any unparseable or unenforceable value —
  a benchmark run with a misread cap must fail loudly at boot, not run
  uncapped.
  """
  @spec from_env(%{optional(String.t()) => String.t()}) ::
          {:ok, t()} | {:error, String.t()}
  def from_env(env \\ System.get_env()) do
    with {:ok, backend, model} <- parse_model(env["RAXOL_MODEL"]),
         {:ok, max_turns} <- parse_pos_int(env, "RAXOL_MAX_TURNS"),
         {:ok, max_cost} <- parse_pos_float(env, "RAXOL_MAX_COST_USD"),
         {:ok, rate_in} <- parse_pos_float(env, "RAXOL_COST_PER_MTOK_IN"),
         {:ok, rate_out} <- parse_pos_float(env, "RAXOL_COST_PER_MTOK_OUT"),
         :ok <- check_cost_enforceable(max_cost, rate_in, rate_out) do
      {:ok,
       %__MODULE__{
         active?: env["RAXOL_PROFILE"] == "benchmark",
         backend: backend,
         model: model,
         max_turns: max_turns,
         max_cost_usd: max_cost,
         cost_per_mtok_in: rate_in,
         cost_per_mtok_out: rate_out,
         trajectory_path: blank_to_nil(env["RAXOL_TRAJECTORY_PATH"])
       }}
    end
  end

  @doc """
  Check accumulated usage against the profile's caps.

  `turns` counts completed turns; `usage` is `%{input_tokens: n,
  output_tokens: n}` accumulated across the run. Returns `:ok` or
  `{:exceeded, reason}` where reason names the cap
  (`:max_turns` / `:max_cost_usd`).
  """
  @spec budget_status(t(), non_neg_integer(), map()) ::
          :ok | {:exceeded, :max_turns | :max_cost_usd}
  def budget_status(%__MODULE__{} = profile, turns, usage) do
    cond do
      profile.max_turns != nil and turns >= profile.max_turns ->
        {:exceeded, :max_turns}

      profile.max_cost_usd != nil and
          cost_usd(profile, usage) > profile.max_cost_usd ->
        {:exceeded, :max_cost_usd}

      true ->
        :ok
    end
  end

  @doc """
  Accumulate one turn's usage map into `%{input_tokens: n, output_tokens: n}`.

  Backends pass provider-raw usage through, so both naming families and
  both key types are accepted: `input_tokens`/`output_tokens`
  (Anthropic-style) and `prompt_tokens`/`completion_tokens`
  (OpenAI-style), atoms or strings.
  """
  @spec add_usage(map(), map()) :: %{
          input_tokens: non_neg_integer(),
          output_tokens: non_neg_integer()
        }
  def add_usage(acc, usage) when is_map(usage) do
    %{
      input_tokens:
        Map.get(acc, :input_tokens, 0) +
          read_tokens(usage, [:input_tokens, :prompt_tokens]),
      output_tokens:
        Map.get(acc, :output_tokens, 0) +
          read_tokens(usage, [:output_tokens, :completion_tokens])
    }
  end

  def add_usage(acc, _usage), do: acc

  defp read_tokens(usage, keys) do
    Enum.find_value(keys, 0, fn key ->
      case Map.get(usage, key) || Map.get(usage, Atom.to_string(key)) do
        n when is_count(n) -> n
        _ -> nil
      end
    end)
  end

  @doc "Compute run cost in USD from accumulated usage, 0.0 without rates."
  @spec cost_usd(t(), map()) :: float()
  def cost_usd(%__MODULE__{cost_per_mtok_in: nil}, _usage), do: 0.0
  def cost_usd(%__MODULE__{cost_per_mtok_out: nil}, _usage), do: 0.0

  def cost_usd(%__MODULE__{} = profile, usage) do
    input = Map.get(usage, :input_tokens, 0)
    output = Map.get(usage, :output_tokens, 0)

    input / 1_000_000 * profile.cost_per_mtok_in +
      output / 1_000_000 * profile.cost_per_mtok_out
  end

  # -- Parsing ---------------------------------------------------------------

  defp parse_model(nil), do: {:ok, nil, nil}
  defp parse_model(""), do: {:ok, nil, nil}

  defp parse_model(value) do
    case String.split(value, "/", parts: 2) do
      [provider, model] when provider != "" and model != "" ->
        resolve_backend(provider, model)

      _ ->
        {:error, "RAXOL_MODEL must be provider/model (got #{inspect(value)})"}
    end
  end

  defp resolve_backend(provider, model) do
    supported = Raxol.Agent.Backend.Selector.supported_backends()

    case Enum.find(supported, &(Atom.to_string(&1) == provider)) do
      nil ->
        list = Enum.map_join(supported, ", ", &Atom.to_string/1)

        {:error, "RAXOL_MODEL provider #{inspect(provider)} unknown; supported: #{list}"}

      backend ->
        {:ok, backend, model}
    end
  end

  defp parse_pos_int(env, key) do
    case blank_to_nil(env[key]) do
      nil ->
        {:ok, nil}

      raw ->
        case Integer.parse(raw) do
          {n, ""} when n > 0 -> {:ok, n}
          _ -> {:error, "#{key} must be a positive integer (got #{inspect(raw)})"}
        end
    end
  end

  defp parse_pos_float(env, key) do
    case blank_to_nil(env[key]) do
      nil ->
        {:ok, nil}

      raw ->
        case Float.parse(raw) do
          {f, ""} when f > 0 -> {:ok, f}
          _ -> {:error, "#{key} must be a positive number (got #{inspect(raw)})"}
        end
    end
  end

  defp check_cost_enforceable(nil, _in, _out), do: :ok

  defp check_cost_enforceable(_cost, rate_in, rate_out)
       when rate_in != nil and rate_out != nil,
       do: :ok

  defp check_cost_enforceable(_cost, _in, _out) do
    {:error,
     "RAXOL_MAX_COST_USD requires RAXOL_COST_PER_MTOK_IN and " <>
       "RAXOL_COST_PER_MTOK_OUT so the cap can be enforced from token usage"}
  end

  defp blank_to_nil(nil), do: nil
  defp blank_to_nil(""), do: nil
  defp blank_to_nil(value), do: value
end
