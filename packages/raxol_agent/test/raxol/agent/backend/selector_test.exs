defmodule Raxol.Agent.Backend.SelectorTest do
  use ExUnit.Case, async: true

  alias Raxol.Agent.Backend.Selector
  alias Raxol.Agent.ExecutorConfig

  describe "select/1" do
    test "resolves HTTP-backed harnesses with a provider hint" do
      for {harness, provider} <- [
            anthropic: :anthropic,
            openai: :openai,
            kimi: :kimi,
            ollama: :ollama
          ] do
        cfg = ExecutorConfig.new(harness: harness)
        assert {:ok, Raxol.Agent.Backend.HTTP, opts} = Selector.select(cfg)
        assert opts[:provider] == provider
      end
    end

    test "resolves lm_studio to the HTTP backend with a base_url default" do
      cfg = ExecutorConfig.new(harness: :lm_studio)
      assert {:ok, Raxol.Agent.Backend.HTTP, opts} = Selector.select(cfg)
      assert opts[:provider] == :openai
      assert opts[:base_url] == "http://localhost:1234"
    end

    test "resolves llm7 to the HTTP backend with a base_url default" do
      cfg = ExecutorConfig.new(harness: :llm7)
      assert {:ok, Raxol.Agent.Backend.HTTP, opts} = Selector.select(cfg)
      assert opts[:provider] == :openai
      assert opts[:base_url] == "https://api.llm7.io"
    end

    test "resolves longcat to the HTTP backend with a base_url and model default" do
      cfg = ExecutorConfig.new(harness: :longcat)
      assert {:ok, Raxol.Agent.Backend.HTTP, opts} = Selector.select(cfg)
      assert opts[:provider] == :openai

      # Base URL stops at "/openai"; build_request appends "/v1/chat/completions".
      assert opts[:base_url] == "https://api.longcat.chat/openai"
      assert opts[:model] == "LongCat-2.0"
    end

    test "resolves deepseek to the HTTP backend with a base_url and model default" do
      cfg = ExecutorConfig.new(harness: :deepseek)
      assert {:ok, Raxol.Agent.Backend.HTTP, opts} = Selector.select(cfg)
      assert opts[:provider] == :openai
      assert opts[:base_url] == "https://api.deepseek.com"
      assert opts[:model] == "deepseek-v4-flash"

      # The backend-scoped price table is keyed to this id (ADR-0035), so
      # registering it is what makes the cache-tier pricing reachable.
      assert {:ok, _cost, :scoped_table} =
               Raxol.Agent.LlmPrices.turn_cost(:deepseek, "deepseek-v4-flash", %{
                 prompt_cache_hit_tokens: 1,
                 prompt_cache_miss_tokens: 1
               })
    end

    test "resolves openrouter to the HTTP backend with attribution headers" do
      cfg = ExecutorConfig.new(harness: :openrouter)
      assert {:ok, Raxol.Agent.Backend.HTTP, opts} = Selector.select(cfg)
      assert opts[:provider] == :openai
      # Base URL stops at "/api"; build_request appends "/v1/chat/completions".
      assert opts[:base_url] == "https://openrouter.ai/api"

      headers = opts[:extra_headers]
      assert {"HTTP-Referer", "https://raxol.io"} in headers
      assert {"X-OpenRouter-Title", "Raxol"} in headers
      assert {"X-OpenRouter-Categories", "cli-agent,personal-agent"} in headers
    end

    test "config opts override the baked openrouter attribution headers" do
      cfg =
        ExecutorConfig.new(
          harness: :openrouter,
          opts: [extra_headers: [{"HTTP-Referer", "https://example.test"}]]
        )

      assert {:ok, _, opts} = Selector.select(cfg)
      assert opts[:extra_headers] == [{"HTTP-Referer", "https://example.test"}]
    end

    test "resolves lumo and mock to their dedicated backends" do
      assert {:ok, Raxol.Agent.Backend.Lumo, _} =
               Selector.select(ExecutorConfig.new(harness: :lumo))

      assert {:ok, Raxol.Agent.Backend.Mock, _} =
               Selector.select(ExecutorConfig.new(harness: :mock))
    end

    test "merges config model and auth over harness defaults" do
      cfg =
        ExecutorConfig.new(
          harness: :anthropic,
          model: "claude-opus-4-8",
          auth: %{api_key: "sk-x"}
        )

      assert {:ok, Raxol.Agent.Backend.HTTP, opts} = Selector.select(cfg)

      assert opts[:provider] == :anthropic
      assert opts[:model] == "claude-opus-4-8"
      assert opts[:api_key] == "sk-x"
    end

    test "config opts override harness defaults" do
      cfg =
        ExecutorConfig.new(harness: :llm7, opts: [base_url: "https://override"])

      assert {:ok, _, opts} = Selector.select(cfg)
      assert opts[:base_url] == "https://override"
    end

    test "resolves native CLI harnesses to their backends" do
      assert {:ok, Raxol.Agent.Backend.ClaudeCode, _} =
               Selector.select(ExecutorConfig.new(harness: :claude_native))

      assert {:ok, Raxol.Agent.Backend.Cursor, _} =
               Selector.select(ExecutorConfig.new(harness: :cursor))
    end

    test "codex is reserved (served by the symphony app-server runner)" do
      cfg = ExecutorConfig.new(harness: :codex)
      assert {:error, {:backend_not_implemented, :codex}} = Selector.select(cfg)
    end

    test "unknown backend returns an error" do
      cfg = ExecutorConfig.new(harness: :nonsense)
      assert {:error, {:unknown_backend, :nonsense}} = Selector.select(cfg)
    end
  end

  describe "supported_backends/0" do
    test "lists the resolvable backends" do
      supported = Selector.supported_backends()
      assert :anthropic in supported
      assert :mock in supported
      refute :codex in supported
    end
  end

  describe "credential validation routing" do
    # A harness whose `:provider` is not a dialect Backend.HTTP recognizes gets
    # NO auth check at all: `check_auth/1` returns :unsupported without a
    # request, and a dead credential reports as merely "stored". That is how
    # openrouter, lm_studio, llm7 and longcat went silently unvalidated -- the
    # caller passed `executor.backend` as `:provider`, which only happens to be
    # a dialect name for the four original providers.
    test "every HTTP-backed harness builds an auth check request" do
      for harness <- Selector.supported_backends() do
        config =
          ExecutorConfig.new(backend: harness, auth: %{api_key: "probe-key"})

        case Selector.select(config) do
          {:ok, Raxol.Agent.Backend.HTTP, opts} ->
            refute Raxol.Agent.Backend.HTTP.auth_check_request(opts) ==
                     :unsupported,
                   "#{harness} resolves to HTTP but has no auth check"

          {:ok, _other_backend, _opts} ->
            :ok
        end
      end
    end

    # OpenRouter serves /api/v1/models publicly (200 with no key), so checking
    # there would call a revoked credential valid -- worse than not checking.
    test "openrouter checks the auth-required endpoint, not the public one" do
      config =
        ExecutorConfig.new(backend: :openrouter, auth: %{api_key: "probe-key"})

      {:ok, _module, opts} = Selector.select(config)

      assert {url, headers} =
               Raxol.Agent.Backend.HTTP.auth_check_request(opts)

      assert url == "https://openrouter.ai/api/v1/key"
      refute url =~ "/models"
      assert {"authorization", "Bearer probe-key"} in headers
    end

    test "an openai-dialect provider still checks the model list by default" do
      config =
        ExecutorConfig.new(backend: :openai, auth: %{api_key: "probe-key"})

      {:ok, _module, opts} = Selector.select(config)

      assert {"https://api.openai.com/v1/models", _headers} =
               Raxol.Agent.Backend.HTTP.auth_check_request(opts)
    end
  end
end
