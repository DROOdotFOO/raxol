defmodule Raxol.Agent.ExecutorConfig do
  @moduledoc """
  Explicit `{harness, model, auth}` configuration for an agent executor.

  This is the front door for selecting where an agent's turns run. A `harness`
  names the runtime/vendor (`:anthropic`, `:openai`, `:lumo`, ...); `model` and
  `auth` say which model behind it and with what credentials. This replaces the
  implicit `base_url` substring detection in `Raxol.Agent.Backend.HTTP` with a
  named, declarative struct.

  Resolve a config to a concrete backend module + options with
  `Raxol.Agent.Backend.Selector.select/1`. The struct itself only knows how to
  flatten itself into the keyword list backends already consume
  (`to_backend_opts/1`).

  ## Examples

      iex> Raxol.Agent.ExecutorConfig.new(harness: :anthropic, model: "claude-opus-4-8")
      %Raxol.Agent.ExecutorConfig{harness: :anthropic, model: "claude-opus-4-8", auth: %{}, opts: []}

      iex> cfg = Raxol.Agent.ExecutorConfig.new(harness: :openai, model: "gpt-5", auth: %{api_key: "sk-x"})
      iex> Raxol.Agent.ExecutorConfig.to_backend_opts(cfg)
      [model: "gpt-5", api_key: "sk-x"]
  """

  @enforce_keys [:harness]
  defstruct harness: nil, model: nil, auth: %{}, opts: []

  @type harness ::
          :anthropic
          | :openai
          | :kimi
          | :ollama
          | :llm7
          | :lumo
          | :mock
          | :claude_native
          | :codex
          | :cursor

  @type t :: %__MODULE__{
          harness: harness(),
          model: String.t() | nil,
          auth: map(),
          opts: keyword()
        }

  @doc """
  Build an `ExecutorConfig` from a keyword list or map.

  Recognized keys: `:harness` (required), `:model`, `:auth`, `:opts`. The
  `:harness` value is required and must be an atom.
  """
  @spec new(keyword() | map()) :: t()
  def new(attrs) when is_list(attrs), do: new(Map.new(attrs))

  def new(%{harness: harness} = attrs) when is_atom(harness) and not is_nil(harness) do
    %__MODULE__{
      harness: harness,
      model: Map.get(attrs, :model),
      auth: Map.get(attrs, :auth, %{}),
      opts: Map.get(attrs, :opts, [])
    }
  end

  @doc """
  Alias for `new/1` to read naturally when parsing external keyword config.
  """
  @spec from_keyword(keyword()) :: t()
  def from_keyword(kw) when is_list(kw), do: new(kw)

  @doc """
  Flatten this config into the keyword options a backend consumes.

  Order of precedence (later wins): auth fields, then explicit `:opts`, with the
  `:model` placed first so an `:opts`-supplied model can still override it.
  """
  @spec to_backend_opts(t()) :: keyword()
  def to_backend_opts(%__MODULE__{model: model, auth: auth, opts: opts}) do
    []
    |> put_model(model)
    |> Keyword.merge(auth_to_opts(auth))
    |> Keyword.merge(opts)
  end

  defp put_model(kw, nil), do: kw
  defp put_model(kw, model), do: Keyword.put(kw, :model, model)

  defp auth_to_opts(auth) when is_map(auth) do
    auth
    |> Enum.filter(fn {k, _v} -> is_atom(k) end)
    |> Enum.map(fn {k, v} -> {k, v} end)
  end

  defp auth_to_opts(_), do: []
end
