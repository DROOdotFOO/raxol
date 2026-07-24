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
      cfg = ExecutorConfig.new(harness: :llm7, opts: [base_url: "https://override"])
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
end
