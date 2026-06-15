defmodule Mix.Raxol.AppTemplates do
  @moduledoc """
  TEA module source templates for `mix raxol.new`.

  Each function returns the source code for a generated app module.
  """

  @spec render(String.t(), map()) :: String.t()
  def render(template, bindings)

  def render("blank", %{app: app, module: module}) do
    """
    defmodule #{module} do
      @moduledoc \"\"\"
      A Raxol application.

      Run with: mix run lib/#{app}.ex
      \"\"\"

      use Raxol.Core.Runtime.Application

      @impl true
      def init(_context), do: %{}

      @impl true
      def update(message, model) do
        case message do
          %Raxol.Core.Events.Event{type: :key, data: %{key: :char, char: "q"}} ->
            {model, [Directive.stop()]}

          %Raxol.Core.Events.Event{type: :key, data: %{key: :char, char: "c", ctrl: true}} ->
            {model, [Directive.stop()]}

          _ ->
            {model, []}
        end
      end

      @impl true
      def view(_model) do
        column style: %{padding: 1, align_items: :center} do
          text("#{module} -- edit this view!", style: [:bold])
        end
      end

      @impl true
      def subscribe(_model), do: []
    end
    """
  end

  def render("counter", %{app: app, module: module}) do
    """
    defmodule #{module} do
      @moduledoc \"\"\"
      A Raxol counter application using The Elm Architecture (TEA).

      Run with: mix run lib/#{app}.ex
      \"\"\"

      use Raxol.Core.Runtime.Application

      @impl true
      def init(_context), do: %{count: 0}

      @impl true
      def update(message, model) do
        case message do
          :increment -> {%{model | count: model.count + 1}, []}
          :decrement -> {%{model | count: model.count - 1}, []}

          %Raxol.Core.Events.Event{type: :key, data: %{key: :char, char: "="}} ->
            {%{model | count: model.count + 1}, []}

          %Raxol.Core.Events.Event{type: :key, data: %{key: :char, char: "-"}} ->
            {%{model | count: model.count - 1}, []}

          %Raxol.Core.Events.Event{type: :key, data: %{key: :char, char: "q"}} ->
            {model, [Directive.stop()]}

          %Raxol.Core.Events.Event{type: :key, data: %{key: :char, char: "c", ctrl: true}} ->
            {model, [Directive.stop()]}

          _ -> {model, []}
        end
      end

      @impl true
      def view(model) do
        column style: %{padding: 1, gap: 1, align_items: :center} do
          [
            text("#{module}", style: [:bold]),
            box style: %{padding: 1, border: :single, width: 20, justify_content: :center} do
              text("Count: \#{model.count}", style: [:bold])
            end,
            row style: %{gap: 1} do
              [
                button("=", on_click: :increment),
                button("-", on_click: :decrement)
              ]
            end,
            text("Press '='/'-' or click buttons. 'q' to quit.")
          ]
        end
      end

      @impl true
      def subscribe(_model), do: []
    end
    """
  end

  def render("todo", %{app: app, module: module}) do
    """
    defmodule #{module} do
      @moduledoc \"\"\"
      A Raxol todo application using The Elm Architecture (TEA).

      Run with: mix run lib/#{app}.ex
      \"\"\"

      use Raxol.Core.Runtime.Application

      defmodule Todo do
        defstruct [:id, :text, done: false]
      end

      @impl true
      def init(_context) do
        %{todos: [], input: "", next_id: 1, selected: 0, mode: :normal}
      end

      @impl true
      def update(message, model) do
        case message do
          {:input_char, char} when model.mode == :input ->
            {%{model | input: model.input <> char}, []}

          :input_backspace when model.mode == :input ->
            {%{model | input: String.slice(model.input, 0..-2//1)}, []}

          :input_submit when model.mode == :input and model.input != "" ->
            todo = %Todo{id: model.next_id, text: model.input}
            {%{model | todos: model.todos ++ [todo], input: "", next_id: model.next_id + 1, mode: :normal}, []}

          :input_cancel -> {%{model | input: "", mode: :normal}, []}
          :start_input -> {%{model | mode: :input}, []}
          :move_up -> {%{model | selected: max(0, model.selected - 1)}, []}
          :move_down -> {%{model | selected: min(length(model.todos) - 1, model.selected)}, []}

          :toggle_done ->
            todos = model.todos |> Enum.with_index() |> Enum.map(fn {t, i} ->
              if i == model.selected, do: %{t | done: !t.done}, else: t
            end)
            {%{model | todos: todos}, []}

          :delete_todo ->
            todos = List.delete_at(model.todos, model.selected)
            {%{model | todos: todos, selected: min(model.selected, max(0, length(todos) - 1))}, []}

          %Raxol.Core.Events.Event{type: :key, data: %{key: :char, char: "q"}} when model.mode == :normal ->
            {model, [Directive.stop()]}

          %Raxol.Core.Events.Event{type: :key, data: %{key: :char, char: "c", ctrl: true}} ->
            {model, [Directive.stop()]}

          %Raxol.Core.Events.Event{type: :key, data: %{key: :char, char: "a"}} when model.mode == :normal ->
            update(:start_input, model)

          %Raxol.Core.Events.Event{type: :key, data: %{key: :char, char: "d"}} when model.mode == :normal ->
            update(:delete_todo, model)

          %Raxol.Core.Events.Event{type: :key, data: %{key: :char, char: " "}} when model.mode == :normal ->
            update(:toggle_done, model)

          %Raxol.Core.Events.Event{type: :key, data: %{key: :up}} when model.mode == :normal ->
            update(:move_up, model)

          %Raxol.Core.Events.Event{type: :key, data: %{key: :down}} when model.mode == :normal ->
            update(:move_down, model)

          %Raxol.Core.Events.Event{type: :key, data: %{key: :enter}} when model.mode == :input ->
            update(:input_submit, model)

          %Raxol.Core.Events.Event{type: :key, data: %{key: :escape}} ->
            update(:input_cancel, model)

          %Raxol.Core.Events.Event{type: :key, data: %{key: :backspace}} when model.mode == :input ->
            update(:input_backspace, model)

          %Raxol.Core.Events.Event{type: :key, data: %{key: :char, char: ch}} when model.mode == :input ->
            update({:input_char, ch}, model)

          _ -> {model, []}
        end
      end

      @impl true
      def view(model) do
        column style: %{padding: 1, gap: 1} do
          [
            text("Todo List", style: [:bold]),
            box style: %{border: :single, padding: 1, width: 40} do
              column style: %{gap: 0} do
                if model.todos == [] do
                  text("No todos yet. Press 'a' to add one.")
                else
                  Enum.with_index(model.todos)
                  |> Enum.map(fn {todo, i} ->
                    prefix = if i == model.selected, do: "> ", else: "  "
                    check = if todo.done, do: "[x] ", else: "[ ] "
                    style = if todo.done, do: [:dim], else: []
                    text(prefix <> check <> todo.text, style: style)
                  end)
                end
              end
            end,
            if model.mode == :input do
              row do
                [text("New: "), text(model.input <> "_", style: [:underline])]
              end
            else
              text("a:add  space:toggle  d:delete  up/down:move  q:quit", style: [:dim])
            end
          ]
        end
      end

      @impl true
      def subscribe(_model), do: []
    end
    """
  end

  @supported_templates ~w(blank counter todo dashboard)

  def render(template, _bindings) when template not in @supported_templates do
    raise ArgumentError,
          "unknown template #{inspect(template)}, expected one of: #{inspect(@supported_templates)}"
  end

  def render("dashboard", %{app: app, module: module}) do
    """
    defmodule #{module} do
      @moduledoc \"\"\"
      A Raxol dashboard application using The Elm Architecture (TEA).

      Run with: mix run lib/#{app}.ex
      \"\"\"

      use Raxol.Core.Runtime.Application

      @impl true
      def init(_context) do
        %{
          active_panel: 0,
          panels: ["System", "Logs", "Stats"],
          logs: ["App started", "Listening on port 4000", "Connected to database"],
          stats: %{uptime: 0, requests: 0, memory_mb: 42},
          tick: 0
        }
      end

      @impl true
      def update(message, model) do
        case message do
          :next_panel ->
            {%{model | active_panel: rem(model.active_panel + 1, length(model.panels))}, []}

          :prev_panel ->
            {%{model | active_panel: rem(model.active_panel - 1 + length(model.panels), length(model.panels))}, []}

          :tick ->
            stats = %{model.stats | uptime: model.stats.uptime + 1, requests: model.stats.requests + Enum.random(0..5)}
            {%{model | stats: stats, tick: model.tick + 1}, []}

          %Raxol.Core.Events.Event{type: :key, data: %{key: :char, char: "q"}} ->
            {model, [Directive.stop()]}

          %Raxol.Core.Events.Event{type: :key, data: %{key: :char, char: "c", ctrl: true}} ->
            {model, [Directive.stop()]}

          %Raxol.Core.Events.Event{type: :key, data: %{key: :tab}} ->
            update(:next_panel, model)

          %Raxol.Core.Events.Event{type: :key, data: %{key: :char, char: "h"}} ->
            update(:prev_panel, model)

          %Raxol.Core.Events.Event{type: :key, data: %{key: :char, char: "l"}} ->
            update(:next_panel, model)

          _ -> {model, []}
        end
      end

      @impl true
      def view(model) do
        column style: %{padding: 1, gap: 1} do
          [
            row style: %{gap: 2} do
              Enum.with_index(model.panels)
              |> Enum.map(fn {name, i} ->
                style = if i == model.active_panel, do: [:bold, :underline], else: [:dim]
                text(name, style: style)
              end)
            end,
            render_panel(model),
            text("Tab/h/l:switch panels  q:quit", style: [:dim])
          ]
        end
      end

      defp render_panel(%{active_panel: 0} = model) do
        box style: %{border: :single, padding: 1, width: 50} do
          column style: %{gap: 1} do
            [
              text("System Info", style: [:bold]),
              text("Uptime: \#{model.stats.uptime}s"),
              text("Memory: \#{model.stats.memory_mb} MB"),
              text("Elixir: \#{System.version()}"),
              text("OTP: \#{:erlang.system_info(:otp_release)}")
            ]
          end
        end
      end

      defp render_panel(%{active_panel: 1} = model) do
        box style: %{border: :single, padding: 1, width: 50} do
          column style: %{gap: 0} do
            [text("Recent Logs", style: [:bold]) |
              Enum.map(model.logs, fn log -> text("  " <> log, style: [:dim]) end)]
          end
        end
      end

      defp render_panel(%{active_panel: _} = model) do
        box style: %{border: :single, padding: 1, width: 50} do
          column style: %{gap: 1} do
            [
              text("Stats", style: [:bold]),
              text("Requests: \#{model.stats.requests}"),
              row style: %{gap: 0} do
                bar = String.duplicate("#", min(model.stats.requests, 30))
                text("[" <> bar <> "]")
              end
            ]
          end
        end
      end

      @impl true
      def subscribe(_model) do
        [subscribe_interval(1000, :tick)]
      end
    end
    """
  end
end
