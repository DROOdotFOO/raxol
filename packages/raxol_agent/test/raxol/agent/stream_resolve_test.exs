defmodule Raxol.Agent.StreamResolveTest do
  # Env-based (global) resolution, so not async.
  use ExUnit.Case, async: false

  alias Raxol.Agent.Stream, as: AgentStream

  @managed_env ~w(
    ANTHROPIC_API_KEY OPENAI_API_KEY KIMI_API_KEY MOONSHOT_API_KEY
    OPENROUTER_API_KEY LONGCAT_API_KEY PROTON_ACCESS_TOKEN
    AI_API_KEY AI_BASE_URL AI_MODEL
  )

  setup do
    saved = Map.new(@managed_env, fn key -> {key, System.get_env(key)} end)
    Enum.each(@managed_env, &System.delete_env/1)

    # Point the reference store at a path that does not exist, so a real
    # ~/.raxol/providers.json can never leak into the test.
    empty_store =
      Path.join(
        System.tmp_dir!(),
        "raxol-noproviders-#{System.unique_integer([:positive])}.json"
      )

    prev_store = System.get_env("RAXOL_PROVIDERS")
    System.put_env("RAXOL_PROVIDERS", empty_store)

    on_exit(fn ->
      if prev_store,
        do: System.put_env("RAXOL_PROVIDERS", prev_store),
        else: System.delete_env("RAXOL_PROVIDERS")

      Enum.each(saved, fn
        {key, nil} -> System.delete_env(key)
        {key, value} -> System.put_env(key, value)
      end)
    end)

    :ok
  end

  describe "resolve_executor/1 (auto_provider)" do
    test "returns nil without auto_provider (default behavior is unchanged)" do
      System.put_env("ANTHROPIC_API_KEY", "sk-ant")
      assert AgentStream.resolve_executor([]) == nil
    end

    # Auto-detection refuses providers billed in API credits, so reaching one
    # this way takes the explicit opt-in. Without it a configured key resolves
    # to nothing, which is the point: an unattended turn cannot spend.
    test "auto-detects a provider from an env key once paid use is opted into" do
      System.put_env("RAXOL_ALLOW_PAID_API", "1")
      on_exit(fn -> System.delete_env("RAXOL_ALLOW_PAID_API") end)
      System.put_env("ANTHROPIC_API_KEY", "sk-ant")

      assert %Raxol.Agent.ExecutorConfig{backend: :anthropic} =
               AgentStream.resolve_executor(auto_provider: true)
    end

    test "a configured paid key alone does not auto-resolve" do
      System.put_env("ANTHROPIC_API_KEY", "sk-ant")
      assert AgentStream.resolve_executor(auto_provider: true) == nil
    end

    test "a pinned :provider resolves that provider's credential" do
      System.put_env("OPENAI_API_KEY", "sk-openai")

      assert %Raxol.Agent.ExecutorConfig{backend: :openai} =
               AgentStream.resolve_executor(
                 auto_provider: true,
                 provider: :openai
               )
    end

    test "the generic AI_API_KEY escape hatch resolves once paid use is opted into" do
      System.put_env("RAXOL_ALLOW_PAID_API", "1")
      on_exit(fn -> System.delete_env("RAXOL_ALLOW_PAID_API") end)
      System.put_env("AI_API_KEY", "sk-generic")

      assert %Raxol.Agent.ExecutorConfig{} =
               AgentStream.resolve_executor(auto_provider: true)
    end

    test "returns nil when no credential resolves (falls through to :backend/Mock)" do
      assert AgentStream.resolve_executor(auto_provider: true) == nil
    end
  end
end
