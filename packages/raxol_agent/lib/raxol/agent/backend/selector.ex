defmodule Raxol.Agent.Backend.Selector do
  @moduledoc """
  Resolve a `Raxol.Agent.ExecutorConfig` to a concrete backend module + options.

  This is the explicit replacement for `Raxol.Agent.Backend.HTTP`'s implicit
  `base_url` substring detection: a named harness maps to a backend module and a
  set of default options (provider hint, base URL), which are merged with the
  config's own model/auth/opts.

  Native CLI harnesses (`:claude_native`, `:codex`, `:cursor`) are reserved for
  the future "vendor owns the loop" path and currently resolve to an error.
  """

  alias Raxol.Agent.ExecutorConfig

  # harness => {backend_module, default_opts}
  @harness_table %{
    anthropic: {Raxol.Agent.Backend.HTTP, [provider: :anthropic]},
    openai: {Raxol.Agent.Backend.HTTP, [provider: :openai]},
    kimi: {Raxol.Agent.Backend.HTTP, [provider: :kimi]},
    ollama: {Raxol.Agent.Backend.HTTP, [provider: :ollama]},
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
    # Native harnesses: the CLI owns its loop; Raxol tools are injected over MCP.
    claude_native: {Raxol.Agent.Backend.ClaudeCode, []},
    cursor: {Raxol.Agent.Backend.Cursor, []}
  }

  # Codex speaks a stateful `app-server` JSON-RPC protocol (not the stream-json
  # NDJSON interface the native backends share); it is served by
  # `Raxol.Symphony.Runners.Codex` rather than an agent backend here.
  @reserved_harnesses [:codex]

  @doc """
  Resolve an executor config to `{:ok, backend_module, backend_opts}`.

  The returned `backend_opts` are the harness defaults merged with the config's
  flattened `model`/`auth`/`opts` (config values win on conflict). Returns
  `{:error, {:harness_not_implemented, harness}}` for reserved native harnesses
  and `{:error, {:unknown_harness, harness}}` otherwise.
  """
  @spec select(ExecutorConfig.t()) ::
          {:ok, module(), keyword()} | {:error, term()}
  def select(%ExecutorConfig{harness: harness} = config) do
    case Map.fetch(@harness_table, harness) do
      {:ok, {backend, defaults}} ->
        opts = Keyword.merge(defaults, ExecutorConfig.to_backend_opts(config))
        {:ok, backend, opts}

      :error ->
        {:error, reason_for(harness)}
    end
  end

  @doc "List the harness atoms this selector can resolve to a backend."
  @spec supported_harnesses() :: [ExecutorConfig.harness()]
  def supported_harnesses, do: Map.keys(@harness_table)

  defp reason_for(harness) when harness in @reserved_harnesses,
    do: {:harness_not_implemented, harness}

  defp reason_for(harness), do: {:unknown_harness, harness}
end
