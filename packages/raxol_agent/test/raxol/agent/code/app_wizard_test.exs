defmodule Raxol.Agent.Code.AppWizardTest do
  use ExUnit.Case, async: false

  alias Raxol.Agent.Backend.Credentials
  alias Raxol.Agent.Code.App
  alias Raxol.Agent.Code.App.Commands
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

  # Everything `App.view/1` would put on screen, as one string: the panels
  # only assert `%{} = App.view(...)` otherwise, so wording changes in a
  # rendered panel are invisible to the suite.
  defp view_text(model), do: model |> App.view() |> node_text() |> Enum.join("\n")

  defp node_text(%{type: :text, content: content}) when is_binary(content),
    do: [content]

  defp node_text(%{children: children}), do: node_text(children)
  defp node_text(nodes) when is_list(nodes), do: Enum.flat_map(nodes, &node_text/1)
  defp node_text(_other), do: []

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

  describe "hosted (jailed) session" do
    # The wizard ends in the HOST-GLOBAL credential store (`Credentials.put`
    # via connect/4, plus a 1Password item via the op saver). A tenant on a
    # multi-tenant host must not reach either, from any entry point.
    test "init does not open the wizard and says why" do
      model = new_model(jail: true)

      assert model.wizard == nil
      assert model.provider_status == :no_provider

      # Asserted on the rendered surface rather than on `notice`: the reason
      # lives in the persistent hint panel now, because a notice is replaced
      # by the next command while "no provider is connected" stays true.
      assert view_text(model) =~ "credential management is disabled in a hosted session"
    end

    test "init still skips the wizard when the host pre-wired a provider" do
      model = new_model(jail: true, provider_status: {:ready, :lm_studio, :explicit})

      assert model.wizard == nil
      assert model.notice == nil
    end

    test "connect/4 refuses an op:// reference without touching the store" do
      model = new_model(jail: true)

      model = Commands.connect(model, :anthropic, "op://Vault/Anthropic/key", nil)

      assert model.notice =~ "credential management is disabled in a hosted session"
      assert model.provider_status == :no_provider
      assert model.login_ref == nil
      assert Credentials.fetch(:anthropic) == :none
    end

    test "connect/4 refuses a raw key too" do
      model = Commands.connect(new_model(jail: true), :openai, "sk-raw", nil)

      assert model.notice =~ "credential management is disabled in a hosted session"
      assert model.provider_status == :no_provider
      assert model.executor == nil
    end

    test "a credential-step submit closes the wizard with the refusal, storing nothing" do
      model =
        %{
          new_model(jail: true)
          | wizard: %{step: :credential, harness: :openai, buffer: "sk-raw"}
        }
        |> press(:enter)

      assert model.wizard == nil
      assert model.notice =~ "credential management is disabled in a hosted session"
      assert model.provider_status == :no_provider
      assert Credentials.fetch(:openai) == :none
    end

    test "the 1Password save is refused at the resource" do
      test_pid = self()

      model =
        new_model(
          jail: true,
          op_saver: fn harness, key ->
            send(test_pid, {:op_saver_called, harness, key})
            {:ok, "op://Vault/OpenAI/credential"}
          end
        )

      model =
        %{model | wizard: %{step: :confirm_save, harness: :openai, key: "sk-raw"}}
        |> press("y")

      assert model.wizard == nil
      assert model.notice =~ "credential management is disabled in a hosted session"
      assert Credentials.fetch(:openai) == :none
      refute_received {:op_saver_called, _, _}
    end

    # The unconnected-provider panel is the first thing a hosted tenant sees.
    # It used to render the full "Connect a provider with /login:" cheatsheet
    # in a session where /login refuses and init opens no wizard.
    test "the hint panel does not advertise /login in a hosted session" do
      jailed = view_text(new_model(jail: true))

      assert jailed =~ "credential management is disabled in a hosted session"
      refute jailed =~ "/login"
      refute jailed =~ "connect a provider to begin"

      # Unjailed, the cheatsheet is still the whole point of the panel (it
      # shows once the browse wizard init opens is dismissed).
      open = view_text(press(new_model(), :escape))
      assert open =~ "Connect a provider with /login:"
      assert open =~ "connect a provider to begin"
    end

    # The jail clause used to sit ahead of the `{:no_key, harness}` one, so a
    # hosted session whose host DID pre-wire a provider but whose key failed
    # to resolve was told "credential management is disabled" -- the policy,
    # not the diagnosis. The operator needs both.
    test "a jailed session with an unresolved key still names the harness" do
      jailed = view_text(new_model(jail: true, provider_status: {:no_key, :anthropic}))

      assert jailed =~ "harness anthropic was selected but no key resolved"
      assert jailed =~ "credential management is disabled in a hosted session"
      refute jailed =~ "/login"
    end

    # Panel heading, panel body and a boot notice used to render the same
    # sentence on three consecutive lines of a hosted tenant's first screen.
    # The panel is the durable copy (it persists while no provider is
    # connected); the notice was transient and is gone.
    test "the jailed first screen does not repeat itself" do
      screen = view_text(new_model(jail: true))

      assert count_of(screen, "no provider connected") == 1
      assert count_of(screen, "credential management is disabled in a hosted session") == 1
    end

    defp count_of(haystack, needle),
      do: haystack |> String.split(needle) |> length() |> Kernel.-(1)

    test "a prompt sent with no provider says the same thing in a jail" do
      {model, []} =
        App.update(Event.key_event(:enter, :pressed, []), %{
          new_model(jail: true)
          | input: "hello"
        })

      assert model.notice =~ "credential management is disabled in a hosted session"
      refute model.notice =~ "/login"
      refute model.running?
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
