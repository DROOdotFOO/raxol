defmodule Raxol.Playground.Demos.ReplDemoTest do
  use ExUnit.Case, async: true

  alias Raxol.Playground.Demos.ReplDemo

  defp key(char) when is_binary(char) do
    %Raxol.Core.Events.Event{type: :key, data: %{key: :char, char: char}}
  end

  defp key(special) when is_atom(special) do
    %Raxol.Core.Events.Event{type: :key, data: %{key: special}}
  end

  defp ctrl_key(char) do
    %Raxol.Core.Events.Event{type: :key, data: %{key: :char, char: char, ctrl: true}}
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

    test "uses explicit per-launch sandbox and timeout options" do
      for sandbox <- [:none, :standard, :strict] do
        model =
          ReplDemo.init(%{
            options: [sandbox: sandbox, timeout: 250]
          })

        assert model.sandbox_level == sandbox
        assert model.eval_timeout == 250
      end
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
end
