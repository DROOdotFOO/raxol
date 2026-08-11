defmodule Raxol.Agent.Code.AppWizardTest do
  use ExUnit.Case, async: false

  alias Raxol.Agent.Backend.Credentials
  alias Raxol.Agent.Code.App
  alias Raxol.Agent.ExecutorConfig
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
        "raxol-wizard-#{System.unique_integer([:positive])}.json"
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

  defp new_model(extra \\ []) do
    options =
      [
        login_validator: noop_validator(),
        op_saver: fn _harness, _key -> {:ok, "op://Vault/Item/credential"} end,
        cwd: tmp("cwd"),
        sessions_dir: tmp("sess"),
        provider_status: :no_provider
      ]
      |> Keyword.merge(extra)

    App.init(%{options: options})
  end

  defp tmp(tag),
    do:
      Path.join(
        System.tmp_dir!(),
        "raxol-wizard-#{tag}-#{System.unique_integer([:positive])}"
      )

  defp key(k, mods \\ []), do: Event.key_event(k, :pressed, mods)

  defp press(model, k) do
    {model, _cmds} = App.update(key(k), model)
    model
  end

  describe "browse" do
    test "init opens the browse wizard when no provider is connected" do
      model = new_model()
      assert %{step: :browse, entries: entries, cursor: cursor} = model.wizard
      assert is_integer(cursor)
      assert Enum.any?(entries, &(&1.harness == :anthropic))
    end

    test "arrow keys move the cursor within bounds" do
      model = new_model()
      start = model.wizard.cursor

      model = press(model, :down)
      assert model.wizard.cursor == start + 1

      # Up past the top clamps at 0.
      model = model |> press(:up) |> press(:up) |> press(:up)
      assert model.wizard.cursor == 0
    end

    test "Esc closes the browse wizard" do
      model = new_model() |> press(:escape)
      assert model.wizard == nil
    end

    test "Enter on a keyed provider opens masked credential entry" do
      # Navigate to anthropic by harness rather than by position: the registry
      # leads with the keyless subscription harness, so index 0 is not keyed.
      model = new_model()
      index = Enum.find_index(model.wizard.entries, &(&1.harness == :anthropic))
      model = Enum.reduce(1..index, model, fn _, m -> press(m, :down) end)

      assert Enum.at(model.wizard.entries, model.wizard.cursor).harness ==
               :anthropic

      model = press(model, :enter)

      assert %{step: :credential, harness: :anthropic, buffer: ""} =
               model.wizard
    end

    test "Enter on a keyless provider connects and closes the wizard" do
      model = new_model()
      index = Enum.find_index(model.wizard.entries, &(&1.harness == :lm_studio))
      model = Enum.reduce(1..index, model, fn _, m -> press(m, :down) end)

      assert Enum.at(model.wizard.entries, model.wizard.cursor).harness ==
               :lm_studio

      model = press(model, :enter)
      assert {:ready, :lm_studio, _} = model.provider_status
      assert model.wizard == nil
    end
  end

  describe "credential entry" do
    defp to_credential(model, harness) do
      %{model | wizard: %{step: :credential, harness: harness, buffer: ""}}
    end

    test "typing accumulates into the buffer" do
      model = new_model() |> to_credential(:openai)
      model = model |> press("s") |> press("k") |> press("1")
      assert model.wizard.buffer == "sk1"

      model = press(model, :backspace)
      assert model.wizard.buffer == "sk"
    end

    test "an op:// reference is stored and connects (env fallback keeps it deterministic)" do
      System.put_env("ANTHROPIC_API_KEY", "sk-env")
      model = new_model() |> to_credential(:anthropic)

      model = %{
        model
        | wizard: %{model.wizard | buffer: "op://Vault/Anthropic/key"}
      }

      model = press(model, :enter)

      assert {:ok, %{op_ref: "op://Vault/Anthropic/key"}} =
               Credentials.fetch(:anthropic)

      assert {:ready, :anthropic, _} = model.provider_status
      assert model.wizard == nil
    end

    test "a raw key connects for the session and never persists to the store" do
      model = new_model() |> to_credential(:openai)
      model = %{model | wizard: %{model.wizard | buffer: "sk-raw"}}

      model = press(model, :enter)

      assert {:ready, :openai, :explicit} = model.provider_status
      assert model.executor.auth == %{api_key: "sk-raw"}
      # Either an offer to save (op present) or already closed (op absent) --
      # but the raw key is never written to the reference store directly.
      assert model.wizard == nil or match?(%{step: :confirm_save}, model.wizard)
      assert Credentials.fetch(:openai) == :none
    end

    test "Esc from credential entry returns to the browse list" do
      model = new_model() |> to_credential(:openai)
      model = press(model, :escape)
      assert %{step: :browse} = model.wizard
    end
  end

  describe "save to 1Password" do
    defp to_confirm_save(model, harness, key) do
      %{model | wizard: %{step: :confirm_save, harness: harness, key: key}}
    end

    test "y saves the key via the op saver and stores the returned reference" do
      model =
        new_model(op_saver: fn _h, _k -> {:ok, "op://Vault/OpenAI/credential"} end)
        |> to_confirm_save(:openai, "sk-raw")

      model = press(model, "y")

      assert {:ok, %{op_ref: "op://Vault/OpenAI/credential"}} =
               Credentials.fetch(:openai)

      assert model.wizard == nil
      assert model.notice =~ "saved openai key to 1Password"
    end

    test "a failed save keeps the session key and reports it" do
      model =
        new_model(op_saver: fn _h, _k -> {:error, :op_create_failed} end)
        |> to_confirm_save(:openai, "sk-raw")

      model = press(model, "y")

      assert Credentials.fetch(:openai) == :none
      assert model.wizard == nil
      assert model.notice =~ "could not save to 1Password"
    end

    test "n keeps the key for the session only" do
      model = new_model() |> to_confirm_save(:openai, "sk-raw")
      model = press(model, "n")

      assert model.wizard == nil
      assert model.notice =~ "kept for this session only"
      assert Credentials.fetch(:openai) == :none
    end
  end

  describe "validate at launch" do
    test "an auto-detected provider is validated on the first update" do
      executor = ExecutorConfig.new(harness: :openai, auth: %{api_key: "sk-x"})

      model =
        new_model(
          provider_status: {:ready, :openai, :env},
          executor: executor,
          login_validator: validator_sending(:valid)
        )

      assert model.pending_validation == executor

      # The first update fires the armed ping (in the dispatcher process).
      model = press(model, "h")
      assert model.pending_validation == nil
      assert is_reference(model.login_ref)

      assert_receive {:command_result, {:login_validation, ref, :openai, :valid}} = msg

      assert ref == model.login_ref

      {model, []} = App.update(msg, model)
      assert model.status_line =~ "validated"
    end

    test "no launch validation is armed without an executor" do
      model = new_model(provider_status: :ready)
      assert model.pending_validation == nil
    end
  end
end
