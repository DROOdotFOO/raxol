defmodule Raxol.Symphony.Orchestrator.PausedSaverTest do
  use ExUnit.Case, async: false

  alias Raxol.Symphony.Orchestrator.PausedSaver
  alias Raxol.Symphony.Orchestrator.PausedSaver.{Dets, Memory}

  defp paused_entry(issue_id) do
    %{
      issue: %{id: issue_id, identifier: "MT-#{issue_id}"},
      attempt: 1,
      workspace_path: "/tmp/ws-#{issue_id}",
      interrupt_reason: :awaiting_buyer_payment,
      resume_token: %{seq: 1},
      paused_at: System.monotonic_time(:millisecond),
      last_event: nil,
      last_message: nil,
      turn_count: 2,
      tokens: %{input_tokens: 100, output_tokens: 50, total_tokens: 150}
    }
  end

  describe "dispatch with nil saver" do
    test "put/3 + delete/2 + load_all/1 are all no-ops" do
      assert :ok = PausedSaver.put(nil, "a", paused_entry("a"))
      assert :ok = PausedSaver.delete(nil, "a")
      assert %{} == PausedSaver.load_all(nil)
    end
  end

  describe "Memory adapter" do
    setup do
      table = :"symphony_paused_test_#{:erlang.unique_integer([:positive])}"
      on_exit(fn -> if :ets.whereis(table) != :undefined, do: :ets.delete(table) end)
      {:ok, saver: {Memory, %{table: table}}}
    end

    test "round-trips a paused entry", %{saver: saver} do
      entry = paused_entry("a")

      assert :ok = PausedSaver.put(saver, "a", entry)
      assert %{"a" => ^entry} = PausedSaver.load_all(saver)
    end

    test "stores multiple entries independently", %{saver: saver} do
      e1 = paused_entry("a")
      e2 = paused_entry("b")

      assert :ok = PausedSaver.put(saver, "a", e1)
      assert :ok = PausedSaver.put(saver, "b", e2)
      assert %{"a" => ^e1, "b" => ^e2} = PausedSaver.load_all(saver)
    end

    test "delete removes the entry", %{saver: saver} do
      e = paused_entry("a")
      assert :ok = PausedSaver.put(saver, "a", e)
      assert :ok = PausedSaver.delete(saver, "a")
      assert %{} == PausedSaver.load_all(saver)
    end

    test "delete on unknown key is idempotent", %{saver: saver} do
      assert :ok = PausedSaver.delete(saver, "ghost")
    end

    test "put overwrites an existing entry", %{saver: saver} do
      e1 = paused_entry("a")
      e2 = %{e1 | interrupt_reason: :awaiting_delivery}

      assert :ok = PausedSaver.put(saver, "a", e1)
      assert :ok = PausedSaver.put(saver, "a", e2)
      assert %{"a" => ^e2} = PausedSaver.load_all(saver)
    end
  end

  describe "Dets adapter" do
    setup do
      path =
        Path.join(
          System.tmp_dir!(),
          "symphony_paused_#{:erlang.unique_integer([:positive])}.dets"
        )

      name = :"symphony_paused_dets_#{:erlang.unique_integer([:positive])}"
      config = %{path: path, name: name}

      on_exit(fn ->
        _ = :dets.close(name)
        _ = File.rm(path)
      end)

      {:ok, saver: {Dets, config}, path: path, name: name}
    end

    test "persists entries to disk across :dets.close + reopen",
         %{saver: {Dets, cfg} = saver, name: name} do
      e = paused_entry("a")

      assert :ok = PausedSaver.put(saver, "a", e)

      # Close + reopen to prove the entry survives.
      :ok = :dets.close(name)

      assert %{"a" => ^e} = PausedSaver.load_all({Dets, cfg})
    end

    test "delete removes the entry", %{saver: saver} do
      e = paused_entry("a")
      :ok = PausedSaver.put(saver, "a", e)
      :ok = PausedSaver.delete(saver, "a")
      assert %{} == PausedSaver.load_all(saver)
    end

    test "missing path returns an error" do
      assert :ok != PausedSaver.put({Dets, %{}}, "a", paused_entry("a"))
    end
  end
end
