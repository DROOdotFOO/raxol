defmodule Raxol.Agent.Backend.Selector do
  @moduledoc """
  Resolve a `Raxol.Agent.ExecutorConfig` to a concrete backend module + options.

  This is the explicit replacement for `Raxol.Agent.Backend.HTTP`'s implicit
  `base_url` substring detection: a named backend maps to a backend module and a
  set of default options (provider hint, base URL), which are merged with the
  config's own model/auth/opts.

  Native CLI backends (`:claude_native`, `:codex`, `:cursor`) are reserved for
  the future "vendor owns the loop" path and currently resolve to an error.
  """

  alias Raxol.Agent.ExecutorConfig

  # backend => {backend_module, default_opts}
  @backend_table %{
    anthropic: {Raxol.Agent.Backend.HTTP, [provider: :anthropic]},
    openai: {Raxol.Agent.Backend.HTTP, [provider: :openai]},
    kimi: {Raxol.Agent.Backend.HTTP, [provider: :kimi]},
    ollama: {Raxol.Agent.Backend.HTTP, [provider: :ollama]},
    # LM Studio serves an OpenAI-compatible /v1/chat/completions endpoint, so
    # it reuses the :openai request/response/SSE handling in Backend.HTTP.
    # LM Studio ignores auth; "lm-studio" is its documented placeholder key
    # (Backend.HTTP requires an :api_key for the :openai provider).
    lm_studio:
      {Raxol.Agent.Backend.HTTP,
       [
         provider: :openai,
         base_url: "http://localhost:1234",
         api_key: "lm-studio"
       ]},
    llm7: {Raxol.Agent.Backend.HTTP, [provider: :openai, base_url: "https://api.llm7.io"]},
    openrouter:
      {Raxol.Agent.Backend.HTTP,
       [
         provider: :openai,
         # The :openai build_request appends "/v1/chat/completions", so the base
         # URL stops at "/api" (never "/api/v1", which would double the "/v1").
         base_url: "https://openrouter.ai/api",
         extra_headers: [
           {"HTTP-Referer", "https://raxol.io"},
           {"X-OpenRouter-Title", "Raxol"},
           {"X-OpenRouter-Categories", "cli-agent,personal-agent"}
         ]
       ]},
    lumo: {Raxol.Agent.Backend.Lumo, []},
    mock: {Raxol.Agent.Backend.Mock, []},
    # Native backends: the CLI owns its loop; Raxol tools are injected over MCP.
    claude_native: {Raxol.Agent.Backend.ClaudeCode, []},
    cursor: {Raxol.Agent.Backend.Cursor, []}
  }

  # Codex speaks a stateful `app-server` JSON-RPC protocol (not the stream-json
  # NDJSON interface the native backends share); it is served by
  # `Raxol.Symphony.Runners.Codex` rather than an agent backend here.
  @reserved_backends [:codex]

  @doc """
  Resolve an executor config to `{:ok, backend_module, backend_opts}`.

  The returned `backend_opts` are the backend defaults merged with the config's
  flattened `model`/`auth`/`opts` (config values win on conflict). Returns
  `{:error, {:backend_not_implemented, backend}}` for reserved native backends
  and `{:error, {:unknown_backend, backend}}` otherwise.
  """
  @spec select(ExecutorConfig.t()) ::
          {:ok, module(), keyword()} | {:error, term()}
  def select(%ExecutorConfig{backend: backend} = config) do
    case Map.fetch(@backend_table, backend) do
      {:ok, {module, defaults}} ->
        opts = Keyword.merge(defaults, ExecutorConfig.to_backend_opts(config))
        {:ok, module, opts}

      :error ->
        {:error, reason_for(backend)}
    end
  end

  @doc "List the backend atoms this selector can resolve to a backend module."
  @spec supported_backends() :: [ExecutorConfig.backend()]
  def supported_backends, do: Map.keys(@backend_table)

  @doc false
  @deprecated "Use supported_backends/0"
  @spec supported_harnesses() :: [ExecutorConfig.backend()]
  def supported_harnesses, do: supported_backends()

  defp reason_for(backend) when backend in @reserved_backends,
    do: {:backend_not_implemented, backend}

  defp reason_for(backend), do: {:unknown_backend, backend}
end
