# Drives the acpx (openclaw/acpx, MIT) v1 conformance corpus --
# `test/conformance/cases/*.json`, copied verbatim, see NOTICE.md -- through
# `Raxol.AgentClientProtocol.Test.Conformance.CaseRunner`. See that module's
# moduledoc for the step/check engine this ports, the fixture agent/client,
# and the compliance notes found while porting.
#
# `async: false`: every case starts its own `Agent`/`Client` connection
# pair, but they all share the ONE package-level `SessionRegistry` name
# (`Raxol.AgentClientProtocol.SessionRegistry`, `MIX_ENV=test`'s empty
# `RaxolAgentClientProtocol.Application` tree does not start it -- see
# `session_test.exs`'s identical `setup`), so two cases racing to
# `start_supervised!` it under the same fixed atom name would collide.
defmodule Raxol.AgentClientProtocol.Conformance.AcpxCasesTest do
  use ExUnit.Case, async: false
  use Raxol.AgentClientProtocol.Test.InvariantSentinel

  alias Raxol.AgentClientProtocol.Session.Supervisor, as: SessionSup
  alias Raxol.AgentClientProtocol.Test.Conformance.CaseRunner

  @cases_dir Path.join(__DIR__, "cases")

  # Cases whose scripted agent legitimately completes a non-empty prompt without
  # streaming a single `session/update`, tripping the ADR-0030 delivery guard
  # (`[:raxol, :acp, :zero_updates_turn]`). Declared per case instead of muted
  # module-wide, and `expect_invariant` asserts the event FIRES: if the fixture
  # starts streaming updates, this row fails and must be removed.
  @zero_update_cases %{
    # 019 awaits a backgrounded prompt whose only observable is the terminal
    # stopReason; the fixture agent streams nothing in between.
    "019-background-prompt-completes.json" => [[:raxol, :acp, :zero_updates_turn]]
  }

  setup do
    start_supervised!(SessionSup.registry_child_spec())
    :ok
  end

  @cases_dir
  |> Path.join("*.json")
  |> Path.wildcard()
  |> Enum.sort()
  |> Enum.each(fn case_path ->
    case_def = CaseRunner.load_case(case_path)
    case_id = case_def["id"] || Path.basename(case_path)

    @tag case_path: case_path
    case Map.fetch(@zero_update_cases, Path.basename(case_path)) do
      {:ok, events} -> @tag expect_invariant: events
      :error -> :ok
    end

    test "#{Path.basename(case_path)} (#{case_id}): #{case_def["title"]}", %{
      case_path: case_path
    } do
      case_def = CaseRunner.load_case(case_path)

      case CaseRunner.run(case_def) do
        :pass ->
          :ok

        {:fail, reason} ->
          flunk("""
          conformance case #{case_def["id"]} failed:

          #{reason}
          """)
      end
    end
  end)
end
