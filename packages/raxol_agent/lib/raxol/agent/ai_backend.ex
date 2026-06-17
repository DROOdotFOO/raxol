defmodule Raxol.Agent.AIBackend do
  @moduledoc """
  Behaviour for pluggable AI model integration.

  Agents are backend-agnostic -- they call `complete/2` or `stream/2`
  and the backend handles the model-specific HTTP/inference details.

  Implementations:
  - `Raxol.Agent.Backend.HTTP` -- Req-based client for Claude, GPT, Ollama, Kimi
  - `Raxol.Agent.Backend.Lumo` -- Proton Lumo with U2L encryption (or lumo-tamer proxy)
  - `Raxol.Agent.Backend.Mock` -- Deterministic responses for testing
  """

  @type message :: %{role: :system | :user | :assistant, content: String.t()}
  @type response :: %{content: String.t(), usage: map(), metadata: map()}
  @type stream_event ::
          {:chunk, String.t()} | {:done, response()} | {:error, term()}

  @doc "Send messages and receive a complete response."
  @callback complete([message()], opts :: keyword()) ::
              {:ok, response()} | {:error, term()}

  @doc "Send messages and receive a stream of events."
  @callback stream([message()], opts :: keyword()) ::
              {:ok, Enumerable.t()} | {:error, term()}

  @doc "Check if the backend is currently available."
  @callback available?() :: boolean()

  @doc "Human-readable name of the backend."
  @callback name() :: String.t()

  @doc "List of supported capabilities."
  @callback capabilities() :: [:completion | :streaming | :tool_use | :vision]

  @doc """
  Whether the backend runs its own internal tool-call loop.

  When `true`, the vendor owns the agent loop (e.g. a wrapped Claude Code or
  Codex CLI) and the framework must NOT drive tool dispatch itself -- it injects
  its tools into the vendor instead. When `false` (the default), the framework's
  ReAct loop drives tool calls. Defaults to `false` for backends that omit it.
  """
  @callback handles_tools_internally?() :: boolean()

  @doc "Maximum context window in tokens, or `nil` when unknown."
  @callback max_context_tokens() :: pos_integer() | nil

  @optional_callbacks [stream: 2, handles_tools_internally?: 0, max_context_tokens: 0]

  @doc """
  Query whether a backend handles tools internally, defaulting to `false`.

  Safe to call on any backend module: backends that do not implement the
  optional callback are treated as framework-driven.
  """
  @spec handles_tools_internally?(module()) :: boolean()
  def handles_tools_internally?(backend) when is_atom(backend) do
    if function_exported?(backend, :handles_tools_internally?, 0) do
      backend.handles_tools_internally?()
    else
      false
    end
  end

  @doc "Query a backend's max context window, defaulting to `nil`."
  @spec max_context_tokens(module()) :: pos_integer() | nil
  def max_context_tokens(backend) when is_atom(backend) do
    if function_exported?(backend, :max_context_tokens, 0) do
      backend.max_context_tokens()
    else
      nil
    end
  end
end
