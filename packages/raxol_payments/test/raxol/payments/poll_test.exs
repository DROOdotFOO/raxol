defmodule Raxol.Payments.PollTest do
  use ExUnit.Case, async: true

  alias Raxol.Payments.Poll

  defp terminal?(%{done: done}), do: done

  # A fetch driven by a queue in the process dictionary, so each call returns the
  # next scripted result. Runs in the test process (Poll calls fetch inline).
  defp scripted_fetch(results) do
    Process.put(:poll_script, results)

    fn ->
      [next | rest] = Process.get(:poll_script)
      Process.put(:poll_script, rest)
      next
    end
  end

  describe "run/3" do
    test "returns terminal status and elapsed on the first poll" do
      fetch = scripted_fetch([{:ok, %{done: true}}])

      assert {:ok, %{done: true}, elapsed} = Poll.run(fetch, &terminal?/1)
      assert is_integer(elapsed) and elapsed >= 0
    end

    test "polls until terminal" do
      fetch =
        scripted_fetch([
          {:ok, %{done: false}},
          {:ok, %{done: false}},
          {:ok, %{done: true}}
        ])

      assert {:ok, %{done: true}, _elapsed} =
               Poll.run(fetch, &terminal?/1, fast_interval_ms: 1, slow_interval_ms: 1)
    end

    test "treats a 429 as a transient backoff and keeps polling" do
      fetch =
        scripted_fetch([
          {:error, {:http, 429, %{}}},
          {:ok, %{done: true}}
        ])

      assert {:ok, %{done: true}, _elapsed} =
               Poll.run(fetch, &terminal?/1, fast_interval_ms: 1)
    end

    test "returns a non-retryable fetch error immediately" do
      fetch = scripted_fetch([{:error, {:http, 500, %{}}}])

      assert {:error, {:http, 500, %{}}} = Poll.run(fetch, &terminal?/1)
    end

    test "returns :timeout when the deadline passes before terminal" do
      fetch = fn -> {:ok, %{done: false}} end

      assert {:error, :timeout} = Poll.run(fetch, &terminal?/1, timeout_ms: 0)
    end
  end
end
