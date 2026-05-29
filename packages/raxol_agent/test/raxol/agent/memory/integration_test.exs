defmodule Raxol.Agent.Memory.IntegrationTest do
  use ExUnit.Case, async: false

  alias Raxol.Agent.Memory.Record
  alias Raxol.Agent.Memory.Store.Ets, as: Store
  alias Raxol.Agent.Stream, as: AgentStream

  defmodule CaptureBackend do
    # Duck-typed backend: Stream.react only calls complete/2.
    def complete(messages, opts) do
      send(Keyword.fetch!(opts, :test_pid), {:captured, messages})

      {:ok,
       %{
         content: "done",
         usage: %{input_tokens: 0, output_tokens: 0},
         metadata: %{backend: :capture}
       }}
    end
  end

  setup do
    name = :"mem_int_#{System.unique_integer([:positive])}"
    start_supervised!(%{id: name, start: {Store, :start_link, [[name: name]]}})

    {:ok, _} =
      Store.store(
        Record.new(%{content: "the api key lives in 1password", agent_id: "a1"}),
        server: name
      )

    %{provider: {Store, [server: name, agent_id: "a1"]}}
  end

  defp run(opts) do
    "where is the api key"
    |> AgentStream.react(opts)
    |> Enum.to_list()
  end

  test "Stream.react injects recalled memory into the backend messages", %{provider: provider} do
    run(backend: CaptureBackend, backend_opts: [test_pid: self()], context: %{memory: provider})

    assert_receive {:captured, messages}, 1_000
    system = for m <- messages, Map.get(m, :role) == :system, do: m.content
    assert Enum.any?(system, &(&1 =~ "1password"))
  end

  test "no provider leaves messages free of a memory block" do
    run(backend: CaptureBackend, backend_opts: [test_pid: self()], context: %{})

    assert_receive {:captured, messages}, 1_000

    refute Enum.any?(messages, fn m ->
             Map.get(m, :role) == :system and m.content =~ "Relevant memory"
           end)
  end
end
