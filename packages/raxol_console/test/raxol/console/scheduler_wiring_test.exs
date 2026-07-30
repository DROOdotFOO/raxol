defmodule Raxol.Console.Scheduler.WiringTest do
  @moduledoc """
  A Console agent's scheduled task, wired via `Raxol.Console.Scheduler.Wiring`,
  runs a fresh agent turn carrying the soul.md persona and delivers its result
  to a messaging channel -- end-to-end against the real `Scheduler` / `Fire` /
  `Stream` / `Delivery` / gateway adapter. Only the LLM is a capture double.
  """
  use ExUnit.Case, async: true

  alias Raxol.Agent.Scheduler
  alias Raxol.Console.Scheduler.Wiring
  alias Raxol.Console.Test.CaptureBackend
  alias Raxol.Gateway.Adapter.InMemory

  @soul "# TestBot\n\nYou are TestBot, the Console runtime agent."

  test "a scheduled fire carries the persona and delivers to a gateway channel" do
    sink = self()
    adapters = %{in_memory: {InMemory, %{sink: sink}}}

    opts =
      Wiring.scheduler_opts(%{
        adapters: adapters,
        system_prompt: @soul,
        agent_opts: [
          backend: CaptureBackend,
          backend_opts: [sink: sink, response: "SCHEDULED-OK"]
        ],
        dispatch: fn fire -> fire.() end
      })
      |> Keyword.merge(name: :console_wiring_scheduler)

    start_supervised!({Scheduler, opts})

    {:ok, _job} =
      Scheduler.create(:console_wiring_scheduler, %{
        id: "daily",
        prompt: "produce the daily summary",
        schedule: "every 1h",
        target: "in_memory:ops"
      })

    assert :ok = Scheduler.run(:console_wiring_scheduler, "daily")

    assert_receive {:backend_messages, messages}
    assert Enum.any?(messages, &(&1.role == :system and &1.content =~ "TestBot"))

    assert_receive {:gateway_sent, route, "SCHEDULED-OK"}
    assert route.platform == :in_memory
    assert route.chat_id == "ops"
  end

  test "omits :dispatch when none is supplied" do
    opts = Wiring.scheduler_opts(%{adapters: %{in_memory: {InMemory, %{sink: self()}}}})

    assert is_function(opts[:runner], 1)
    assert is_function(opts[:deliver], 2)
    refute Keyword.has_key?(opts, :dispatch)
  end
end
