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

  # Sized for the deployment, not for a developer's laptop. This demo is the
  # only strict-sandbox caller and it is served anonymously over SSH, where the
  # playground allows 50 concurrent connections on a 1GB machine -- the
  # evaluator's own 64MB default would let a handful of sessions exhaust it
  # between them. Small enough that a session cannot hurt its neighbours;
  # generous for anything a REPL demo legitimately computes.
  @eval_max_heap_bytes 8 * 1024 * 1024
  @eval_max_output_bytes 256 * 1024
  @max_bindings 8
  @inspect_limit 5
  @inspect_width 30

  @disabled_message "Evaluation is disabled on this deployment. " <>
                      "The evaluator runs submitted code with the node's full " <>
                      "authority, so it is opt-in: set RAXOL_REPL_EXPOSED=true " <>
                      "(or config :raxol, :repl_exposed, true) on a node that " <>
                      "holds no keys."

  # Anonymous surfaces route straight to this demo: the playground's HTTP
  # gallery serves every catalog entry at `/demos/:demo` through the `:browser`
  # pipeline with no auth, and the SSH playground did the same before it was
  # suspended in August. Evaluation is therefore opt-in per deployment rather
  # than on by default (#1045).
  #
  # The flag is the one `Raxol.Payments.Deployment.assert_signing_isolated!/0`
  # already reads: turning this REPL on is exactly the condition that makes a
  # signing node refuse to boot, so the two halves of that rule can no longer
  # disagree about whether a deployment exposes an evaluator.
  @doc """
  Whether this deployment allows the playground REPL to evaluate code.

  Off unless `RAXOL_REPL_EXPOSED=true` or `config :raxol, :repl_exposed, true`.
  The demo renders either way; with evaluation off, Enter reports the flag
  rather than running the input.
  """
  @spec evaluation_enabled?() :: boolean()
  def evaluation_enabled? do
    System.get_env("RAXOL_REPL_EXPOSED") == "true" or
      Application.get_env(:raxol, :repl_exposed, false) == true
  end

  @impl true
  def init(_context) do
    %{
      input: "",
      cursor: 0,
      evaluator: Evaluator.new(),
      output: [{banner(), :info}],
      output_offset: 0,
      input_history: [],
      history_index: nil
    }
  end

  defp banner do
    if evaluation_enabled?() do
      "# Raxol REPL -- type Elixir expressions, Enter to eval"
    else
      "# Raxol REPL -- evaluation is disabled on this deployment"
    end
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

    if evaluation_enabled?() do
      check_and_eval(model, code)
    else
      append_output(model, code, @disabled_message, :error)
    end
  end

  defp check_and_eval(model, code) do
    # An enabled deployment still runs submitted code at the whitelist-only
    # strict level -- never the default standard blocklist.
    case Sandbox.check(code, :strict) do
      :ok ->
        do_eval(model, code)

      {:error, violations} ->
        msg = "Sandbox: " <> Enum.join(violations, "; ")
        append_output(model, code, msg, :error)
    end
  end

  # snippet:start
  defp do_eval(model, code) do
    case Evaluator.eval(model.evaluator, code,
           timeout: @eval_timeout,
           max_heap_bytes: @eval_max_heap_bytes,
           max_result_bytes: @eval_max_output_bytes
         ) do
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

  # snippet:end

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
