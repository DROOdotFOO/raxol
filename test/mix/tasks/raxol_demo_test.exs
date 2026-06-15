defmodule Mix.Tasks.Raxol.DemoTest do
  use ExUnit.Case, async: true

  describe "demo modules" do
    test "counter init returns count 0" do
      assert Raxol.Demo.Counter.init(%{}) == %{count: 0}
    end

    test "counter update handles increment/decrement" do
      model = %{count: 0}
      assert {%{count: 1}, []} = Raxol.Demo.Counter.update(:increment, model)
      assert {%{count: -1}, []} = Raxol.Demo.Counter.update(:decrement, model)
      assert {%{count: 0}, []} = Raxol.Demo.Counter.update(:reset, %{count: 5})
    end

    test "counter update ignores unknown messages" do
      model = %{count: 0}
      assert {%{count: 0}, []} = Raxol.Demo.Counter.update(:unknown, model)
    end

    test "todo init returns default state" do
      model = Raxol.Demo.Todo.init(%{})
      assert length(model.todos) == 3
      assert model.cursor == 0
      assert model.mode == :normal
      assert model.input_buffer == ""
    end

    test "todo toggle_done works" do
      model = Raxol.Demo.Todo.init(%{})
      assert hd(model.todos).done == false

      event = %Raxol.Core.Events.Event{type: :key, data: %{key: :enter}}
      {model, []} = Raxol.Demo.Todo.update(event, model)
      assert hd(model.todos).done == true
    end

    test "todo navigation" do
      model = Raxol.Demo.Todo.init(%{})
      assert model.cursor == 0

      event = %Raxol.Core.Events.Event{type: :key, data: %{key: :char, char: "j"}}
      {model, []} = Raxol.Demo.Todo.update(event, model)
      assert model.cursor == 1

      event = %Raxol.Core.Events.Event{type: :key, data: %{key: :char, char: "k"}}
      {model, []} = Raxol.Demo.Todo.update(event, model)
      assert model.cursor == 0
    end

    test "todo input mode" do
      model = Raxol.Demo.Todo.init(%{})

      # Enter input mode
      event = %Raxol.Core.Events.Event{type: :key, data: %{key: :char, char: "a"}}
      {model, []} = Raxol.Demo.Todo.update(event, model)
      assert model.mode == :input

      # Type characters
      event = %Raxol.Core.Events.Event{type: :key, data: %{key: :char, char: "H"}}
      {model, []} = Raxol.Demo.Todo.update(event, model)
      event = %Raxol.Core.Events.Event{type: :key, data: %{key: :char, char: "i"}}
      {model, []} = Raxol.Demo.Todo.update(event, model)
      assert model.input_buffer == "Hi"

      # Submit
      event = %Raxol.Core.Events.Event{type: :key, data: %{key: :enter}}
      {model, []} = Raxol.Demo.Todo.update(event, model)
      assert model.mode == :normal
      assert length(model.todos) == 4
      assert List.last(model.todos).text == "Hi"
    end

    test "dashboard init returns valid state" do
      model = Raxol.Demo.Dashboard.init(%{})
      assert model.tick == 0
      assert model.panel == :runtime
      assert model.paused == false
      assert length(model.log) == 3
      assert length(model.mem_history) == 20
    end

    test "dashboard tick updates state" do
      model = Raxol.Demo.Dashboard.init(%{})
      {model, []} = Raxol.Demo.Dashboard.update(:tick, model)
      assert model.tick == 1
      assert model.log != []
    end

    test "dashboard panel navigation" do
      model = Raxol.Demo.Dashboard.init(%{})
      assert model.panel == :runtime

      event = %Raxol.Core.Events.Event{type: :key, data: %{key: :tab}}
      {model, []} = Raxol.Demo.Dashboard.update(event, model)
      assert model.panel == :schedulers

      event = %Raxol.Core.Events.Event{type: :key, data: %{key: :tab}}
      {model, []} = Raxol.Demo.Dashboard.update(event, model)
      assert model.panel == :log

      event = %Raxol.Core.Events.Event{type: :key, data: %{key: :tab}}
      {model, []} = Raxol.Demo.Dashboard.update(event, model)
      assert model.panel == :processes

      event = %Raxol.Core.Events.Event{type: :key, data: %{key: :tab}}
      {model, []} = Raxol.Demo.Dashboard.update(event, model)
      assert model.panel == :runtime
    end

    test "dashboard pause/resume" do
      model = Raxol.Demo.Dashboard.init(%{})
      assert model.paused == false

      event = %Raxol.Core.Events.Event{type: :key, data: %{key: :char, char: " "}}
      {model, []} = Raxol.Demo.Dashboard.update(event, model)
      assert model.paused == true

      # Tick should be ignored when paused
      {model, []} = Raxol.Demo.Dashboard.update(:tick, model)
      assert model.tick == 0
    end

    test "showcase init returns valid state" do
      model = Raxol.Demo.Showcase.init(%{})
      assert model.tab == 0
      assert model.checkbox_checked == false
      assert model.counter == 0
    end

    test "showcase tab switching with number keys" do
      model = Raxol.Demo.Showcase.init(%{})

      event = %Raxol.Core.Events.Event{type: :key, data: %{key: :char, char: "3"}}
      {model, []} = Raxol.Demo.Showcase.update(event, model)
      assert model.tab == 2

      event = %Raxol.Core.Events.Event{type: :key, data: %{key: :char, char: "1"}}
      {model, []} = Raxol.Demo.Showcase.update(event, model)
      assert model.tab == 0
    end

    test "showcase tab switching with Tab key" do
      model = Raxol.Demo.Showcase.init(%{})

      event = %Raxol.Core.Events.Event{type: :key, data: %{key: :tab}}
      {model, []} = Raxol.Demo.Showcase.update(event, model)
      assert model.tab == 1
    end

    test "showcase checkbox toggle on tab 1" do
      model = %{Raxol.Demo.Showcase.init(%{}) | tab: 1}

      event = %Raxol.Core.Events.Event{type: :key, data: %{key: :space}}
      {model, []} = Raxol.Demo.Showcase.update(event, model)
      assert model.checkbox_checked == true

      {model, []} = Raxol.Demo.Showcase.update(event, model)
      assert model.checkbox_checked == false
    end

    test "showcase counter on tab 3" do
      model = %{Raxol.Demo.Showcase.init(%{}) | tab: 3}

      event = %Raxol.Core.Events.Event{type: :key, data: %{key: :char, char: "="}}
      {model, []} = Raxol.Demo.Showcase.update(event, model)
      assert model.counter == 1

      event = %Raxol.Core.Events.Event{type: :key, data: %{key: :char, char: "-"}}
      {model, []} = Raxol.Demo.Showcase.update(event, model)
      assert model.counter == 0
    end
  end

  describe "all demos produce quit command on q" do
    for {name, module} <- [
          {"counter", Raxol.Demo.Counter},
          {"todo", Raxol.Demo.Todo},
          {"dashboard", Raxol.Demo.Dashboard},
          {"showcase", Raxol.Demo.Showcase}
        ] do
      test "#{name} quits on q" do
        module = unquote(module)
        model = module.init(%{})

        # For todo, ensure we're in normal mode
        model = Map.update(model, :mode, nil, fn _ -> :normal end)

        event = %Raxol.Core.Events.Event{type: :key, data: %{key: :char, char: "q"}}
        {_model, commands} = module.update(event, model)
        assert [%Raxol.Core.Runtime.Directive.Stop{}] = commands
      end
    end
  end

  describe "all demos produce valid view output" do
    for {name, module} <- [
          {"counter", Raxol.Demo.Counter},
          {"todo", Raxol.Demo.Todo},
          {"dashboard", Raxol.Demo.Dashboard},
          {"showcase", Raxol.Demo.Showcase}
        ] do
      test "#{name} view returns non-nil" do
        module = unquote(module)
        model = module.init(%{})
        view = module.view(model)
        assert view != nil
      end
    end
  end
end
