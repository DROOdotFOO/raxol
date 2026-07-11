defmodule Raxol.Playground.Demos.ReplDemo do
  @moduledoc "Playground demo: interactive Elixir REPL with sandboxed evaluation."
  use Raxol.Core.Runtime.Application

  alias Raxol.REPL.{Evaluator, Sandbox}

  import Raxol.Playground.DemoHelpers,
    only: [history_prev: 1, history_next: 1, effective_width: 2]

  @visible_lines 14
  @default_box_width 70
  @box_height 16
  @max_history Raxol.Core.Defaults.history_limit()
  @eval_timeout Raxol.Core.Defaults.timeout_ms()
  @max_bindings 8
  @inspect_limit 5
  @inspect_width 30

  @impl true
  def init(_context) do
    %{
      input: "",
      cursor: 0,
      evaluator: Evaluator.new(),
      output: [
        {"# Raxol REPL -- type Elixir expressions, Enter to eval", :info}
      ],
      output_offset: 0,
      input_history: [],
      history_index: nil
    }
  end

  @impl true
  def update(message, model) do
    case message do
      key_match(:enter) ->
        {eval_input(model), []}

      key_match(:backspace) ->
        {delete_char(model), []}

      key_match("l", ctrl: true) ->
        {%{model | output: [], output_offset: 0}, []}

      key_match("u", ctrl: true) ->
        {%{model | input: "", cursor: 0}, []}

      key_match(:up) ->
        {history_prev(model), []}

      key_match(:down) ->
        {history_next(model), []}

      _ ->
        handle_repl_continued(message, model)
    end
  end

  defp handle_repl_continued(message, model) do
    case message do
      key_match("j", ctrl: true) ->
        {scroll_output(model, 1), []}

      key_match("k", ctrl: true) ->
        {scroll_output(model, -1), []}

      key_match(:char, char: ch) when byte_size(ch) == 1 ->
        {%{model | input: model.input <> ch, cursor: model.cursor + 1}, []}

      _ ->
        {model, []}
    end
  end

  defp delete_char(model) do
    input = String.slice(model.input, 0..-2//1)
    %{model | input: input, cursor: max(model.cursor - 1, 0)}
  end

  @impl true
  def view(model) do
    visible_output =
      model.output
      |> Enum.reverse()
      |> Enum.drop(model.output_offset)
      |> Enum.take(@visible_lines)
      |> Enum.map(fn {line, kind} -> output_line(line, kind) end)

    bindings_view = bindings_section(model.evaluator)

    column style: %{gap: 0} do
      [
        text("REPL", style: [:bold]),
        divider(),
        box style: %{
              border: :single,
              padding: 1,
              width: effective_width(model, @default_box_width),
              height: @box_height,
              # Eval output is arbitrary user code -- a long `inspect`
              # result can exceed the box width. `overflow: :hidden`
              # (docs/core/LAYOUT.md section 2, F1) clips it inside the
              # border instead of bleeding past it.
              overflow: :hidden
            } do
          column style: %{gap: 0} do
            if visible_output == [],
              do: [text("(empty)", style: [:dim])],
              else: visible_output
          end
        end,
        prompt_line(model),
        divider(),
        bindings_view,
        text(
          "[Enter] eval  [Up/Down] history  [Ctrl+L] clear  [Ctrl+U] clear input",
          style: [:dim]
        )
      ]
    end
  end

  @impl true
  def subscribe(_model), do: []

  # -- Eval --

  defp eval_input(%{input: ""} = model), do: model

  defp eval_input(model) do
    code = String.trim(model.input)

    # The playground is served anonymously over SSH, so the REPL demo runs at
    # the whitelist-only strict level -- never the default standard blocklist.
    case Sandbox.check(code, :strict) do
      :ok ->
        do_eval(model, code)

      {:error, violations} ->
        msg = "Sandbox: " <> Enum.join(violations, "; ")
        append_output(model, code, msg, :error)
    end
  end

  defp do_eval(model, code) do
    case Evaluator.eval(model.evaluator, code, timeout: @eval_timeout) do
      {:ok, result, new_eval} ->
        output_lines = format_result(result)
        new_history = [code | model.input_history] |> Enum.take(@max_history)

        model
        |> Map.put(:evaluator, new_eval)
        |> Map.put(:input, "")
        |> Map.put(:cursor, 0)
        |> Map.put(:history_index, nil)
        |> Map.put(:input_history, new_history)
        |> add_output_lines([{"> #{code}", :input} | output_lines])

      {:error, reason, _eval} ->
        append_output(model, code, reason, :error)
    end
  end

  defp append_output(model, code, message, kind) do
    lines = [{"> #{code}", :input}, {message, kind}]

    model
    |> Map.put(:input, "")
    |> Map.put(:cursor, 0)
    |> Map.put(:history_index, nil)
    |> add_output_lines(lines)
  end

  defp add_output_lines(model, lines) do
    new_output =
      Enum.reduce(lines, model.output, fn line, acc -> [line | acc] end)

    %{model | output: new_output, output_offset: 0}
  end

  defp format_result(result) do
    lines =
      if result.output != "" do
        result.output
        |> String.split("\n")
        |> Enum.map(fn l -> {"  #{l}", :io} end)
      else
        []
      end

    # credo:disable-for-next-line Credo.Check.Refactor.AppendSingleItem
    lines ++ [{"=> #{result.formatted}", :result}]
  end

  # history_prev/1 and history_next/1 imported from DemoHelpers

  # -- Scroll --

  defp scroll_output(model, delta) do
    max_offset = max(0, length(model.output) - @visible_lines)

    new_offset =
      Raxol.Core.Utils.Math.clamp(model.output_offset + delta, 0, max_offset)

    %{model | output_offset: new_offset}
  end

  # -- View helpers --

  defp output_line(line, :input), do: text(line, style: [:bold])
  defp output_line(line, :result), do: text(line, fg: :green)
  defp output_line(line, :io), do: text(line, fg: :cyan)
  defp output_line(line, :error), do: text(line, fg: :red)
  defp output_line(line, :info), do: text(line, style: [:dim])

  defp prompt_line(model) do
    row style: %{gap: 0} do
      [
        text("iex> ", style: [:bold], fg: :magenta),
        text(model.input <> "_")
      ]
    end
  end

  defp bindings_section(evaluator) do
    bindings = Evaluator.bindings(evaluator)

    if bindings == [] do
      text("Bindings: (none)", style: [:dim])
    else
      binding_strs =
        bindings
        |> Enum.take(@max_bindings)
        |> Enum.map(fn {name, value} ->
          val_str =
            inspect(value, limit: @inspect_limit, width: @inspect_width)
            |> String.slice(0..(@inspect_width - 1))

          "#{name}=#{val_str}"
        end)

      remaining = length(bindings) - @max_bindings
      suffix = if remaining > 0, do: " +#{remaining} more", else: ""

      text("Bindings: #{Enum.join(binding_strs, ", ")}#{suffix}", style: [:dim])
    end
  end
end
