defmodule Raxol.Agent.Policy.Retry do
  @moduledoc """
  Retry policy: wrap an operation in a bounded-attempt loop with
  configurable backoff and error-matching.

  Three constructors:

  - `exponential/1` -- exponential backoff (`base_ms * 2^(attempt - 1)`,
    capped at `max_ms`)
  - `linear/1` -- fixed `base_ms` between attempts
  - `always/1` -- exponential backoff, retry on any `{:error, _}`

  ## Fields

  - `max_attempts` -- total attempts including the first; must be `>= 1`
  - `base_ms` -- base delay in ms between attempts
  - `max_ms` -- cap on the computed backoff (`base_ms * 2^(attempt - 1)` for
    exponential; ignored for `linear`); default `:infinity`
  - `mode` -- `:exponential | :linear`; affects backoff computation
  - `on` -- error matcher:
    - `:any` -- retry on any `{:error, _}` (the default for `always/1`)
    - list of atoms -- retry on `{:error, atom}` when `atom` is in the list
    - list of `{Module, atom}` tuples -- retry on `{:error, {Module, atom}}`
    - a `(reason -> boolean)` predicate -- arbitrary matching
  """

  @type matcher ::
          :any
          | [atom() | {module(), atom()}]
          | (term() -> boolean())

  @type mode :: :exponential | :linear

  @type t :: %__MODULE__{
          max_attempts: pos_integer(),
          base_ms: non_neg_integer(),
          max_ms: non_neg_integer() | :infinity,
          mode: mode(),
          on: matcher()
        }

  @enforce_keys [:max_attempts, :base_ms]
  defstruct max_attempts: 3,
            base_ms: 200,
            max_ms: :infinity,
            mode: :exponential,
            on: :any

  @doc """
  Construct an exponential-backoff retry policy.

  Required: `:max_attempts`, `:base_ms`. Optional: `:max_ms`, `:on`.
  """
  @spec exponential(keyword()) :: t()
  def exponential(opts) do
    %__MODULE__{
      max_attempts: fetch_pos!(opts, :max_attempts),
      base_ms: fetch_non_neg!(opts, :base_ms),
      max_ms: Keyword.get(opts, :max_ms, :infinity),
      mode: :exponential,
      on: Keyword.get(opts, :on, :any)
    }
  end

  @doc """
  Construct a linear-backoff retry policy. `:base_ms` is the
  delay between attempts (no exponential growth).
  """
  @spec linear(keyword()) :: t()
  def linear(opts) do
    %__MODULE__{
      max_attempts: fetch_pos!(opts, :max_attempts),
      base_ms: fetch_non_neg!(opts, :base_ms),
      max_ms: :infinity,
      mode: :linear,
      on: Keyword.get(opts, :on, :any)
    }
  end

  @doc """
  Construct an "always retry" policy: exponential backoff with
  `:on` set to `:any`.
  """
  @spec always(keyword()) :: t()
  def always(opts) do
    %__MODULE__{
      max_attempts: fetch_pos!(opts, :max_attempts),
      base_ms: fetch_non_neg!(opts, :base_ms),
      max_ms: Keyword.get(opts, :max_ms, :infinity),
      mode: :exponential,
      on: :any
    }
  end

  @doc """
  Backoff in ms before the given attempt (1-indexed: backoff/1 is
  the delay before the second attempt).
  """
  @spec backoff(t(), pos_integer()) :: non_neg_integer()
  def backoff(%__MODULE__{mode: :linear, base_ms: base}, _attempt), do: base

  def backoff(
        %__MODULE__{mode: :exponential, base_ms: base, max_ms: max},
        attempt
      )
      when attempt >= 1 do
    raw = base * Bitwise.bsl(1, attempt - 1)

    case max do
      :infinity -> raw
      n when is_integer(n) -> min(raw, n)
    end
  end

  @doc """
  Check whether `reason` matches the policy's `:on` matcher.
  """
  @spec retriable?(t(), term()) :: boolean()
  def retriable?(%__MODULE__{on: :any}, _reason), do: true

  def retriable?(%__MODULE__{on: list}, reason) when is_list(list),
    do: reason in list

  def retriable?(%__MODULE__{on: fun}, reason) when is_function(fun, 1),
    do: !!fun.(reason)

  defp fetch_pos!(opts, key) do
    case Keyword.fetch!(opts, key) do
      n when is_integer(n) and n >= 1 ->
        n

      other ->
        raise ArgumentError,
              "#{inspect(key)} must be a positive integer, got: #{inspect(other)}"
    end
  end

  defp fetch_non_neg!(opts, key) do
    case Keyword.fetch!(opts, key) do
      n when is_integer(n) and n >= 0 ->
        n

      other ->
        raise ArgumentError,
              "#{inspect(key)} must be a non-negative integer, got: #{inspect(other)}"
    end
  end
end
