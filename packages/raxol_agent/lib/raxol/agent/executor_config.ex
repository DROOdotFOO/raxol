defmodule Raxol.Agent.ExecutorConfig do
  @moduledoc """
  Explicit `{backend, model, auth}` configuration for an agent executor.

  This is the front door for selecting where an agent's turns run. A `backend`
  names the runtime/vendor (`:anthropic`, `:openai`, `:lumo`, ...); `model` and
  `auth` say which model behind it and with what credentials. This replaces the
  implicit `base_url` substring detection in `Raxol.Agent.Backend.HTTP` with a
  named, declarative struct.

  Resolve a config to a concrete backend module + options with
  `Raxol.Agent.Backend.Selector.select/1`. The struct itself only knows how to
  flatten itself into the keyword list backends already consume
  (`to_backend_opts/1`).

  `:backend` is the canonical key; `:harness` is accepted as a deprecated alias.

  ## Examples

      iex> Raxol.Agent.ExecutorConfig.new(backend: :anthropic, model: "claude-opus-4-8")
      %Raxol.Agent.ExecutorConfig{backend: :anthropic, model: "claude-opus-4-8", auth: %{}, opts: []}

      iex> cfg = Raxol.Agent.ExecutorConfig.new(backend: :openai, model: "gpt-5", auth: %{api_key: "sk-x"})
      iex> Raxol.Agent.ExecutorConfig.to_backend_opts(cfg)
      [model: "gpt-5", api_key: "sk-x"]
  """

  # Snapshot safety: `auth` holds the API credential, so it is redacted from any
  # durable snapshot while the routing fields persist. Left undeclared this
  # struct would be dropped whole by the codec; declaring the slice makes the
  # secret boundary explicit and keeps a session key out of a checkpoint on
  # disk. See `Raxol.Agent.Snapshot.Persist`.
  @derive {Raxol.Agent.Snapshot.Persist,
           persist: [:backend, :model, :opts], redact: [:auth]}
  @enforce_keys [:backend]
  defstruct backend: nil, model: nil, auth: %{}, opts: []

  @type backend ::
          :anthropic
          | :openai
          | :kimi
          | :ollama
          | :lm_studio
          | :llm7
          | :openrouter
          | :longcat
          | :lumo
          | :mock
          | :claude_native
          | :codex
          | :cursor

  @type t :: %__MODULE__{
          backend: backend(),
          model: String.t() | nil,
          auth: map(),
          opts: keyword()
        }

  @doc """
  Build an `ExecutorConfig` from a keyword list or map.

  Recognized keys: `:backend` (required; `:harness` is a deprecated alias),
  `:model`, `:auth`, `:opts`. The backend value is required and must be an atom.
  If both `:backend` and `:harness` are given, `:backend` wins.
  """
  @spec new(keyword() | map()) :: t()
  def new(attrs) when is_list(attrs), do: new(Map.new(attrs))

  def new(%{backend: backend} = attrs)
      when is_atom(backend) and not is_nil(backend),
      do: build(backend, attrs)

  def new(%{harness: backend} = attrs)
      when is_atom(backend) and not is_nil(backend),
      do: build(backend, attrs)

  defp build(backend, attrs) do
    %__MODULE__{
      backend: backend,
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
