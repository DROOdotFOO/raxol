defmodule Raxol.Agent.EventForwarderTest do
  use ExUnit.Case, async: true

  alias Raxol.Agent.EventForwarder

  defp drain_messages(timeout \\ 50) do
    do_drain(timeout, [])
  end

  defp do_drain(timeout, acc) do
    receive do
      msg -> do_drain(timeout, [msg | acc])
    after
      timeout -> Enum.reverse(acc)
    end
  end

  describe "to_parent/4" do
    test "forwards each event as {tag, key, payload}" do
      stream = [
        {:text_delta, "hi"},
        {:turn_complete, %{content: "hi", usage: %{}, iteration: 0}},
        {:done, %{content: "hi", tool_results: [], usage: %{}}}
      ]

      assert :ok = EventForwarder.to_parent(stream, self(), "issue-1")

      msgs = drain_messages()
      assert length(msgs) == 3

      assert [
               {:run_event, "issue-1", %{event: :text_delta}},
               {:run_event, "issue-1", %{event: :turn_completed}},
               {:run_event, "issue-1", %{event: :turn_completed}}
             ] = msgs
    end

    test "halts on :done returning :ok" do
      stream = [
        {:text_delta, "before"},
        {:done, %{content: "fin"}},
        {:text_delta, "after-should-not-arrive"}
      ]

      :ok = EventForwarder.to_parent(stream, self(), "k")

      msgs = drain_messages()
      assert length(msgs) == 2

      refute Enum.any?(msgs, fn {_, _, p} ->
               p[:message] == "after-should-not-arrive"
             end)
    end

    test "halts on :error returning {:error, reason} by default" do
      stream = [{:text_delta, "x"}, {:error, :boom}]

      assert {:error, :boom} = EventForwarder.to_parent(stream, self(), "k")
    end

    test "halt_on_error?: false continues past :error" do
      stream = [
        {:error, :boom},
        {:done, %{content: ""}}
      ]

      assert :ok =
               EventForwarder.to_parent(stream, self(), "k",
                 halt_on_error?: false
               )
    end

    test "custom :tag" do
      :ok =
        EventForwarder.to_parent([{:done, %{content: ""}}], self(), :alpha,
          tag: :symphony
        )

      assert_received {:symphony, :alpha, %{event: :turn_completed}}
    end

    test "custom :transform forwards raw tuples" do
      stream = [{:text_delta, "raw"}, {:done, %{content: ""}}]

      :ok =
        EventForwarder.to_parent(stream, self(), "k",
          transform: &Function.identity/1
        )

      assert_received {:run_event, "k", {:text_delta, "raw"}}
      assert_received {:run_event, "k", {:done, _}}
    end

    test "drains an empty stream and returns :ok" do
      assert :ok = EventForwarder.to_parent([], self(), "k")
      assert drain_messages(10) == []
    end
  end
end
