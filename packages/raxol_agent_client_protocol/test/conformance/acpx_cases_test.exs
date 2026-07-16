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

  alias Raxol.AgentClientProtocol.Session.Supervisor, as: SessionSup
  alias Raxol.AgentClientProtocol.Test.Conformance.CaseRunner

  @cases_dir Path.join(__DIR__, "cases")

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
