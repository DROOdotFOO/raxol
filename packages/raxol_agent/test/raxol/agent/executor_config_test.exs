defmodule Raxol.Agent.ExecutorConfigTest do
  use ExUnit.Case, async: true

  alias Raxol.Agent.ExecutorConfig

  describe "new/1" do
    test "builds from a keyword list" do
      cfg = ExecutorConfig.new(harness: :anthropic, model: "claude-opus-4-8")

      assert %ExecutorConfig{
               backend: :anthropic,
               model: "claude-opus-4-8",
               auth: %{},
               opts: []
             } = cfg
    end

    test "builds from a map" do
      cfg = ExecutorConfig.new(%{harness: :openai, auth: %{api_key: "sk-x"}})

      assert cfg.backend == :openai
      assert cfg.auth == %{api_key: "sk-x"}
    end

    test "defaults model, auth, and opts" do
      cfg = ExecutorConfig.new(harness: :mock)

      assert cfg.model == nil
      assert cfg.auth == %{}
      assert cfg.opts == []
    end

    test "requires a non-nil atom harness" do
      assert_raise FunctionClauseError, fn -> ExecutorConfig.new(model: "x") end

      assert_raise FunctionClauseError, fn ->
        ExecutorConfig.new(harness: nil)
      end
    end
  end

  describe "from_keyword/1" do
    test "is an alias for new/1" do
      assert ExecutorConfig.from_keyword(harness: :mock) ==
               ExecutorConfig.new(harness: :mock)
    end
  end

  describe "to_backend_opts/1" do
    test "includes model when set" do
      cfg = ExecutorConfig.new(harness: :openai, model: "gpt-5")
      assert ExecutorConfig.to_backend_opts(cfg) == [model: "gpt-5"]
    end

    test "omits model when nil" do
      cfg = ExecutorConfig.new(harness: :openai)
      assert ExecutorConfig.to_backend_opts(cfg) == []
    end

    test "flattens auth map into keyword opts" do
      cfg =
        ExecutorConfig.new(
          harness: :openai,
          model: "gpt-5",
          auth: %{api_key: "sk-x"}
        )

      opts = ExecutorConfig.to_backend_opts(cfg)

      assert opts[:model] == "gpt-5"
      assert opts[:api_key] == "sk-x"
    end

    test "explicit opts override auth-derived keys" do
      cfg =
        ExecutorConfig.new(
          harness: :openai,
          auth: %{base_url: "https://from-auth"},
          opts: [base_url: "https://from-opts"]
        )

      assert ExecutorConfig.to_backend_opts(cfg)[:base_url] ==
               "https://from-opts"
    end

    test "ignores non-atom auth keys" do
      cfg =
        ExecutorConfig.new(
          harness: :openai,
          auth: %{"string_key" => "v", api_key: "sk-x"}
        )

      opts = ExecutorConfig.to_backend_opts(cfg)

      assert opts[:api_key] == "sk-x"
      refute Keyword.has_key?(opts, :string_key)
    end
  end

  # Regression guard for the session-key-to-disk leak class: a session-only key
  # lives in `auth` (e.g. `/login openai sk-...` in the coding TUI). If the
  # snapshot codec is ever wired to persist an agent model, `auth` must be
  # redacted, never serialized. Removing the @derive (undeclared -> dropped
  # whole) or moving `:auth` into `persist:` would regress this.
  describe "snapshot redaction" do
    alias Raxol.Agent.Snapshot

    @secret "sk-SECRET-do-not-persist-1234"

    test "dumping the struct redacts auth and keeps the routing fields" do
      cfg =
        ExecutorConfig.new(
          harness: :openai,
          model: "gpt-x",
          auth: %{api_key: @secret}
        )

      {:ok, envelope} = Snapshot.dump(cfg)

      refute Jason.encode!(envelope) =~ @secret
      assert Enum.any?(envelope.redacted, &(&1["path"] == ["auth"]))

      {:ok, restored} = Snapshot.load(envelope)
      assert restored.backend == :openai
      assert restored.model == "gpt-x"
      # The secret comes back at its struct default, never the real value.
      assert restored.auth == %{}
    end

    test "a model embedding an executor never leaks the key into the envelope" do
      model = %{
        input: "hello",
        executor: ExecutorConfig.new(harness: :openai, auth: %{api_key: @secret})
      }

      {:ok, envelope} = Snapshot.dump(model)

      refute Jason.encode!(envelope) =~ @secret
      assert Enum.any?(envelope.redacted, &(&1["path"] == ["executor", "auth"]))
    end
  end
end
