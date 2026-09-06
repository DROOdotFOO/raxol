defmodule Raxol.Agent.Backend.Catalog do
  @moduledoc """
  The single declaration of which agent backends exist.

  Three registries used to declare this independently: `Backend.Selector`'s
  module table, `Backend.Resolver`'s provider list, and
  `Raxol.Agent.ExecutorConfig`'s `backend()` union. They drifted, and each drift
  was a live defect rather than untidiness -- `:grok_native` was resolvable and
  selectable while invisible to Dialyzer, and `:cursor` was selectable in code
  while unnameable from `/login`, `--backend` and `.raxol/config.json`. See
  ADR-0034, "Gap 4: five registries disagree about which backends exist".

  The policy is derive, not merge: this module is the declaration and the three
  consumers each project the slice they need out of it. Nothing here knows about
  credential resolution, request building, or Symphony's runner registry, which
  answer different questions and keep their own logic.

  ## Entry shape

    * `:id` -- the backend atom, canonical everywhere (`:harness` in the
      resolver is the same value under its deprecated name)
    * `:label` -- human name for the setup panel and `/login`
    * `:kind` -- `:http`, `:native`, `:mock`, or `:reserved`. `:reserved` names
      a backend the type system accepts and the selector deliberately refuses
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

  @type kind :: :http | :native | :mock | :reserved
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
  # list is not alphabetised. The subscription harnesses come first because they
  # cost nothing extra AND are frontier models; everything billed in API credits
  # sits behind them and behind the `RAXOL_ALLOW_PAID_API` gate in the resolver.
  @entries [
    %{
      id: :claude_native,
      label: "Claude (subscription, via CLI)",
      kind: :native,
      module: Raxol.Agent.Backend.ClaudeCode,
      backend_opts: [],
      env_keys: [],
      model_env: nil,
      billing: :subscription,
      detectable?: true
    },
    %{
      id: :grok_native,
      label: "Grok (subscription, via CLI)",
      kind: :native,
      module: Raxol.Agent.Backend.GrokBuild,
      backend_opts: [],
      env_keys: [],
      model_env: "GROK_MODEL",
      billing: :subscription,
      detectable?: true
    },
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
    },
    # Cursor is declared undetectable rather than left out. Its CLI probe would
    # answer like the other native harnesses and thereby insert it into the
    # auto-detect order, changing which backend an unattended run picks; that is
    # a product decision, not a registry cleanup. Declaring it here is what makes
    # it nameable from `/login`, `--backend cursor` and `.raxol/config.json`,
    # which it was not while the resolver's list was written out by hand.
    %{
      id: :cursor,
      label: "Cursor (subscription, via CLI)",
      kind: :native,
      module: Raxol.Agent.Backend.Cursor,
      backend_opts: [],
      env_keys: [],
      model_env: nil,
      billing: :subscription,
      detectable?: false
    },
    # Codex speaks a stateful `app-server` JSON-RPC protocol (not the
    # stream-json NDJSON interface the native backends share); it is served by
    # `Raxol.Symphony.Runners.Codex` rather than an agent backend here. It stays
    # in the catalog so the type accepts it and the selector can answer
    # `{:error, {:backend_not_implemented, :codex}}` instead of pretending the
    # name is a typo.
    %{
      id: :codex,
      label: "Codex (via Symphony runner)",
      kind: :reserved,
      module: Raxol.Symphony.Runners.Codex,
      backend_opts: [],
      env_keys: [],
      model_env: nil,
      billing: :subscription,
      detectable?: false
    }
  ]

  @ids Enum.map(@entries, & &1.id)

  @doc "Every catalog entry, in declaration order."
  @spec entries() :: [entry()]
  def entries, do: @entries

  @doc "Every backend id, in declaration order."
  @spec ids() :: [atom()]
  def ids, do: @ids

  @doc """
  Entries of one kind, or of any kind in a list, preserving declaration order.
  """
  @spec by_kind(kind() | [kind()]) :: [entry()]
  def by_kind(kind) when is_atom(kind), do: by_kind([kind])

  def by_kind(kinds) when is_list(kinds),
    do: Enum.filter(@entries, &(&1.kind in kinds))

  @doc "Fetch one entry by id."
  @spec fetch(atom()) :: {:ok, entry()} | :error
  def fetch(id) when is_atom(id) do
    case Enum.find(@entries, &(&1.id == id)) do
      nil -> :error
      entry -> {:ok, entry}
    end
  end
end
