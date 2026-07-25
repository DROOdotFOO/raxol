defmodule Raxol.Agent.Scheduler.FireTest.CapturingBackend do
  @moduledoc "An AIBackend that records the messages it receives, for fire inspection."
  @behaviour Raxol.Agent.AIBackend

  @impl true
  def complete(messages, opts) do
    send(Keyword.fetch!(opts, :collector), {:messages, messages})

    {:ok,
     %{
       content: Keyword.get(opts, :response, "done"),
       usage: %{input_tokens: 0, output_tokens: 0},
       metadata: %{backend: :capturing}
     }}
  end

  @impl true
  def stream(messages, opts) do
    {:ok, response} = complete(messages, opts)
    {:ok, [{:chunk, response.content}, {:done, response}]}
  end

  @impl true
  def available?, do: true
  @impl true
  def name, do: "Capturing Backend"
  @impl true
  def capabilities, do: [:completion, :tool_use]
end

defmodule Raxol.Agent.Scheduler.FireTest.RecordContext do
  @moduledoc "An action that reports the run context's in_cron flag to a collector."
  use Raxol.Agent.Action,
    name: "record_ctx",
    description: "records the in_cron flag",
    schema: [input: [], output: []]

  @impl true
  def run(_params, context) do
    send(Map.fetch!(context, :collector), {:in_cron, Map.get(context, :in_cron)})
    {:ok, %{}}
  end
end

defmodule Raxol.Agent.Scheduler.FireTest do
  use ExUnit.Case, async: false

  alias Raxol.Agent.Scheduler.Fire
  alias Raxol.Agent.Scheduler.FireTest.CapturingBackend
  alias Raxol.Agent.Scheduler.FireTest.RecordContext
  alias Raxol.Agent.Skills

  defp capturing_opts(extra \\ []) do
    [agent_opts: [backend: CapturingBackend, backend_opts: [collector: self()] ++ extra]]
  end

  describe "run/2" do
    test "returns the backend's rendered content" do
      assert {:ok, "the answer"} =
               Fire.run(%{prompt: "q", skills: []}, capturing_opts(response: "the answer"))

      assert_receive {:messages, _}
    end

    test "each fire is history-free: no turn accumulates onto the next" do
      job = %{prompt: "hello", skills: []}

      {:ok, _} = Fire.run(job, capturing_opts())
      assert_receive {:messages, first}

      {:ok, _} = Fire.run(job, capturing_opts())
      assert_receive {:messages, second}

      # Both fires send the identical single user turn -- the second does not
      # carry the first's assistant reply.
      assert first == second
      assert [%{role: :user, content: "hello"}] = user_turns(first)
      refute Enum.any?(first, &(&1.role == :assistant))
    end

    test "injects the job's skills as a system prompt" do
      store = start_skills_store()

      {:ok, _} =
        Skills.Store.create(%{name: "greet", description: "d", body: "Always say hi."},
          server: store
        )

      {:ok, _} = Fire.run(%{prompt: "p", skills: ["greet"]}, capturing_opts() ++ [skills: store])

      assert_receive {:messages, messages}
      system = Enum.find(messages, &(&1.role == :system))
      assert system
      assert system.content =~ "Always say hi."
      assert system.content =~ "greet"
    end

    test "runs without skills when the skills store is unavailable" do
      # No store started under this name: fetching the skill fails, and the fire
      # still runs its prompt rather than crashing.
      {:ok, "done"} =
        Fire.run(
          %{prompt: "p", skills: ["missing"]},
          capturing_opts() ++ [skills: :no_such_store]
        )

      assert_receive {:messages, messages}
      refute Enum.any?(messages, &(&1.role == :system))
    end

    test "marks the run context in_cron when the fire has tools" do
      {:ok, counter} = Agent.start_link(fn -> 0 end)

      # A one-shot tool call: the first completion asks for record_ctx, the next
      # returns a final answer, so the ReAct loop terminates.
      tool_calls_fn = fn ->
        n = Agent.get_and_update(counter, fn n -> {n, n + 1} end)
        if n == 0, do: [%{"name" => "record_ctx", "arguments" => %{}}], else: nil
      end

      opts = [
        actions: [RecordContext],
        agent_opts: [
          backend: Raxol.Agent.Backend.Mock,
          backend_opts: [response: "done", tool_calls_fn: tool_calls_fn],
          context: %{collector: self()}
        ]
      ]

      assert {:ok, "done"} = Fire.run(%{prompt: "p", skills: []}, opts)
      assert_receive {:in_cron, true}
    end
  end

  # -- helpers ----------------------------------------------------------------

  defp user_turns(messages), do: Enum.filter(messages, &(&1.role == :user))

  defp start_skills_store do
    root = Path.join(System.tmp_dir!(), "fire_skills_#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf(root) end)
    name = :"fire_skills_store_#{System.unique_integer([:positive])}"
    start_supervised!({Skills.Store, name: name, skills_root: root, external_dirs: []})
    name
  end
end
