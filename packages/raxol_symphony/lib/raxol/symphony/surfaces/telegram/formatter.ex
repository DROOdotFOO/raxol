defmodule Raxol.Symphony.Surfaces.Telegram.Formatter do
  @moduledoc """
  Pure functions that turn Symphony orchestrator state into Telegram
  message bodies + inline keyboards.

  Returned shape: `{text, inline_keyboard}` where `text` is HTML-safe (uses
  Telegram's `parse_mode: "HTML"`) and `inline_keyboard` is a list of rows,
  each row a list of button maps with `text` and `callback_data` fields.

  ## Callback data convention

  All buttons use the `sym:<verb>[:<arg>]` namespace so a single bot router
  can dispatch:

  - `sym:refresh` -- request immediate orchestrator tick
  - `sym:list` -- request the full snapshot message
  - `sym:stop:<issue_id>` -- terminate the run for `issue_id`
  - `sym:run:<issue_id>` -- request the per-run detail message
  - `sym:resume:<issue_id>:approved` -- resume a paused run with approval
  - `sym:resume:<issue_id>:rejected` -- resume a paused run with rejection

  This keeps the surface decoupled from any specific bot framework.
  """

  @max_runs_displayed 8
  @max_retries_displayed 8
  @max_paused_displayed 8

  @type keyboard :: [[map()]]
  @type message :: {String.t(), keyboard()}

  # -- Snapshot summary -------------------------------------------------------

  @doc "Top-level snapshot message: counts + list of running + paused + retrying."
  @spec snapshot_message(map()) :: message()
  def snapshot_message(snapshot) when is_map(snapshot) do
    counts = Map.get(snapshot, :counts, %{running: 0, retrying: 0, paused: 0})
    running = take_n(Map.get(snapshot, :running, []), @max_runs_displayed)
    paused = take_n(Map.get(snapshot, :paused, []), @max_paused_displayed)
    retrying = take_n(Map.get(snapshot, :retrying, []), @max_retries_displayed)
    generated_at = Map.get(snapshot, :generated_at)
    paused_count = counts[:paused] || 0

    text =
      [
        "<b>Symphony</b>",
        "<i>#{escape(generated_at_label(generated_at))}</i>",
        "",
        "running: <b>#{counts.running}</b>  paused: <b>#{paused_count}</b>  " <>
          "retrying: <b>#{counts.retrying}</b>",
        "",
        running_section(running),
        paused_section(paused),
        retrying_section(retrying)
      ]
      |> Enum.reject(&(&1 == nil or &1 == ""))
      |> Enum.join("\n")

    keyboard = snapshot_keyboard(running, paused)
    {text, keyboard}
  end

  # -- Per-run message --------------------------------------------------------

  @doc "Detailed message for a single running entry."
  @spec run_message(map()) :: message()
  def run_message(run) when is_map(run) do
    text =
      [
        "<b>Run #{escape(run.issue_identifier)}</b>",
        "state: <code>#{escape(run.state)}</code>",
        "turns: <b>#{run.turn_count}</b>",
        "runtime: #{format_ms(run.started_ms_ago)}",
        "last event: <code>#{escape(format_event(run.last_event))}</code>"
      ]
      |> Enum.join("\n")

    keyboard = [
      [
        %{text: "Stop", callback_data: "sym:stop:#{run.issue_id}"},
        %{text: "Refresh", callback_data: "sym:list"}
      ]
    ]

    {text, keyboard}
  end

  @doc "Detailed message for a single paused entry, with Approve/Reject buttons."
  @spec paused_run_message(map()) :: message()
  def paused_run_message(entry) when is_map(entry) do
    reason = format_reason(entry[:interrupt_reason])
    paused_ago = format_ms(entry[:paused_ms_ago] || 0)

    text =
      [
        "<b>Paused #{escape(entry.issue_identifier)}</b>",
        "reason: <code>#{escape(reason)}</code>",
        "paused: #{paused_ago} ago",
        "last event: <code>#{escape(format_event(entry[:last_event]))}</code>",
        last_message_line(entry[:last_message])
      ]
      |> Enum.reject(&(&1 == nil or &1 == ""))
      |> Enum.join("\n")

    keyboard = [
      [
        %{
          text: "Approve",
          callback_data: "sym:resume:#{entry.issue_id}:approved"
        },
        %{
          text: "Reject",
          callback_data: "sym:resume:#{entry.issue_id}:rejected"
        }
      ],
      [%{text: "Refresh", callback_data: "sym:list"}]
    ]

    {text, keyboard}
  end

  defp last_message_line(nil), do: nil
  defp last_message_line(""), do: nil
  defp last_message_line(msg) when is_binary(msg), do: "<i>#{escape(msg)}</i>"
  defp last_message_line(_), do: nil

  # -- Event-specific messages ------------------------------------------------

  @doc """
  Renders a Symphony event into a Telegram-friendly message.

  Events recognised:

  - `:tick_completed` (no-op default; returns `:skip` so Notifier can suppress)
  - `:worker_exit_normal` -- run finished cleanly
  - `:worker_exit_abnormal` -- run crashed; will be retried
  - `:worker_stopped` -- run terminated by operator
  - `{:preflight_failed, reason}` -- workflow validation failed

  Returns `:skip` for events the surface intentionally drops, or `{text, keyboard}`.
  """
  @spec event_message(term(), map()) :: message() | :skip
  def event_message(:tick_completed, _snapshot), do: :skip

  def event_message(:worker_exit_normal, snapshot) do
    base =
      "<b>Symphony</b>\nA run completed normally.\n\n" <>
        counts_line(snapshot)

    {base,
     snapshot_keyboard(
       Map.get(snapshot, :running, []),
       Map.get(snapshot, :paused, [])
     )}
  end

  def event_message(:worker_exit_abnormal, snapshot) do
    base =
      "<b>Symphony</b>\n<b>A run failed.</b> See pending retries below.\n\n" <>
        counts_line(snapshot)

    {base,
     snapshot_keyboard(
       Map.get(snapshot, :running, []),
       Map.get(snapshot, :paused, [])
     )}
  end

  def event_message(:worker_stopped, snapshot) do
    {"<b>Symphony</b>\nA run was stopped by an operator.\n\n" <>
       counts_line(snapshot),
     snapshot_keyboard(
       Map.get(snapshot, :running, []),
       Map.get(snapshot, :paused, [])
     )}
  end

  def event_message(:worker_paused, snapshot) do
    paused = Map.get(snapshot, :paused, [])
    head = List.first(paused)

    body =
      if head do
        reason = format_reason(head[:interrupt_reason])

        "<b>Symphony</b>\n<b>A run is paused.</b> #{escape(head.issue_identifier)} -- " <>
          "<code>#{escape(reason)}</code>\n\n" <> counts_line(snapshot)
      else
        "<b>Symphony</b>\nA run is paused.\n\n" <> counts_line(snapshot)
      end

    keyboard =
      if head do
        [
          [
            %{
              text: "Approve #{head.issue_identifier}",
              callback_data: "sym:resume:#{head.issue_id}:approved"
            },
            %{
              text: "Reject",
              callback_data: "sym:resume:#{head.issue_id}:rejected"
            }
          ],
          [%{text: "Refresh", callback_data: "sym:refresh"}]
        ]
      else
        snapshot_keyboard(Map.get(snapshot, :running, []), paused)
      end

    {body, keyboard}
  end

  def event_message({:preflight_failed, reason}, _snapshot) do
    {"<b>Symphony preflight failed</b>\n<code>#{escape(inspect(reason))}</code>\n\n" <>
       "Dispatch is paused until the workflow is fixed.",
     [[%{text: "Refresh", callback_data: "sym:refresh"}]]}
  end

  def event_message(_other, _snapshot), do: :skip

  # -- Sections ---------------------------------------------------------------

  defp running_section([]), do: "<i>(no active runs)</i>"

  defp running_section(runs) do
    rows =
      Enum.map_join(runs, "\n", fn run ->
        "• #{escape(run.issue_identifier)} -- " <>
          "<code>#{escape(run.state)}</code> t=#{run.turn_count} " <>
          "(#{format_ms(run.started_ms_ago)})"
      end)

    "<b>Active runs</b>\n" <> rows
  end

  defp paused_section([]), do: nil

  defp paused_section(paused) do
    rows =
      Enum.map_join(paused, "\n", fn entry ->
        reason = format_reason(entry[:interrupt_reason])
        paused_ago = format_ms(entry[:paused_ms_ago] || 0)

        "• #{escape(entry.issue_identifier)} -- " <>
          "<code>#{escape(reason)}</code> paused #{paused_ago}"
      end)

    "\n<b>Paused</b>\n" <> rows
  end

  defp retrying_section([]), do: nil

  defp retrying_section(retries) do
    rows =
      Enum.map_join(retries, "\n", fn r ->
        "• #{escape(r.issue_identifier)} -- attempt #{r.attempt}, " <>
          "due in #{format_ms(r.due_in_ms)}"
      end)

    "\n<b>Pending retries</b>\n" <> rows
  end

  defp snapshot_keyboard(running, paused \\ []) do
    refresh = %{text: "Refresh", callback_data: "sym:refresh"}

    stop_buttons =
      running
      |> Enum.take(3)
      |> Enum.map(fn run ->
        %{
          text: "Stop #{run.issue_identifier}",
          callback_data: "sym:stop:#{run.issue_id}"
        }
      end)

    approve_buttons =
      paused
      |> Enum.take(3)
      |> Enum.map(fn entry ->
        %{
          text: "Approve #{entry.issue_identifier}",
          callback_data: "sym:resume:#{entry.issue_id}:approved"
        }
      end)

    [stop_buttons, approve_buttons, [refresh]]
    |> Enum.reject(&Enum.empty?/1)
  end

  # -- Helpers ----------------------------------------------------------------

  defp counts_line(snapshot) do
    counts = Map.get(snapshot, :counts, %{running: 0, retrying: 0, paused: 0})
    paused = counts[:paused] || 0

    "running: <b>#{counts.running}</b>  paused: <b>#{paused}</b>  " <>
      "retrying: <b>#{counts.retrying}</b>"
  end

  defp generated_at_label(nil), do: "no data yet"
  defp generated_at_label(s) when is_binary(s), do: s
  defp generated_at_label(_), do: "?"

  defp take_n(list, n) when is_list(list), do: Enum.take(list, n)
  defp take_n(_, _), do: []

  defp format_event(nil), do: "(no events)"
  defp format_event(atom) when is_atom(atom), do: Atom.to_string(atom)
  defp format_event(b) when is_binary(b), do: b
  defp format_event(other), do: inspect(other)

  defp format_reason(nil), do: "(unspecified)"
  defp format_reason(atom) when is_atom(atom), do: Atom.to_string(atom)
  defp format_reason(b) when is_binary(b), do: b
  defp format_reason(other), do: inspect(other)

  defp format_ms(ms) when is_integer(ms) and ms < 1_000, do: "#{ms}ms"

  defp format_ms(ms) when is_integer(ms) and ms < 60_000,
    do: "#{div(ms, 1000)}s"

  defp format_ms(ms) when is_integer(ms) do
    mins = div(ms, 60_000)
    secs = div(rem(ms, 60_000), 1000)
    "#{mins}m#{secs}s"
  end

  defp format_ms(_), do: "?"

  # Telegram HTML parse mode requires escaping <, >, &
  defp escape(nil), do: ""

  defp escape(value) when is_binary(value) do
    value
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
  end

  defp escape(value), do: value |> to_string() |> escape()
end
