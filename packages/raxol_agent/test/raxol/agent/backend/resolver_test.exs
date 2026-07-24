defmodule Raxol.Agent.Backend.ResolverTest do
  use ExUnit.Case, async: false

  alias Raxol.Agent.Backend.Credentials
  alias Raxol.Agent.Backend.Resolver

  # Every env var the resolver reads. Cleared in setup so a developer's real
  # ANTHROPIC_API_KEY (etc.) can't leak into these assertions.
  @managed_env ~w(
    ANTHROPIC_API_KEY ANTHROPIC_MODEL OPENAI_API_KEY OPENAI_MODEL
    KIMI_API_KEY MOONSHOT_API_KEY KIMI_MODEL OPENROUTER_API_KEY OPENROUTER_MODEL
    LONGCAT_API_KEY LONGCAT_MODEL PROTON_ACCESS_TOKEN OLLAMA_MODEL
    AI_API_KEY AI_BASE_URL AI_MODEL
    RAXOL_ANTHROPIC_OP RAXOL_OPENAI_OP RAXOL_KIMI_OP RAXOL_OPENROUTER_OP
    RAXOL_LONGCAT_OP RAXOL_LUMO_OP RAXOL_OLLAMA_OP RAXOL_LM_STUDIO_OP
    RAXOL_LLM7_OP RAXOL_MOCK_OP
  )

  setup do
    saved = Map.new(@managed_env, fn key -> {key, System.get_env(key)} end)
    Enum.each(@managed_env, &System.delete_env/1)

    store =
      Path.join(
        System.tmp_dir!(),
        "raxol-resolver-#{System.unique_integer([:positive])}.json"
      )

    prev_store = System.get_env("RAXOL_PROVIDERS")
    System.put_env("RAXOL_PROVIDERS", store)

    on_exit(fn ->
      File.rm(store)

      if prev_store,
        do: System.put_env("RAXOL_PROVIDERS", prev_store),
        else: System.delete_env("RAXOL_PROVIDERS")

      Enum.each(saved, fn
        {key, nil} -> System.delete_env(key)
        {key, val} -> System.put_env(key, val)
      end)
    end)

    :ok
  end

  describe "auto-detect precedence" do
    test "no provider anywhere yields :no_provider" do
      assert :no_provider = Resolver.resolve()
    end

    test "a provider env key is detected" do
      System.put_env("ANTHROPIC_API_KEY", "sk-ant")
      assert {:ok, config, :env} = Resolver.resolve()
      assert config.backend == :anthropic
      assert config.auth == %{api_key: "sk-ant"}
    end

    test "registry order wins when several env keys are present" do
      System.put_env("OPENAI_API_KEY", "sk-oai")
      System.put_env("KIMI_API_KEY", "sk-kimi")
      # openai precedes kimi in the registry.
      assert {:ok, %{backend: :openai}, :env} = Resolver.resolve()
    end

    test "the generic AI_API_KEY maps onto :openai with its base URL" do
      System.put_env("AI_API_KEY", "sk-generic")
      System.put_env("AI_BASE_URL", "https://example.test")
      System.put_env("AI_MODEL", "some-model")

      assert {:ok, config, :generic} = Resolver.resolve()
      assert config.backend == :openai
      assert config.auth == %{api_key: "sk-generic"}
      assert config.model == "some-model"
      assert config.opts[:base_url] == "https://example.test"
    end

    test "a keyed provider outranks the generic escape hatch" do
      System.put_env("ANTHROPIC_API_KEY", "sk-ant")
      System.put_env("AI_API_KEY", "sk-generic")
      assert {:ok, %{backend: :anthropic}, :env} = Resolver.resolve()
    end

    test "a stored keyless provider is auto-selected as :configured" do
      Credentials.put(:lm_studio, base_url: "http://localhost:1234")
      assert {:ok, config, :configured} = Resolver.resolve()
      assert config.backend == :lm_studio
      assert config.auth == %{}
    end
  end

  describe "explicit harness" do
    test "resolves the named provider's env key" do
      System.put_env("OPENAI_API_KEY", "sk-oai")
      assert {:ok, config, :env} = Resolver.resolve(harness: :openai)
      assert config.backend == :openai
      assert config.auth == %{api_key: "sk-oai"}
    end

    test "an explicit api_key opt wins over the env key" do
      System.put_env("OPENAI_API_KEY", "sk-env")

      assert {:ok, config, :explicit} =
               Resolver.resolve(harness: :openai, api_key: "sk-opt")

      assert config.auth == %{api_key: "sk-opt"}
    end

    test "a keyed provider with no credential yields {:no_key, harness}" do
      assert {:no_key, :anthropic} = Resolver.resolve(harness: :anthropic)
    end

    test "a keyless provider needs no key" do
      assert {:ok, config, :explicit} = Resolver.resolve(harness: :lm_studio)
      assert config.backend == :lm_studio
      assert config.auth == %{}
    end

    test "a base_url opt flows into the config opts" do
      assert {:ok, config, :explicit} =
               Resolver.resolve(harness: :ollama, base_url: "http://host:11434")

      assert config.opts[:base_url] == "http://host:11434"
    end
  end

  describe "model precedence" do
    test "explicit model opt beats the stored model and env model" do
      Credentials.put(:anthropic, op_ref: "op://v/i/f", model: "stored-model")
      System.put_env("ANTHROPIC_MODEL", "env-model")
      System.put_env("ANTHROPIC_API_KEY", "sk-ant")

      assert {:ok, config, _} =
               Resolver.resolve(harness: :anthropic, model: "opt-model")

      assert config.model == "opt-model"
    end

    test "the provider model env var is used when no override is given" do
      System.put_env("ANTHROPIC_MODEL", "env-model")
      System.put_env("ANTHROPIC_API_KEY", "sk-ant")
      assert {:ok, config, _} = Resolver.resolve(harness: :anthropic)
      assert config.model == "env-model"
    end
  end

  describe "1Password reference fall-through" do
    test "a stored op ref that can't resolve falls through to the env key" do
      # Deterministic only without the op CLI; a live op binary depends on
      # vault state, so we skip the env-source assertion when op is present.
      Credentials.put(:openai, op_ref: "op://__raxol_test__/nope/field")
      System.put_env("OPENAI_API_KEY", "sk-env")

      # A bogus op ref fails to resolve (op absent, or op present but the item
      # does not exist), so the env key supplies the secret. If a live op
      # binary somehow resolves the ref, the source is :op instead.
      case Resolver.resolve(harness: :openai) do
        {:ok, config, :env} ->
          assert config.auth == %{api_key: "sk-env"}

        {:ok, _config, :op} ->
          assert Credentials.op_available?()
      end
    end
  end

  describe "status/0 and helpers" do
    test "status marks a provider available once its key is present" do
      System.put_env("OPENAI_API_KEY", "sk-oai")
      status = Resolver.status()
      openai = Enum.find(status, &(&1.harness == :openai))
      assert openai.available?
      assert openai.source == :env

      anthropic = Enum.find(status, &(&1.harness == :anthropic))
      refute anthropic.available?
    end

    test "harness_from_string maps known names and rejects unknown" do
      assert {:ok, :anthropic} = Resolver.harness_from_string("anthropic")
      assert {:ok, :lm_studio} = Resolver.harness_from_string("lm_studio")
      assert :error = Resolver.harness_from_string("not_a_provider")
    end

    test "providers/0 lists harness + keyless flag" do
      providers = Resolver.providers()

      assert Enum.any?(
               providers,
               &(&1.harness == :anthropic and &1.keyless? == false)
             )

      assert Enum.any?(
               providers,
               &(&1.harness == :lm_studio and &1.keyless? == true)
             )
    end
  end

  describe "diagnostics/0" do
    test "reports the op state and a provider list" do
      diag = Resolver.diagnostics()
      assert diag.op in [:absent, :not_signed_in, :ok]
      assert Enum.any?(diag.providers, &(&1.harness == :anthropic))
    end

    test "notes an env var that is set but empty" do
      System.put_env("OPENAI_API_KEY", "")
      diag = Resolver.diagnostics()
      openai = Enum.find(diag.providers, &(&1.harness == :openai))
      refute openai.available?
      assert openai.note =~ "set but empty"
    end

    test "an available provider carries no note" do
      System.put_env("ANTHROPIC_API_KEY", "sk-ant")
      diag = Resolver.diagnostics()
      anthropic = Enum.find(diag.providers, &(&1.harness == :anthropic))
      assert anthropic.available?
      assert anthropic.note == nil
    end
  end
end
