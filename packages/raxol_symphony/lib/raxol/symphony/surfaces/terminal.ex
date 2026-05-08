if Code.ensure_loaded?(Raxol.Core.Runtime.Application) do
  defmodule Raxol.Symphony.Surfaces.Terminal do
    @moduledoc """
    TEA dashboard surface for the Symphony orchestrator.

    Polls `Orchestrator.snapshot/1` on a fixed cadence (default 500ms) and
    renders the SPEC s13 status into terminal panes:

    - **Header bar** -- counts (running, retrying), generated-at timestamp,
      preflight error indicator.
    - **Active runs table** -- one row per running issue with state,
      turn count, last event, and runtime.
    - **Pending retries table** -- one row per scheduled retry with attempt
      number, due-in countdown, and last error.
    - **Help footer** -- key bindings.

    ## Key bindings

    | Key        | Action                                  |
    |------------|-----------------------------------------|
    | `q`, `Ctrl+C` | quit                                  |
    | `r`        | refresh tracker now (forces a tick)     |
    | `j`/`k`    | move selection in the active runs table |
    | `s`        | stop the selected run                   |
    | `?`        | toggle help overlay                     |

    ## Init context

    Pass via `start_link(..., context: %{orchestrator: <name_or_pid>})`. If
    omitted, the surface targets the registered `Raxol.Symphony.Orchestrator`.

    ## Decoupling from Lifecycle

    The pure-functional shape of the model lets `init/1`, `update/2`, and
    `view/1` be exercised without `Raxol.Core.Runtime.Lifecycle` in tests.
    See `test/raxol/symphony/surfaces/terminal_test.exs`.
    """

    use Raxol.Core.Runtime.Application

    alias Raxol.Symphony.Orchestrator

    @poll_ms 500

    # -- TEA callbacks --------------------------------------------------------

    @impl true
    def init(context) do
      orchestrator = Map.get(context, :orchestrator, Orchestrator)

      %{
        orchestrator: orchestrator,
        snapshot: safe_snapshot(orchestrator),
        selection: 0,
        help_visible?: false,
        last_action: nil,
        last_action_at: nil,
        tick: 0
      }
    end

    @impl true
    def update(message, model) do
      cond do
        message == :tick -> do_tick(model)
        message == {:symphony_event, :tick_completed, nil} -> do_tick(model)
        true -> handle_key(message, model)
      end
    end

    @impl true
    def subscribe(_model) do
      [subscribe_interval(@poll_ms, :tick)]
    end

    @impl true
    def view(model) do
      if model.help_visible? do
        help_overlay(model)
      else
        dashboard(model)
      end
    end

    # -- Public testing seam --------------------------------------------------

    @doc """
    Constructs the initial model with explicit overrides. Useful in tests
    that want to skip the live `safe_snapshot/1` lookup.
    """
    @spec build_model(keyword()) :: map()
    def build_model(opts) do
      %{
        orchestrator: Keyword.get(opts, :orchestrator, Orchestrator),
        snapshot: Keyword.get(opts, :snapshot, empty_snapshot()),
        selection: Keyword.get(opts, :selection, 0),
        help_visible?: Keyword.get(opts, :help_visible?, false),
        last_action: Keyword.get(opts, :last_action),
        last_action_at: Keyword.get(opts, :last_action_at),
        tick: Keyword.get(opts, :tick, 0)
      }
    end

    @doc "Empty snapshot for the cold-start path."
    @spec empty_snapshot() :: map()
    def empty_snapshot do
      %{
        generated_at: nil,
        counts: %{running: 0, retrying: 0},
        running: [],
        retrying: [],
        codex_totals: %{
          input_tokens: 0,
          output_tokens: 0,
          total_tokens: 0,
          seconds_running: 0.0
        },
        rate_limits: nil
      }
    end

    # -- Update helpers -------------------------------------------------------

    defp do_tick(model) do
      snapshot = safe_snapshot(model.orchestrator)
      selection = clamp_selection(model.selection, length(snapshot.running))
      {%{model | snapshot: snapshot, selection: selection, tick: model.tick + 1}, []}
    end

    defp handle_key(message, model) do
      case message do
        key_match("q") -> {model, [command(:quit)]}
        key_match("c", ctrl: true) -> {model, [command(:quit)]}
        key_match("r") -> handle_refresh(model)
        key_match("j") -> handle_scroll(model, +1)
        key_match("k") -> handle_scroll(model, -1)
        key_match("s") -> handle_stop_run(model)
        key_match("?") -> handle_toggle_help(model)
        _ -> {model, []}
      end
    end

    defp handle_refresh(model) do
      _ = safe_call(fn -> Orchestrator.refresh(model.orchestrator) end)
      {note_action(model, :refresh_requested), []}
    end

    defp handle_scroll(model, delta) do
      runs = length(model.snapshot.running)
      next = clamp_selection(model.selection + delta, runs)
      {%{model | selection: next}, []}
    end

    defp handle_stop_run(model) do
      case Enum.at(model.snapshot.running, model.selection) do
        nil ->
          {note_action(model, :no_run_selected), []}

        %{issue_id: id, issue_identifier: ident} ->
          _ = safe_call(fn -> Orchestrator.stop_run(model.orchestrator, id) end)
          {note_action(model, {:stopped, ident}), []}
      end
    end

    defp handle_toggle_help(model) do
      {%{model | help_visible?: not model.help_visible?}, []}
    end

    defp clamp_selection(_selection, 0), do: 0

    defp clamp_selection(selection, runs) when selection < 0,
      do: max(runs - 1, 0)

    defp clamp_selection(selection, runs) when selection >= runs,
      do: 0

    defp clamp_selection(selection, _runs), do: selection

    defp note_action(model, action) do
      %{model | last_action: action, last_action_at: System.system_time(:millisecond)}
    end

    defp safe_snapshot(orchestrator) do
      case safe_call(fn -> Orchestrator.snapshot(orchestrator) end) do
        {:ok, snap} when is_map(snap) -> snap
        _ -> empty_snapshot()
      end
    end

    defp safe_call(fun) do
      {:ok, fun.()}
    catch
      :exit, _ -> :error
      :error, _ -> :error
    end

    # -- View -----------------------------------------------------------------

    defp dashboard(model) do
      column style: %{padding: 0, gap: 0} do
        [
          header(model),
          spacer(size: 1),
          running_panel(model),
          spacer(size: 1),
          retrying_panel(model),
          spacer(size: 1),
          footer(model)
        ]
      end
    end

    defp header(model) do
      counts = model.snapshot.counts
      preflight = preflight_indicator(model)

      box style: %{border: :single, width: :fill, padding: 0} do
        row style: %{gap: 2, justify_content: :space_between} do
          [
            text("  symphony", style: [:bold], fg: :cyan),
            text("running #{counts.running}  retrying #{counts.retrying}",
              style: [:bold]
            ),
            text(preflight, fg: preflight_color(model)),
            text(generated_at_label(model), style: [:dim])
          ]
        end
      end
    end

    defp preflight_indicator(model) do
      case model.snapshot[:last_preflight_error] || nil do
        nil -> "preflight ok"
        reason -> "preflight: #{inspect(reason)}"
      end
    end

    defp preflight_color(model) do
      case model.snapshot[:last_preflight_error] do
        nil -> :green
        _ -> :red
      end
    end

    defp generated_at_label(model) do
      case model.snapshot.generated_at do
        nil -> "no data"
        ts when is_binary(ts) -> ts
        _ -> "?"
      end
    end

    defp running_panel(model) do
      box style: %{border: :single, width: :fill, padding: 1} do
        column style: %{gap: 0} do
          [
            text("Active runs (j/k to navigate, s to stop)",
              style: [:bold],
              fg: :cyan
            ),
            divider(char: "-")
            | running_rows(model)
          ]
        end
      end
    end

    defp running_rows(%{snapshot: %{running: []}}) do
      [text("  (no active runs)", style: [:dim])]
    end

    defp running_rows(model) do
      model.snapshot.running
      |> Enum.with_index()
      |> Enum.map(fn {entry, idx} -> running_row(entry, idx == model.selection) end)
    end

    defp running_row(entry, selected?) do
      marker = if selected?, do: ">", else: " "
      runtime = format_ms(entry.started_ms_ago)
      last_event = format_event(entry.last_event)

      text(
        "#{marker} #{pad(entry.issue_identifier, 8)} " <>
          "#{pad(entry.state, 14)} t=#{pad(to_string(entry.turn_count), 3)}  " <>
          "#{pad(last_event, 24)}  #{runtime}",
        fg: if(selected?, do: :yellow, else: :white)
      )
    end

    defp retrying_panel(model) do
      box style: %{border: :single, width: :fill, padding: 1} do
        column style: %{gap: 0} do
          [
            text("Pending retries", style: [:bold], fg: :cyan),
            divider(char: "-")
            | retrying_rows(model)
          ]
        end
      end
    end

    defp retrying_rows(%{snapshot: %{retrying: []}}) do
      [text("  (none)", style: [:dim])]
    end

    defp retrying_rows(model) do
      Enum.map(model.snapshot.retrying, &retrying_row/1)
    end

    defp retrying_row(entry) do
      text(
        "  #{pad(entry.issue_identifier, 8)} " <>
          "attempt=#{pad(to_string(entry.attempt), 2)}  " <>
          "due in #{pad(format_ms(entry.due_in_ms), 8)}  " <>
          "#{entry.error || ""}",
        fg: :magenta
      )
    end

    defp footer(model) do
      box style: %{border: :single, width: :fill, padding: 0} do
        row style: %{gap: 2, justify_content: :space_between} do
          [
            text("  q quit  r refresh  j/k navigate  s stop  ? help",
              style: [:dim]
            ),
            text(action_label(model), style: [:dim], fg: :green)
          ]
        end
      end
    end

    defp action_label(%{last_action: nil}), do: ""
    defp action_label(%{last_action: :refresh_requested}), do: "refresh requested"
    defp action_label(%{last_action: :no_run_selected}), do: "no run selected"
    defp action_label(%{last_action: {:stopped, ident}}), do: "stopped #{ident}"
    defp action_label(%{last_action: other}), do: inspect(other)

    defp help_overlay(_model) do
      box style: %{border: :double, padding: 2, width: :fill} do
        column style: %{gap: 1} do
          [
            text("Symphony dashboard help", style: [:bold], fg: :cyan),
            divider(char: "-"),
            text("q          quit"),
            text("Ctrl+C     quit"),
            text("r          force orchestrator tick now"),
            text("j / k      move selection up / down in active runs"),
            text("s          stop the selected run"),
            text("?          toggle this help overlay"),
            spacer(size: 1),
            text("Press '?' again to dismiss.", style: [:dim])
          ]
        end
      end
    end

    # -- Formatting -----------------------------------------------------------

    defp format_event(nil), do: "(no events yet)"
    defp format_event(atom) when is_atom(atom), do: Atom.to_string(atom)
    defp format_event(binary) when is_binary(binary), do: binary
    defp format_event(other), do: inspect(other)

    defp format_ms(ms) when is_integer(ms) and ms < 1_000, do: "#{ms}ms"
    defp format_ms(ms) when is_integer(ms) and ms < 60_000, do: "#{div(ms, 1000)}s"

    defp format_ms(ms) when is_integer(ms) do
      mins = div(ms, 60_000)
      secs = div(rem(ms, 60_000), 1000)
      "#{mins}m#{secs}s"
    end

    defp format_ms(_), do: "?"

    defp pad(s, width) when is_binary(s) do
      if byte_size(s) >= width do
        String.slice(s, 0, width)
      else
        s <> String.duplicate(" ", width - byte_size(s))
      end
    end
  end
end
