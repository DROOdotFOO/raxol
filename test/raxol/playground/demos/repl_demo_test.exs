defmodule Raxol.Playground.Demos.ReplDemoTest do
  # `evaluation_enabled?/1` reads process-global state (an env var and the
  # application environment), so these cannot run concurrently with a test
  # that sets it the other way.
  use ExUnit.Case, async: false

  alias Raxol.Playground.Demos.ReplDemo

  setup do
    # Evaluation is off by default (#1045); the tests below exercise the
    # enabled deployment.
    Application.put_env(:raxol_core, :repl_exposed, true)
    on_exit(fn -> Application.delete_env(:raxol_core, :repl_exposed) end)
  end

  defp key(char) when is_binary(char) do
    %Raxol.Core.Events.Event{type: :key, data: %{key: :char, char: char}}
  end

  defp key(special) when is_atom(special) do
    %Raxol.Core.Events.Event{type: :key, data: %{key: special}}
  end

  defp ctrl_key(char) do
    %Raxol.Core.Events.Event{
      type: :key,
      data: %{key: :char, char: char, ctrl: true}
    }
  end

  defp type_string(model, string) do
    string
    |> String.graphemes()
    |> Enum.reduce(model, fn ch, acc ->
      {new_model, _cmds} = ReplDemo.update(key(ch), acc)
      new_model
    end)
  end

  describe "init/1" do
    test "defaults all supported contexts to strict" do
      for context <- [nil, %{}, %{options: []}] do
        model = ReplDemo.init(context)

        assert model.sandbox_level == :strict
        assert model.eval_timeout == Raxol.Core.Defaults.timeout_ms()
      end
    end

    test "a local terminal launch gets the sandbox and timeout it asked for" do
      for sandbox <- [:none, :standard, :strict] do
        model =
          ReplDemo.init(%{
            options: [local_operator: true, sandbox: sandbox, timeout: 250]
          })

        assert model.sandbox_level == sandbox
        assert model.eval_timeout == 250
      end
    end

    # `Raxol.SSH.Server`'s `:app_opts` and `:tenant_opts` land in the same
    # option list, so honouring these unconditionally would let an anonymously
    # served surface ask for `:none` (no check at all) or hold a scheduler for
    # as long as it liked. A served launch keeps the defaults whatever it asks
    # for.
    test "a served launch cannot lower the level or raise the timeout" do
      for env <- [:ssh, :liveview, :telegram, :agent, :gateway] do
        model =
          ReplDemo.init(%{
            options: [
              local_operator: true,
              environment: env,
              sandbox: :none,
              timeout: 600_000
            ]
          })

        assert model.sandbox_level == :strict, "#{env} lowered the level"

        assert model.eval_timeout == Raxol.Core.Defaults.timeout_ms(),
               "#{env} raised the timeout"
      end
    end

    test "options without the local opt-in are ignored" do
      model = ReplDemo.init(%{options: [sandbox: :none, timeout: 600_000]})

      assert model.sandbox_level == :strict
      assert model.eval_timeout == Raxol.Core.Defaults.timeout_ms()
    end

    test "returns initial model" do
      model = ReplDemo.init(nil)
      assert model.input == ""
      assert model.cursor == 0
      assert is_list(model.output)
      assert model.input_history == []
    end
  end

  describe "update/2 -- text input" do
    test "typing characters appends to input" do
      model = ReplDemo.init(nil)
      {model, _} = ReplDemo.update(key("h"), model)
      {model, _} = ReplDemo.update(key("i"), model)
      assert model.input == "hi"
      assert model.cursor == 2
    end

    test "backspace removes last character" do
      model = ReplDemo.init(nil) |> type_string("abc")
      {model, _} = ReplDemo.update(key(:backspace), model)
      assert model.input == "ab"
    end

    test "Ctrl+U clears input" do
      model = ReplDemo.init(nil) |> type_string("hello")
      {model, _} = ReplDemo.update(ctrl_key("u"), model)
      assert model.input == ""
    end
  end

  describe "update/2 -- evaluation" do
    test "Enter with empty input does nothing" do
      model = ReplDemo.init(nil)
      {new_model, _} = ReplDemo.update(key(:enter), model)
      assert new_model.input == ""
      assert length(new_model.output) == length(model.output)
    end

    test "Enter evaluates expression and clears input" do
      model = ReplDemo.init(nil) |> type_string("1 + 2")
      {model, _} = ReplDemo.update(key(:enter), model)
      assert model.input == ""
      assert length(model.output) > 1
    end

    test "evaluation result appears in output" do
      model = ReplDemo.init(nil) |> type_string("42")
      {model, _} = ReplDemo.update(key(:enter), model)

      output_text =
        model.output
        |> Enum.map_join("\n", fn {text, _kind} -> text end)

      assert output_text =~ "42"
    end

    test "bindings persist across evaluations" do
      model = ReplDemo.init(nil) |> type_string("x = 10")
      {model, _} = ReplDemo.update(key(:enter), model)
      model = type_string(model, "x * 3")
      {model, _} = ReplDemo.update(key(:enter), model)

      output_text =
        model.output
        |> Enum.map_join("\n", fn {text, _kind} -> text end)

      assert output_text =~ "30"
    end

    test "sandbox violations show error" do
      model = ReplDemo.init(nil) |> type_string("System.cmd(\"ls\", [])")
      {model, _} = ReplDemo.update(key(:enter), model)

      output_text =
        model.output
        |> Enum.map_join("\n", fn {text, _kind} -> text end)

      assert output_text =~ "Sandbox"
    end
  end

  describe "update/2 -- history" do
    test "up arrow recalls previous input" do
      model = ReplDemo.init(nil) |> type_string("1+1")
      {model, _} = ReplDemo.update(key(:enter), model)
      model = type_string(model, "2+2")
      {model, _} = ReplDemo.update(key(:enter), model)

      {model, _} = ReplDemo.update(key(:up), model)
      assert model.input == "2+2"

      {model, _} = ReplDemo.update(key(:up), model)
      assert model.input == "1+1"
    end

    test "down arrow moves forward in history" do
      model = ReplDemo.init(nil) |> type_string("1+1")
      {model, _} = ReplDemo.update(key(:enter), model)

      {model, _} = ReplDemo.update(key(:up), model)
      assert model.input == "1+1"

      {model, _} = ReplDemo.update(key(:down), model)
      assert model.input == ""
    end
  end

  describe "update/2 -- clear" do
    test "Ctrl+L clears output" do
      model = ReplDemo.init(nil) |> type_string("1+1")
      {model, _} = ReplDemo.update(key(:enter), model)
      assert model.output != []

      {model, _} = ReplDemo.update(ctrl_key("l"), model)
      assert model.output == []
    end
  end

  describe "view/1" do
    test "returns a view tree" do
      model = ReplDemo.init(nil)
      view = ReplDemo.view(model)
      assert is_map(view) or is_list(view)
    end
  end

  # The playground's HTTP gallery serves every catalog entry at `/demos/:demo`
  # with no auth, and this demo evaluates submitted Elixir with the node's full
  # authority. Whether a deployment allows that is a deployment decision, and
  # the default is no (#1045).
  describe "evaluation gate" do
    setup do
      Application.delete_env(:raxol_core, :repl_exposed)
      System.delete_env("RAXOL_REPL_EXPOSED")
      :ok
    end

    test "is off when no deployment turned it on" do
      refute ReplDemo.evaluation_enabled?()
    end

    test "Enter reports the flag instead of evaluating" do
      model = ReplDemo.init(nil) |> type_string("x = 41 + 1")
      {model, _} = ReplDemo.update(key(:enter), model)

      output_text =
        Enum.map_join(model.output, "\n", fn {text, _kind} -> text end)

      assert output_text =~ "disabled"
      assert output_text =~ "RAXOL_REPL_EXPOSED"
      refute output_text =~ "42"
      # Nothing ran, so nothing bound.
      assert model.evaluator.bindings == []
    end

    test "the banner says so before anything is typed" do
      model = ReplDemo.init(nil)
      assert Enum.any?(model.output, fn {text, _} -> text =~ "disabled" end)
    end

    test "either the env var or the application key turns it on" do
      System.put_env("RAXOL_REPL_EXPOSED", "true")
      assert ReplDemo.evaluation_enabled?()
      System.delete_env("RAXOL_REPL_EXPOSED")

      Application.put_env(:raxol_core, :repl_exposed, true)
      assert ReplDemo.evaluation_enabled?()
      Application.delete_env(:raxol_core, :repl_exposed)
    end

    test "an unrecognised flag value leaves evaluation off" do
      for value <- ["1", "TRUE", "true ", "yes", ""] do
        System.put_env("RAXOL_REPL_EXPOSED", value)
        refute ReplDemo.evaluation_enabled?(), "#{inspect(value)} enabled it"
      end

      System.delete_env("RAXOL_REPL_EXPOSED")
      Application.put_env(:raxol_core, :repl_exposed, "true")
      refute ReplDemo.evaluation_enabled?()
      Application.delete_env(:raxol_core, :repl_exposed)
    end

    # `mix raxol.repl` is the operator's own terminal: the code runs as the
    # person who typed it, so it does not need the deployment flag.
    test "a direct local terminal launch evaluates without the flag" do
      context = %{options: [local_operator: true]}
      assert ReplDemo.evaluation_enabled?(context)

      model = ReplDemo.init(context) |> type_string("41 + 1")
      {model, _} = ReplDemo.update(key(:enter), model)

      output_text =
        Enum.map_join(model.output, "\n", fn {text, _kind} -> text end)

      assert output_text =~ "42"
      refute output_text =~ "disabled"
    end

    # The whole point of keying the opt-in on `:environment`: a served app's
    # own options must not be able to claim a local launch. SSH and LiveView
    # both set `:environment` ahead of any app-supplied options.
    test "a remote surface cannot grant itself the local opt-in" do
      for env <- [:ssh, :liveview, :telegram, :agent, :gateway] do
        context = %{options: [local_operator: true, environment: env]}

        refute ReplDemo.evaluation_enabled?(context),
               "#{inspect(env)} self-granted evaluation"

        model = ReplDemo.init(context) |> type_string("41 + 1")
        {model, _} = ReplDemo.update(key(:enter), model)

        output_text =
          Enum.map_join(model.output, "\n", fn {text, _kind} -> text end)

        assert output_text =~ "disabled"
        refute output_text =~ "42"
      end
    end

    test "the launch decision is fixed at init, not re-read per keystroke" do
      model = ReplDemo.init(nil)
      refute model.eval_allowed

      # A deployment flipped after this surface was already served must not
      # retroactively enable the session that was started closed.
      Application.put_env(:raxol_core, :repl_exposed, true)
      on_exit(fn -> Application.delete_env(:raxol_core, :repl_exposed) end)

      {model, _} = ReplDemo.update(key(:enter), type_string(model, "41 + 1"))

      output_text =
        Enum.map_join(model.output, "\n", fn {text, _kind} -> text end)

      assert output_text =~ "disabled"
      refute output_text =~ "42"
    end
  end
end
