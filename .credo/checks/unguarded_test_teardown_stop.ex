defmodule Raxol.Credo.Check.Warning.UnguardedTestTeardownStop do
  @moduledoc false
  use Credo.Check,
    id: "RAXOL001",
    category: :warning,
    base_priority: :high,
    explanations: [
      check: """
      An `on_exit/1` teardown callback must not stop a process with an
      unguarded `GenServer.stop/1,2,3` (or `Supervisor.stop`,
      `DynamicSupervisor.stop`, `Agent.stop`).

      The process can exit on its own between the test body and the teardown
      callback, so the stop call exits with `** (EXIT) no process` and the test
      flakes. The race is widest on contended CI runners, where it shows up as a
      single non-deterministic failure that moves between files.

      Prefer `start_supervised!/1`, which hands the lifecycle to ExUnit and tears
      the process down after the test with no race:

          setup do
            pid = start_supervised!({MyServer, name: MyServer})
            %{server: pid}
          end

      When you genuinely must hand-manage the process, guard the stop:

          on_exit(fn ->
            try do
              GenServer.stop(pid)
            catch
              :exit, _ -> :ok
            end
          end)

      `Process.exit/2` is intentionally not flagged: it never raises, even when
      the target is already dead.
      """
    ]

  # OTP stop calls that exit when the target is not alive. `Process.exit/2` is
  # deliberately excluded because it returns `true` for a dead pid and so cannot
  # cause this flake.
  @stop_modules [:GenServer, :Supervisor, :DynamicSupervisor, :Agent]

  @impl true
  def run(%SourceFile{} = source_file, params) do
    issue_meta = IssueMeta.for(source_file, params)
    Credo.Code.prewalk(source_file, &traverse(&1, &2, issue_meta))
  end

  defp traverse({:on_exit, _meta, args} = ast, issues, issue_meta)
       when is_list(args) do
    case callback_body(args) do
      nil -> {ast, issues}
      body -> {ast, issues ++ unguarded_stop_issues(body, issue_meta)}
    end
  end

  defp traverse(ast, issues, _issue_meta), do: {ast, issues}

  # Supports on_exit(fn -> ... end) and on_exit(ref, fn -> ... end).
  defp callback_body(args) do
    case List.last(args) do
      {:fn, _, [{:->, _, [_params, body]}]} -> body
      _ -> nil
    end
  end

  defp unguarded_stop_issues(body, issue_meta) do
    guarded = guarded_stop_lines(body)

    body
    |> stop_lines()
    |> Enum.reject(&MapSet.member?(guarded, &1))
    |> Enum.sort()
    |> Enum.map(&issue_for(issue_meta, &1))
  end

  # Lines of stop calls that sit inside a try/catch (or try/rescue) and are
  # therefore already guarded against the no-process exit.
  defp guarded_stop_lines(body) do
    {_ast, lines} =
      Macro.prewalk(body, MapSet.new(), fn
        {:try, _, [clauses]} = node, acc when is_list(clauses) ->
          if Keyword.has_key?(clauses, :catch) or
               Keyword.has_key?(clauses, :rescue) do
            {node, MapSet.union(acc, MapSet.new(stop_lines(node)))}
          else
            {node, acc}
          end

        node, acc ->
          {node, acc}
      end)

    lines
  end

  defp stop_lines(ast) do
    {_ast, lines} =
      Macro.prewalk(ast, [], fn node, acc ->
        case stop_line(node) do
          nil -> {node, acc}
          line -> {node, [line | acc]}
        end
      end)

    lines
  end

  defp stop_line({{:., _, [{:__aliases__, _, mods}, :stop]}, meta, _args}) do
    if List.last(mods) in @stop_modules, do: meta[:line], else: nil
  end

  defp stop_line(_node), do: nil

  defp issue_for(issue_meta, line) do
    format_issue(
      issue_meta,
      message:
        "Unguarded process stop in on_exit/1 will flake; " <>
          "use start_supervised!/1 or guard the stop with try/catch :exit.",
      line_no: line
    )
  end
end
