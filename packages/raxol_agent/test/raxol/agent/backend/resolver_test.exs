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

    # Auto-detection now considers an installed vendor CLI (the subscription
    # harness), which would otherwise make every assertion here depend on
    # whether `claude` happens to be on this host's PATH. `config/config.exs`
    # already pins this false for :test; save and RESTORE it rather than
    # deleting, or the tests that follow this module lose that pin and start
    # resolving against the real CLI.
    prev_probe = Application.fetch_env(:raxol_agent, :native_probe)
    Application.put_env(:raxol_agent, :native_probe, fn _mod -> false end)

    on_exit(fn ->
      case prev_probe do
        {:ok, value} -> Application.put_env(:raxol_agent, :native_probe, value)
        :error -> Application.delete_env(:raxol_agent, :native_probe)
      end
    end)

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

  # Auto-detection refuses to spend, so the precedence rules below are about
  # ordering WITHIN the paid tier and only apply once paid use is opted into.
  defp allow_paid! do
    System.put_env("RAXOL_ALLOW_PAID_API", "1")
    on_exit(fn -> System.delete_env("RAXOL_ALLOW_PAID_API") end)
  end

  describe "auto-detect never spends" do
    test "a configured API-credit provider is NOT auto-selected" do
      System.put_env("ANTHROPIC_API_KEY", "sk-ant")
      System.put_env("OPENROUTER_API_KEY", "sk-or")

      assert :no_provider = Resolver.resolve()
    end

    test "the generic AI_API_KEY is not auto-selected either" do
      System.put_env("AI_API_KEY", "sk-generic")
      assert :no_provider = Resolver.resolve()
    end

    test "RAXOL_ALLOW_PAID_API restores the walk-everything order" do
      allow_paid!()
      System.put_env("ANTHROPIC_API_KEY", "sk-ant")

      assert {:ok, %{backend: :anthropic}, :env} = Resolver.resolve()
    end

    test "naming a paid harness explicitly still resolves it" do
      System.put_env("OPENROUTER_API_KEY", "sk-or")

      assert {:ok, config, :env} = Resolver.resolve(harness: :openrouter)
      assert config.backend == :openrouter
    end

    test "a free provider is still auto-selected with no opt-in" do
      Credentials.put(:lm_studio, base_url: "http://localhost:1234")
      System.put_env("OPENROUTER_API_KEY", "sk-or")

      assert {:ok, %{backend: :lm_studio}, :configured} = Resolver.resolve()
    end
  end

  describe "subscription harness" do
    test "an installed vendor CLI is auto-selected ahead of a paid provider" do
      Application.put_env(:raxol_agent, :native_probe, fn _mod -> true end)
      allow_paid!()
      System.put_env("ANTHROPIC_API_KEY", "sk-ant")

      assert {:ok, config, :subscription} = Resolver.resolve()
      assert config.backend == :claude_native
      assert config.auth == %{}
    end

    test "an absent CLI falls through rather than resolving to it" do
      System.put_env("ANTHROPIC_API_KEY", "sk-ant")
      assert :no_provider = Resolver.resolve()
    end

    # Naming a harness resolves it whether or not its CLI is installed, and the
    # source is the naming itself -- `:subscription` is what AUTO-detection
    # reports when it picks one up on its own.
    test "grok resolves by name with no credential to supply" do
      assert {:ok, config, :explicit} = Resolver.resolve(harness: :grok_native)
      assert config.backend == :grok_native
      assert config.auth == %{}
    end

    test "grok is auto-selected when its CLI is present" do
      Application.put_env(:raxol_agent, :native_probe, fn
        Raxol.Agent.Backend.GrokBuild -> true
        _other -> false
      end)

      assert {:ok, %{backend: :grok_native}, :subscription} = Resolver.resolve()
    end

    # Both subscription harnesses are registry entries, so the setup panel and
    # /login list them whether or not their CLI is installed.
    test "both subscription harnesses are in the registry, ahead of the paid ones" do
      harnesses = Enum.map(Resolver.providers(), & &1.harness)

      assert :claude_native in harnesses
      assert :grok_native in harnesses

      subscription_last =
        harnesses |> Enum.find_index(&(&1 == :grok_native))

      paid_first =
        harnesses |> Enum.find_index(&(&1 in [:anthropic, :openai, :openrouter]))

      assert subscription_last < paid_first
    end
  end

  describe "auto-detect precedence" do
    test "no provider anywhere yields :no_provider" do
      assert :no_provider = Resolver.resolve()
    end

    test "a provider env key is detected" do
      allow_paid!()
      System.put_env("ANTHROPIC_API_KEY", "sk-ant")
      assert {:ok, config, :env} = Resolver.resolve()
      assert config.backend == :anthropic
      assert config.auth == %{api_key: "sk-ant"}
    end

    test "registry order wins when several env keys are present" do
      allow_paid!()
      System.put_env("OPENAI_API_KEY", "sk-oai")
      System.put_env("KIMI_API_KEY", "sk-kimi")
      # openai precedes kimi in the registry.
      assert {:ok, %{backend: :openai}, :env} = Resolver.resolve()
    end

    test "the generic AI_API_KEY maps onto :openai with its base URL" do
      allow_paid!()
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
      allow_paid!()
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

  describe "diagnostics/0 against an unusable op CLI" do
    # A fake `op` that records every invocation and always fails, standing in
    # for a signed-out CLI. A locked vault behaves worse still: each call blocks
    # on a desktop authorization prompt until the timeout.
    setup do
      dir =
        Path.join(
          System.tmp_dir!(),
          "raxol-op-count-#{System.os_time(:millisecond)}-" <>
            "#{System.unique_integer([:positive])}"
        )

      File.mkdir_p!(dir)
      log = Path.join(dir, "calls")
      fake_op = Path.join(dir, "op")

      File.write!(fake_op, "#!/bin/sh\necho \"$@\" >> #{log}\nexit 1\n")
      File.chmod!(fake_op, 0o755)

      prev_path = System.get_env("PATH")
      System.put_env("PATH", dir <> ":" <> (prev_path || ""))

      on_exit(fn ->
        System.put_env("PATH", prev_path || "")
        File.rm_rf!(dir)
      end)

      %{log: log}
    end

    test "probes op once for status, not once per provider", %{log: log} do
      # Every provider carries a stored reference, so before the fix each one
      # shelled out to `op read` on top of the single `op whoami` -- a serial
      # storm that made `/inspect` take 12 to 22 seconds against a locked vault
      # and raised one authorization prompt per provider.
      for var <- ~w(RAXOL_ANTHROPIC_OP RAXOL_OPENAI_OP RAXOL_KIMI_OP RAXOL_OPENROUTER_OP) do
        System.put_env(var, "op://vault/#{var}/credential")
      end

      diag = Resolver.diagnostics()

      assert diag.op == :not_signed_in

      calls =
        if File.exists?(log), do: log |> File.read!() |> String.split("\n", trim: true), else: []

      assert length(calls) == 1,
             "expected one `op whoami`, got #{length(calls)}: #{inspect(calls)}"

      assert hd(calls) =~ "whoami"
    end

    test "a stored reference still reports why it is unavailable" do
      # Skipping the probe must not cost the diagnostic its answer: the note is
      # the same conclusion the probe would have reached, minus the wait.
      System.put_env("RAXOL_ANTHROPIC_OP", "op://vault/anthropic/credential")

      anthropic =
        Resolver.diagnostics().providers
        |> Enum.find(&(&1.harness == :anthropic))

      refute anthropic.available?
      assert anthropic.note =~ "op signin"
    end
  end
end
