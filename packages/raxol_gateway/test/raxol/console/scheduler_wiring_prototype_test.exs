defmodule Raxol.Console.Scheduler.WiringPrototypeTest do
  @moduledoc """
  Stage-3 spike proof (Console runtime integration): a Console agent's scheduled
  task, wired via `Raxol.Console.Scheduler.Wiring`, runs a fresh agent turn that
  carries the soul.md persona and delivers its result to a messaging channel --
  end-to-end, against the real `Scheduler` / `Fire` / `Stream` / `Delivery` /
  gateway adapter. Only the LLM is a capture double at the external boundary.
  """
  use ExUnit.Case, async: true

  alias Raxol.Agent.Scheduler
  alias Raxol.Console.Scheduler.Wiring
  alias Raxol.Console.Test.CaptureBackend
  alias Raxol.Gateway.Adapter.InMemory

  @soul """
  # TestBot

  You are TestBot, the Console spike agent. Operate within your boundaries.
  """

  test "a scheduled fire carries the soul.md persona and delivers to a gateway channel" do
    sink = self()

    # The gateway's connected-adapters map the Console runtime owns. InMemory
    # forwards each outbound to `sink` as {:gateway_sent, route, rendered}.
    adapters = %{in_memory: {InMemory, %{sink: sink}}}

    opts =
      Wiring.scheduler_opts(%{
        adapters: adapters,
        system_prompt: @soul,
        # Persona-driven turn: capture backend records the system message and
        # returns a deterministic result. No executor pinned elsewhere, so this
        # backend is what the fire actually runs.
        agent_opts: [
          backend: CaptureBackend,
          backend_opts: [sink: sink, response: "SCHEDULED-OK-42"]
        ],
        # Synchronous dispatch makes the fire complete within Scheduler.run/2,
        # so the test observes both effects deterministically (no sleeps).
        dispatch: fn fire -> fire.() end
      })
      |> Keyword.merge(name: :console_proto_scheduler)

    start_supervised!({Scheduler, opts})

    {:ok, job} =
      Scheduler.create(:console_proto_scheduler, %{
        id: "daily-summary",
        prompt: "produce the daily summary",
        schedule: "every 1h",
        target: "in_memory:ops-channel"
      })

    assert job.id == "daily-summary"

    # Fire now, out of schedule.
    assert :ok = Scheduler.run(:console_proto_scheduler, "daily-summary")

    # 1) Persona reached the model: the fire's turn included the soul.md text as
    #    a system message (proves Fire.runner threaded :system_prompt through the
    #    Scheduler -> Fire -> Stream path).
    assert_receive {:backend_messages, messages}

    assert Enum.any?(messages, fn m ->
             m.role == :system and m.content =~ "TestBot"
           end),
           "expected the soul.md persona in the scheduled fire's system message, got: #{inspect(messages)}"

    assert Enum.any?(messages, fn m ->
             m.role == :user and m.content =~ "daily summary"
           end)

    # 2) The result was delivered to the agent's messaging channel via the
    #    gateway (proves Scheduler.Delivery.gateway routed the "platform:chat_id"
    #    target through Raxol.Gateway.Delivery).
    assert_receive {:gateway_sent, route, "SCHEDULED-OK-42"}
    assert route.platform == :in_memory
    assert route.chat_id == "ops-channel"
  end

  test "scheduler_opts omits :dispatch when none is supplied (scheduler default applies)" do
    opts = Wiring.scheduler_opts(%{adapters: %{in_memory: {InMemory, %{sink: self()}}}})

    assert Keyword.has_key?(opts, :runner)
    assert is_function(opts[:runner], 1)
    assert is_function(opts[:deliver], 2)
    refute Keyword.has_key?(opts, :dispatch)
  end
end
