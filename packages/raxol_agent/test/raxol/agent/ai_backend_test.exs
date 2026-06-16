defmodule Raxol.Agent.AIBackendTest do
  use ExUnit.Case, async: true

  alias Raxol.Agent.AIBackend
  alias Raxol.Agent.Backend.Mock

  defmodule InternalLoopBackend do
    @behaviour Raxol.Agent.AIBackend

    @impl true
    def complete(_messages, _opts), do: {:ok, %{content: "", usage: %{}, metadata: %{}}}
    @impl true
    def available?, do: true
    @impl true
    def name, do: "Internal Loop"
    @impl true
    def capabilities, do: [:completion, :tool_use]
    @impl true
    def handles_tools_internally?, do: true
    @impl true
    def max_context_tokens, do: 200_000
  end

  describe "Mock backend" do
    test "returns default response" do
      {:ok, resp} = Mock.complete([%{role: :user, content: "hello"}])

      assert resp.content == "Mock response"
      assert resp.metadata.backend == :mock
    end

    test "returns configured static response" do
      {:ok, resp} =
        Mock.complete(
          [%{role: :user, content: "hello"}],
          response: "Custom reply"
        )

      assert resp.content == "Custom reply"
    end

    test "returns response from function" do
      counter = :counters.new(1, [:atomics])

      {:ok, resp} =
        Mock.complete(
          [%{role: :user, content: "hello"}],
          response_fn: fn ->
            :counters.add(counter, 1, 1)
            "Response #{:counters.get(counter, 1)}"
          end
        )

      assert resp.content == "Response 1"
    end

    test "returns configured error" do
      assert {:error, :rate_limited} =
               Mock.complete(
                 [%{role: :user, content: "hello"}],
                 error: :rate_limited
               )
    end

    test "tracks token usage" do
      {:ok, resp} =
        Mock.complete([
          %{role: :user, content: "hello world"}
        ])

      assert resp.usage.input_tokens > 0
      assert resp.usage.output_tokens >= 0
    end

    test "stream returns events" do
      {:ok, events} =
        Mock.stream(
          [%{role: :user, content: "hello"}],
          response: "streamed"
        )

      assert [{:chunk, "streamed"}, {:done, %{content: "streamed"}}] = events
    end

    test "reports availability and capabilities" do
      assert Mock.available?() == true
      assert Mock.name() == "Mock Backend"
      assert :completion in Mock.capabilities()
      assert :streaming in Mock.capabilities()
    end
  end

  describe "capability negotiation" do
    test "handles_tools_internally?/1 defaults to false for backends without the callback" do
      refute AIBackend.handles_tools_internally?(Mock)
    end

    test "handles_tools_internally?/1 returns the backend's value when implemented" do
      assert AIBackend.handles_tools_internally?(InternalLoopBackend)
    end

    test "max_context_tokens/1 defaults to nil for backends without the callback" do
      assert AIBackend.max_context_tokens(Mock) == nil
    end

    test "max_context_tokens/1 returns the backend's value when implemented" do
      assert AIBackend.max_context_tokens(InternalLoopBackend) == 200_000
    end
  end
end
