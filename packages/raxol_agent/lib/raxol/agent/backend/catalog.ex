defmodule Raxol.Agent.Backend.Catalog do
  @moduledoc """
  The single declaration of which agent backends exist.

  `Backend.Selector`'s module table, `Backend.Resolver`'s provider list and
  `Raxol.Agent.ExecutorConfig`'s `backend()` union are all projected from the
  entries here, so the three cannot disagree about which backends exist.

  The policy is derive, not merge: this module is the declaration and the three
  consumers each project the slice they need out of it. Nothing here knows about
  credential resolution or request building, which answer different questions
  and keep their own logic.

  ## Entry shape

    * `:id` -- the backend atom, canonical everywhere (`:harness` in the
      resolver is the same value under its deprecated name)
    * `:label` -- human name shown where a backend is listed
    * `:kind` -- `:http` or `:mock`
    * `:module` -- the backend module the selector resolves to
    * `:backend_opts` -- defaults merged under the config's own options
    * `:env_keys` -- API key env vars, checked in order; `[]` means keyless
    * `:model_env` -- env var naming a default model, or `nil`
    * `:billing` -- `:subscription`, `:api_credits`, `:local`, or `:free`.
      Auto-detection routes on this: `:api_credits` draws down a prepaid
      balance and is never selected without an explicit choice
    * `:detectable?` -- whether the backend takes part in the auto-detect walk
      at all, independent of what `:billing` then allows
  """

  @type kind :: :http | :mock
  @type billing :: :subscription | :api_credits | :local | :free

  @type entry :: %{
          id: atom(),
          label: String.t(),
          kind: kind(),
          module: module(),
          backend_opts: keyword(),
          env_keys: [String.t()],
          model_env: String.t() | nil,
          billing: billing(),
          detectable?: boolean()
        }

  # Declaration order IS the auto-detect order for detectable entries, so this
  # list is not alphabetised. Everything billed in API credits sits behind the
  # `RAXOL_ALLOW_PAID_API` gate in the resolver.
  @entries [
    %{
      id: :anthropic,
      label: "Anthropic (Claude)",
      kind: :http,
      module: Raxol.Agent.Backend.HTTP,
      backend_opts: [provider: :anthropic],
      env_keys: ["ANTHROPIC_API_KEY"],
      model_env: "ANTHROPIC_MODEL",
      billing: :api_credits,
      detectable?: true
    },
    %{
      id: :openai,
      label: "OpenAI",
      kind: :http,
      module: Raxol.Agent.Backend.HTTP,
      backend_opts: [provider: :openai],
      env_keys: ["OPENAI_API_KEY"],
      model_env: "OPENAI_MODEL",
      billing: :api_credits,
      detectable?: true
    },
    %{
      id: :kimi,
      label: "Kimi (Moonshot)",
      kind: :http,
      module: Raxol.Agent.Backend.HTTP,
      backend_opts: [provider: :kimi],
      env_keys: ["KIMI_API_KEY", "MOONSHOT_API_KEY"],
      model_env: "KIMI_MODEL",
      billing: :api_credits,
      detectable?: true
    },
    %{
      id: :openrouter,
      label: "OpenRouter",
      kind: :http,
      module: Raxol.Agent.Backend.HTTP,
      backend_opts: [
        provider: :openai,
        # The :openai build_request appends "/v1/chat/completions", so the base
        # URL stops at "/api" (never "/api/v1", which would double the "/v1").
        base_url: "https://openrouter.ai/api",
        # OpenRouter serves /api/v1/models PUBLICLY (200 with no key), so the
        # default auth check would call a revoked credential valid. /v1/key is
        # the auth-required endpoint: 401 with no key and with a bad one.
        auth_check_path: "/v1/key",
        extra_headers: [
          {"HTTP-Referer", "https://raxol.io"},
          {"X-OpenRouter-Title", "Raxol"},
          {"X-OpenRouter-Categories", "cli-agent,personal-agent"}
        ]
      ],
      env_keys: ["OPENROUTER_API_KEY"],
      model_env: "OPENROUTER_MODEL",
      billing: :api_credits,
      detectable?: true
    },
    %{
      id: :longcat,
      label: "LongCat (Meituan)",
      kind: :http,
      module: Raxol.Agent.Backend.HTTP,
      # LongCat (Meituan) is OpenAI-compatible; the base URL stops at "/openai"
      # so build_request appends "/v1/chat/completions". LongCat's
      # message-object SSE frames, reasoning_content channel, and "finishreason"
      # key are already handled by the :openai path in Backend.HTTP.
      backend_opts: [
        provider: :openai,
        base_url: "https://api.longcat.chat/openai",
        model: "LongCat-2.0"
      ],
      env_keys: ["LONGCAT_API_KEY"],
      model_env: "LONGCAT_MODEL",
      billing: :api_credits,
      detectable?: true
    },
    %{
      id: :deepseek,
      label: "DeepSeek",
      kind: :http,
      module: Raxol.Agent.Backend.HTTP,
      # DeepSeek is OpenAI-compatible; build_request appends
      # "/v1/chat/completions" to the base. Its usage carries
      # `prompt_cache_hit_tokens`/`prompt_cache_miss_tokens`, which is what
      # `LlmPrices`' backend-scoped table prices (ADR-0035): the rows are
      # keyed to THIS id, so the same model name served by a reseller or a
      # free host keeps failing closed rather than borrowing the direct rate.
      backend_opts: [
        provider: :openai,
        base_url: "https://api.deepseek.com",
        model: "deepseek-v4-flash"
      ],
      env_keys: ["DEEPSEEK_API_KEY"],
      model_env: "DEEPSEEK_MODEL",
      billing: :api_credits,
      detectable?: true
    },
    %{
      id: :lumo,
      label: "Proton Lumo",
      kind: :http,
      module: Raxol.Agent.Backend.Lumo,
      backend_opts: [],
      env_keys: ["PROTON_ACCESS_TOKEN"],
      model_env: nil,
      billing: :subscription,
      detectable?: true
    },
    %{
      id: :ollama,
      label: "Ollama (local)",
      kind: :http,
      module: Raxol.Agent.Backend.HTTP,
      backend_opts: [provider: :ollama],
      env_keys: [],
      model_env: "OLLAMA_MODEL",
      billing: :local,
      detectable?: true
    },
    %{
      id: :lm_studio,
      label: "LM Studio (local)",
      kind: :http,
      module: Raxol.Agent.Backend.HTTP,
      # LM Studio serves an OpenAI-compatible /v1/chat/completions endpoint, so
      # it reuses the :openai request/response/SSE handling in Backend.HTTP.
      # LM Studio ignores auth; "lm-studio" is its documented placeholder key
      # (Backend.HTTP requires an :api_key for the :openai provider).
      backend_opts: [
        provider: :openai,
        base_url: "http://localhost:1234",
        api_key: "lm-studio"
      ],
      env_keys: [],
      model_env: nil,
      billing: :local,
      detectable?: true
    },
    %{
      id: :llm7,
      label: "LLM7 (free, no key)",
      kind: :http,
      module: Raxol.Agent.Backend.HTTP,
      # LLM7 is keyless, so it carries no `:api_key` -- Backend.HTTP omits the
      # auth header when none is set. Only a SUBSET of its catalogue is free:
      # most ids (gpt-5.4-mini, deepseek-v4-flash, ...) answer 401 "Missing API
      # key" without one, so the default names a model that serves keyless
      # requests. Without it the request inherited the :openai default of
      # "gpt-4o", which LLM7 does not host at all ("model_unavailable").
      backend_opts: [
        provider: :openai,
        base_url: "https://api.llm7.io",
        model: "gpt-oss:20b"
      ],
      env_keys: [],
      model_env: nil,
      billing: :free,
      detectable?: true
    },
    %{
      id: :mock,
      label: "Mock (offline)",
      kind: :mock,
      module: Raxol.Agent.Backend.Mock,
      backend_opts: [],
      env_keys: [],
      model_env: nil,
      billing: :free,
      detectable?: true
    }
  ]

  @ids Enum.map(@entries, & &1.id)

  @doc "Every catalog entry, in declaration order."
  @spec entries() :: [entry()]
  def entries, do: @entries

  @doc "Every backend id, in declaration order."
  @spec ids() :: [atom()]
  def ids, do: @ids

  @doc "Fetch one entry by id."
  @spec fetch(atom()) :: {:ok, entry()} | :error
  def fetch(id) when is_atom(id) do
    case Enum.find(@entries, &(&1.id == id)) do
      nil -> :error
      entry -> {:ok, entry}
    end
  end
end
