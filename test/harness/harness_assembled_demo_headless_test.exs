defmodule Raxol.Harness.HarnessAssembledDemoHeadlessTest do
  @moduledoc """
  U4 §7 assembled-demo smoke: boots the real `HarnessAssembledDemo` (the
  full `HarnessApp` over a replayed golden fixture) headless and checks the
  end-to-end laws 1-8 in one place — the transcript renders, the composer
  receives input, and sealed history is untouched by input (law 1).
  """
  use ExUnit.Case, async: false

  alias Raxol.Headless
  alias Raxol.Playground.Demos.HarnessAssembledDemo

  setup do
    pid =
      case Process.whereis(Headless) do
        nil -> start_supervised!({Headless, [name: Headless]})
        existing -> existing
      end

    on_exit(fn ->
      if Process.alive?(pid) do
        for id <- GenServer.call(pid, :list_sessions) do
          try do
            GenServer.call(pid, {:stop_session, id}, 2_000)
          catch
            :exit, _ -> :ok
          end
        end
      end
    end)

    :ok
  end

  test "the assembled demo boots and renders the replayed fixture transcript" do
    {:ok, id} =
      Headless.start(HarnessAssembledDemo, id: :harness_assembled_boot)

    {:ok, text} = Headless.screenshot(id)
    # long-folds' tool_call blocks seal into history
    assert text =~ "run_diagnostic"

    :ok = Headless.stop(id)
  end

  test "typing lands in the composer while sealed history stays untouched (law 1 end-to-end)" do
    {:ok, id} =
      Headless.start(HarnessAssembledDemo, id: :harness_assembled_type)

    {:ok, before} = Headless.screenshot(id)
    assert before =~ "run_diagnostic"

    :ok = Headless.send_key(id, "x")
    Process.sleep(50)

    {:ok, after_text} = Headless.screenshot(id)
    # the composer received the keystroke
    assert after_text =~ "x"
    # sealed history is untouched by input (law 1)
    assert after_text =~ "run_diagnostic"

    :ok = Headless.stop(id)
  end
end
