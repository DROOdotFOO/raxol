defmodule Raxol.Agent.Code.AppLoginTest do
  use ExUnit.Case, async: false

  alias Raxol.Agent.Backend.Credentials
  alias Raxol.Agent.Code.App
  alias Raxol.Core.Events.Event

  @managed_env ~w(
    ANTHROPIC_API_KEY OPENAI_API_KEY KIMI_API_KEY MOONSHOT_API_KEY
    OPENROUTER_API_KEY LONGCAT_API_KEY PROTON_ACCESS_TOKEN
    AI_API_KEY AI_BASE_URL AI_MODEL
    RAXOL_ANTHROPIC_OP RAXOL_OPENAI_OP RAXOL_LM_STUDIO_OP
  )

  setup do
    saved = Map.new(@managed_env, fn key -> {key, System.get_env(key)} end)
    Enum.each(@managed_env, &System.delete_env/1)

    store =
      Path.join(
        System.tmp_dir!(),
        "raxol-applogin-#{System.unique_integer([:positive])}.json"
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

  defp stub_runner do
    fn _session_id, _prompt, _opts, _app ->
      spawn(fn -> Process.sleep(60_000) end)
    end
  end

  # A no-op validator by default so connect tests never touch the network;
  # validation-specific tests inject one that sends a canned result.
  defp noop_validator, do: fn _executor, _ref, _app -> :ok end

  defp validator_sending(result) do
    fn executor, ref, app ->
      send(
        app,
        {:command_result, {:login_validation, ref, executor.backend, result}}
      )

      :ok
    end
  end

  defp new_model(provider_status, extra \\ []) do
    options =
      [
        runner: stub_runner(),
        login_validator: noop_validator(),
        cwd:
          Path.join(
            System.tmp_dir!(),
            "raxol-applogin-cwd-#{System.unique_integer([:positive])}"
          ),
        sessions_dir:
          Path.join(
            System.tmp_dir!(),
            "raxol-applogin-sess-#{System.unique_integer([:positive])}"
          ),
        provider_status: provider_status
      ]
      |> Keyword.merge(extra)

    App.init(%{options: options})
  end

  defp key(k, mods \\ []), do: Event.key_event(k, :pressed, mods)

  defp type(model, text) do
    {model, []} = App.update(key(:enter), %{model | input: text})
    model
  end

  defp submit(model, prompt) do
    {model, cmds} = App.update(key(:enter), %{model | input: prompt})
    {model, cmds}
  end

  describe "turn gating" do
    test "a prompt does not start a turn when no provider is connected" do
      model = new_model(:no_provider)
      {model, cmds} = submit(model, "write me a function")

      refute model.running?
      assert cmds == []
      assert model.notice =~ "provider"
    end

    test "a prompt starts a turn once a provider is connected" do
      model = new_model({:ready, :lm_studio, :explicit})
      {model, _cmds} = submit(model, "write me a function")
      assert model.running?
    end
  end

  describe "/login" do
    test "with no argument opens the browse wizard" do
      model = new_model(:no_provider) |> type("/login")
      assert %{step: :browse, entries: entries} = model.wizard
      assert Enum.any?(entries, &(&1.harness == :anthropic))
    end

    test "connects a keyless local provider" do
      model = new_model(:no_provider) |> type("/login lm_studio")

      assert {:ready, :lm_studio, _source} = model.provider_status
      assert model.executor.backend == :lm_studio
      assert model.notice =~ "connected to lm_studio"
    end

    test "connects with a session-only key that is not persisted" do
      model = new_model(:no_provider) |> type("/login openai sk-session")

      assert {:ready, :openai, :explicit} = model.provider_status
      assert model.executor.auth == %{api_key: "sk-session"}
      assert model.notice =~ "not persisted"
      # Session key must never touch the reference store.
      assert Credentials.fetch(:openai) == :none
    end

    test "stores an op reference (falling through to env keeps it deterministic)" do
      System.put_env("ANTHROPIC_API_KEY", "sk-env")

      model =
        new_model(:no_provider)
        |> type("/login anthropic op://Vault/Anthropic/key")

      # The reference is persisted regardless of whether op or the env key
      # ultimately supplied the secret.
      assert {:ok, %{op_ref: "op://Vault/Anthropic/key"}} =
               Credentials.fetch(:anthropic)

      assert {:ready, :anthropic, _source} = model.provider_status
    end

    test "rejects an unknown provider without connecting" do
      model = new_model(:no_provider) |> type("/login not_a_provider sk-x")
      assert model.notice =~ "unknown provider"
      assert model.provider_status == :no_provider
    end

    test "a keyed provider with no credential explains how to supply one" do
      model = new_model(:no_provider) |> type("/login anthropic")
      assert model.notice =~ "no credential found for anthropic"
      assert model.provider_status == :no_provider
    end

    test "connecting then submitting starts a turn" do
      model = new_model(:no_provider) |> type("/login lm_studio")
      {model, _cmds} = submit(model, "do the thing")
      assert model.running?
    end
  end

  describe "/login validation" do
    test "connecting shows a validating status and stamps a login ref" do
      model =
        new_model(:no_provider, login_validator: noop_validator())
        |> type("/login lm_studio")

      assert model.status_line =~ "validating"
      assert is_reference(model.login_ref)
    end

    test "a validated credential updates the status line" do
      model =
        new_model(:no_provider, login_validator: validator_sending(:valid))

      model = type(model, "/login openai sk-good")

      assert_receive {:command_result,
                      {:login_validation, ref, :openai, :valid}} = msg

      assert ref == model.login_ref

      {model, []} = App.update(msg, model)
      assert model.status_line =~ "validated"
      assert model.login_ref == nil
    end

    test "a rejected key surfaces the HTTP status" do
      model =
        new_model(:no_provider,
          login_validator: validator_sending({:rejected, 401})
        )

      model = type(model, "/login openai sk-bad")

      assert_receive {:command_result,
                      {:login_validation, _ref, :openai, {:rejected, 401}}} =
                       msg

      {model, []} = App.update(msg, model)
      assert model.status_line =~ "rejected"
      assert model.status_line =~ "401"
    end

    test "an unreachable local server is reported" do
      model =
        new_model(:no_provider,
          login_validator: validator_sending(:unreachable)
        )

      model = type(model, "/login lm_studio")

      assert_receive {:command_result,
                      {:login_validation, _ref, :lm_studio, :unreachable}} = msg

      {model, []} = App.update(msg, model)
      assert model.status_line =~ "unreachable"
    end

    test "a stale validation result (superseded login) is ignored" do
      model = new_model(:no_provider, login_validator: noop_validator())
      model = type(model, "/login lm_studio")
      before = model.status_line

      stale = make_ref()

      {model, []} =
        App.update(
          {:command_result,
           {:login_validation, stale, :openai, {:rejected, 401}}},
          model
        )

      assert model.status_line == before
      assert is_reference(model.login_ref)
    end
  end

  describe "interpret_ping/1" do
    test "a 2xx completion is valid" do
      assert App.interpret_ping({:ok, %{content: "ok"}}) == :valid
    end

    test "401/403 mean the key was rejected" do
      assert App.interpret_ping({:error, {:http_error, 401, "no"}}) ==
               {:rejected, 401}

      assert App.interpret_ping({:error, {:http_error, 403, "no"}}) ==
               {:rejected, 403}
    end

    test "a transport failure is unreachable" do
      assert App.interpret_ping({:error, {:request_failed, :econnrefused}}) ==
               :unreachable
    end

    test "another HTTP status is reachable-but-errored" do
      assert App.interpret_ping({:error, {:http_error, 500, ""}}) ==
               {:reachable_error, 500}
    end

    test "a content-level marker still means the key is valid (auth succeeded)" do
      assert App.interpret_ping({:error, "⚠ response truncated"}) == :valid
    end
  end
end
