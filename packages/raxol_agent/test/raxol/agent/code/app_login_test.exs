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

  describe "hosted (jailed) session command gating" do
    # On a multi-tenant host the keyboard principal is a tenant, not the host
    # owner. /login and /logout mutate the host-global credential store, and
    # /copy drives the host clipboard — none may be reachable from a tenant.
    test "/login is refused and writes no credential in a jailed session" do
      model =
        new_model(:no_provider, jail: true)
        |> type("/login anthropic op://Vault/Anthropic/key")

      assert model.notice =~ "disabled in a hosted session"
      assert model.provider_status == :no_provider
      assert Credentials.fetch(:anthropic) == :none
    end

    test "/logout is refused in a jailed session" do
      model =
        new_model({:ready, :lm_studio, :explicit}, jail: true)
        |> type("/logout anthropic")

      assert model.notice =~ "disabled in a hosted session"
      # The provider the tenant was using is untouched.
      assert {:ready, :lm_studio, _} = model.provider_status
    end

    test "/copy is unavailable in a jailed session" do
      model = new_model(:no_provider, jail: true) |> type("/copy")
      assert model.notice =~ "unavailable in a hosted session"
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

  describe "/login <provider> browser" do
    defp signin_recording do
      caller = self()

      fn harness, ref, app ->
        send(caller, {:signin_started, harness, ref, app})
        :ok
      end
    end

    # The flow waits on a human in a browser. Running it inline would freeze
    # the TEA loop for as long as they took, so `/login` must return at once
    # with only a ref to match the result by.
    test "starts the sign-in off the app process and returns immediately" do
      model =
        new_model(:no_provider, signin_runner: signin_recording())
        |> type("/login openrouter browser")

      assert_received {:signin_started, :openrouter, ref, app}
      assert app == self()
      assert model.signin_ref == ref
      assert model.notice =~ "opening a browser"
      assert model.status_line =~ "waiting for openrouter"
      assert model.provider_status == :no_provider
    end

    test "a completed sign-in connects the provider" do
      System.put_env("OPENROUTER_API_KEY", "sk-or-live")

      model =
        new_model(:no_provider,
          signin_runner: signin_recording(),
          login_validator: noop_validator()
        )
        |> type("/login openrouter browser")

      assert_received {:signin_started, :openrouter, ref, _app}

      {model, []} =
        App.update(
          {:command_result, {:browser_signin, ref, :openrouter, {:ok, %{validation: :valid}}}},
          model
        )

      assert {:ready, :openrouter, _source} = model.provider_status
      assert model.signin_ref == nil
      assert model.notice =~ "browser sign-in"
    end

    test "a failed sign-in says why and leaves the provider unconnected" do
      model =
        new_model(:no_provider, signin_runner: signin_recording())
        |> type("/login openrouter browser")

      assert_received {:signin_started, :openrouter, ref, _app}

      {model, []} =
        App.update(
          {:command_result, {:browser_signin, ref, :openrouter, {:error, :timeout}}},
          model
        )

      assert model.notice =~ "timed out"
      assert model.provider_status == :no_provider
      assert model.signin_ref == nil
    end

    # Same ref discipline as the validation ping: a superseded sign-in must not
    # connect a provider the user has since moved on from.
    test "a superseded sign-in result is ignored" do
      model =
        new_model(:no_provider, signin_runner: signin_recording())
        |> type("/login openrouter browser")

      assert_received {:signin_started, :openrouter, _ref, _app}
      current = model.signin_ref

      {model, []} =
        App.update(
          {:command_result,
           {:browser_signin, make_ref(), :openrouter, {:ok, %{validation: :valid}}}},
          model
        )

      assert model.provider_status == :no_provider
      assert model.signin_ref == current
    end

    # Advertising a browser sign-in for a provider that has none would hang the
    # user on a flow that never starts.
    test "a provider without a browser flow is refused, and nothing is spawned" do
      runner = fn _harness, _ref, _app -> flunk("spawned a flow for anthropic") end

      model =
        new_model(:no_provider, signin_runner: runner)
        |> type("/login anthropic browser")

      assert model.notice =~ "no browser sign-in"
      assert model.signin_ref == nil
    end

    test "is refused in a jailed session like the rest of /login" do
      runner = fn _harness, _ref, _app -> flunk("spawned a flow in a jail") end

      model =
        new_model(:no_provider, jail: true, signin_runner: runner)
        |> type("/login openrouter browser")

      assert model.notice =~ "disabled in a hosted session"
      assert model.signin_ref == nil
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

      assert_receive {:command_result, {:login_validation, ref, :openai, :valid}} = msg

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

      assert_receive {:command_result, {:login_validation, _ref, :openai, {:rejected, 401}}} =
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

      assert_receive {:command_result, {:login_validation, _ref, :lm_studio, :unreachable}} = msg

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
          {:command_result, {:login_validation, stale, :openai, {:rejected, 401}}},
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
