defmodule Raxol.Playground.Demos.ReplDemo do
  @moduledoc """
  Playground demo: AST-checked interactive Elixir REPL.

  Evaluation runs submitted code with the node's full authority and is opt-in
  per deployment (`Raxol.Core.Boundary.Evaluation`). `Raxol.REPL.Sandbox` runs
  in front of it, but that checker is a mitigation, not a trust boundary: see
  `check_and_eval/2`.
  """
  use Raxol.Core.Runtime.Application

  alias Raxol.Core.Boundary.Evaluation
  alias Raxol.REPL.{Evaluator, Sandbox}

  import Raxol.Playground.DemoHelpers,
    only: [history_prev: 1, history_next: 1, effective_width: 2]

  @visible_lines 14
  @default_box_width 70
  @box_height 16
  @max_history Raxol.Core.Defaults.history_limit()
  @eval_timeout Raxol.Core.Defaults.timeout_ms()

  # The level every served launch gets: whitelist-only, never `Sandbox`'s own
  # `:standard` blocklist default. Only a direct local terminal launch may ask
  # for a different one (see `sandbox_level/2`), because a level relaxed for
  # one operator's own terminal must not be able to follow an anonymously
  # served surface.
  @default_sandbox_level :strict

  # Sized for the deployment, not for a developer's laptop. An enabled
  # deployment may serve this demo over SSH, where the playground allows 50
  # concurrent connections on a 1GB machine -- the evaluator's own 64MB default
  # would let a handful of sessions exhaust it between them. Small enough that
  # a session cannot hurt its neighbours; generous for anything a REPL demo
  # legitimately computes.
  @eval_max_heap_bytes 8 * 1024 * 1024
  @eval_max_output_bytes 256 * 1024
  @max_bindings 8
  @inspect_limit 5
  @inspect_width 30

  @disabled_message "Evaluation is disabled on this deployment. " <>
                      "The evaluator runs submitted code with the node's full " <>
                      "authority, so it is opt-in: set " <>
                      Evaluation.env_var() <>
                      "=true (or config :raxol_core, :repl_exposed, true) on " <>
                      "a node that holds no keys."

  # Anonymous surfaces route straight to this demo: the playground's HTTP
  # gallery serves every catalog entry at `/demos/:demo` through the `:browser`
  # pipeline with no auth, and the SSH playground did the same before it was
  # suspended in August. Evaluation is therefore opt-in per deployment rather
  # than on by default (#1045).
  #
  # The deployment flag is `Raxol.Core.Boundary.Evaluation.exposed?/0`, which
  # is also the flag `Raxol.Payments.Deployment.assert_signing_isolated!/0`
  # reads. Turning this REPL on is therefore exactly the condition that makes
  # a signing node refuse to boot; the two halves of that rule read one
  # predicate and cannot disagree.
  #
  # A direct local launch (`mix raxol.repl`) is the one case that does not need
  # the deployment flag: the operator started the evaluator in their own
  # terminal, so they are already the authority it would run as. That opt-in is
  # accepted ONLY at `environment: :terminal`. It cannot be self-granted by a
  # remote surface: `Raxol.SSH.Session.lifecycle_opts/4` places
  # `environment: :ssh` ahead of the served app's `:app_opts`/`:tenant_opts`
  # precisely so a served app cannot shadow it, and the web gallery starts
  # every demo with `environment: :liveview`.
  @doc """
  Whether this launch of the REPL demo may evaluate code.

  True when the deployment opted in (`RAXOL_REPL_EXPOSED=true` or
  `config :raxol_core, :repl_exposed, true`), or when a local terminal launch
  passed `local_operator: true`. The demo renders either way; with evaluation
  off, Enter reports the flag rather than running the input.
  """
  @spec evaluation_enabled?(map() | nil) :: boolean()
  def evaluation_enabled?(context \\ nil) do
    Evaluation.exposed?() or local_operator_launch?(context)
  end

  defp local_operator_launch?(%{options: options}) when is_list(options) do
    Keyword.get(options, :local_operator, false) == true and
      Keyword.get(options, :environment, :terminal) == :terminal
  end

  defp local_operator_launch?(_context), do: false

  @impl true
  def init(context) do
    # Decided once, at launch. Re-reading process-global state per keystroke
    # would let a mid-session config change flip an already-served surface.
    eval_allowed = evaluation_enabled?(context)
    local = local_operator_launch?(context)
    opts = context_options(context)

    %{
      input: "",
      cursor: 0,
      evaluator: Evaluator.new(),
      eval_allowed: eval_allowed,
      sandbox_level: sandbox_level(opts, local),
      eval_timeout: eval_timeout(opts, local),
      output: [{banner(eval_allowed), :info}],
      output_offset: 0,
      input_history: [],
      history_index: nil
    }
  end

  defp banner(true),
    do: "# Raxol REPL -- type Elixir expressions, Enter to eval"

  defp banner(false),
    do: "# Raxol REPL -- evaluation is disabled on this deployment"

  # `mix raxol.repl`'s `--sandbox` and `--timeout` arrive here: options given
  # to `Raxol.start_link/2` reach `init/1` in the runtime's context map. Read
  # per instance rather than from application env, because the playground
  # starts this demo with `init(nil)`.
  defp context_options(%{options: options}) when is_list(options), do: options
  defp context_options(_context), do: []

  # Only a direct local terminal launch may move these. A served app supplies
  # its own options too (`Raxol.SSH.Server`'s `:app_opts` and `:tenant_opts`
  # land in the same list), so honouring `:sandbox` unconditionally would let
  # an anonymously served surface ask for `:none`, and honouring `:timeout`
  # would let it hold a scheduler for as long as it liked. The
  # `local_operator_launch?/1` gate is the same one evaluation itself uses.
  defp sandbox_level(opts, true) do
    case Keyword.get(opts, :sandbox) do
      level when level in [:none, :standard, :strict] -> level
      _ -> @default_sandbox_level
    end
  end

  defp sandbox_level(_opts, false), do: @default_sandbox_level

  defp eval_timeout(opts, true) do
    case Keyword.get(opts, :timeout) do
      ms when is_integer(ms) and ms > 0 -> ms
      _ -> @eval_timeout
    end
  end

  defp eval_timeout(_opts, false), do: @eval_timeout

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

  defp eval_input(%{eval_allowed: false} = model) do
    append_output(model, String.trim(model.input), @disabled_message, :error)
  end

  defp eval_input(model), do: check_and_eval(model, String.trim(model.input))

  # `model.sandbox_level` is `@default_sandbox_level` for every served launch
  # and whatever `mix raxol.repl --sandbox` asked for on a local terminal.
  #
  # Whichever level it is, this checker is a MITIGATION, not the trust
  # boundary. Every clause in it decides safety from a module NAME, while
  # `import`, `alias`, `require` and `use` decide which module a name reaches,
  # so they sit underneath the check: at `:strict`, `import System; cmd(...)`,
  # `alias :os, as: Enum` and the bare-name capture forms of `apply`/`spawn`
  # all pass (asserted in `test/raxol/repl/sandbox_test.exs`). What keeps an
  # anonymous caller away from the evaluator is the deployment flag, not this;
  # the check only raises the cost of the obvious attempts. Do not enable
  # evaluation on a node whose authority matters.
  defp check_and_eval(model, code) do
    case Sandbox.check(code, model.sandbox_level) do
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
           timeout: model.eval_timeout,
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
