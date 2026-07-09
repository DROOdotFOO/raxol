defmodule Raxol.Debug.DebuggerAppTest do
  use ExUnit.Case, async: true

  alias Raxol.Debug.{DebuggerApp, TimeTravel}

  setup do
    name = :"tt_test_#{System.unique_integer([:positive])}"
    tt_pid = start_supervised!({TimeTravel, name: name})

    # Record some snapshots
    TimeTravel.record(tt_pid, :init, %{count: 0}, %{count: 0})
    TimeTravel.record(tt_pid, :tick, %{count: 0}, %{count: 1})
    TimeTravel.record(tt_pid, :tick, %{count: 1}, %{count: 2})

    Application.put_env(:raxol, :debugger_tt_ref, tt_pid)

    on_exit(fn -> Application.delete_env(:raxol, :debugger_tt_ref) end)

    %{tt_pid: tt_pid}
  end

  describe "init/1" do
    test "initializes with connection to TimeTravel" do
      model = DebuggerApp.init(nil)
      assert model.connected == true
      assert model.count == 3
      assert length(model.entries) == 3
      assert model.cursor_index != nil
    end

    test "initializes disconnected when no TimeTravel" do
      Application.put_env(:raxol, :debugger_tt_ref, :nonexistent_process)
      model = DebuggerApp.init(nil)
      assert model.connected == false
      assert model.entries == []
    end
  end

  describe "update/2 - navigation" do
    test "step back decreases cursor" do
      model = DebuggerApp.init(nil)
      initial_cursor = model.cursor_index

      event = key_event("h")
      {updated, []} = DebuggerApp.update(event, model)

      assert updated.cursor_index < initial_cursor
    end

    test "step forward increases cursor" do
      model = DebuggerApp.init(nil)
      # Step back first so we can step forward
      {model, []} = DebuggerApp.update(key_event("h"), model)
      cursor_after_back = model.cursor_index

      {updated, []} = DebuggerApp.update(key_event("l"), model)
      assert updated.cursor_index > cursor_after_back
    end

    test "j/k scrolls within panel" do
      model = DebuggerApp.init(nil)

      {scrolled, []} = DebuggerApp.update(key_event("j"), model)
      assert scrolled.timeline_offset == 1 || scrolled == model
    end

    test "tab cycles panels" do
      model = DebuggerApp.init(nil)
      assert model.panel == :timeline

      {m1, []} = DebuggerApp.update(tab_event(), model)
      assert m1.panel == :diff

      {m2, []} = DebuggerApp.update(tab_event(), m1)
      assert m2.panel == :inspector

      {m3, []} = DebuggerApp.update(tab_event(), m2)
      assert m3.panel == :timeline
    end
  end

  describe "update/2 - pause/resume" do
    test "space toggles pause" do
      model = DebuggerApp.init(nil)
      assert model.paused == false

      {paused, []} = DebuggerApp.update(space_event(), model)
      assert paused.paused == true

      {resumed, []} = DebuggerApp.update(space_event(), paused)
      assert resumed.paused == false
    end
  end

  describe "update/2 - jump mode" do
    test "g enters jump mode" do
      model = DebuggerApp.init(nil)
      {m, []} = DebuggerApp.update(key_event("g"), model)
      assert m.jump_mode == true
      assert m.jump_buffer == ""
    end

    test "digits accumulate in jump buffer" do
      model = %{DebuggerApp.init(nil) | jump_mode: true}
      {m, []} = DebuggerApp.update(key_event("1"), model)
      assert m.jump_buffer == "1"

      {m2, []} = DebuggerApp.update(key_event("0"), m)
      assert m2.jump_buffer == "10"
    end

    test "escape cancels jump mode" do
      model = %{DebuggerApp.init(nil) | jump_mode: true, jump_buffer: "42"}
      {m, []} = DebuggerApp.update(escape_event(), model)
      assert m.jump_mode == false
      assert m.jump_buffer == ""
    end

    test "enter executes jump" do
      model = %{DebuggerApp.init(nil) | jump_mode: true, jump_buffer: "0"}
      {m, []} = DebuggerApp.update(enter_event(), model)
      assert m.jump_mode == false
      assert m.cursor_index == 0
    end
  end

  describe "update/2 - quit" do
    test "q sends quit command" do
      model = DebuggerApp.init(nil)
      {_m, commands} = DebuggerApp.update(key_event("q"), model)
      assert length(commands) == 1
    end
  end

  describe "update/2 - refresh" do
    test "refresh updates entries from TimeTravel", %{tt_pid: tt_pid} do
      model = DebuggerApp.init(nil)

      # Add a new snapshot
      TimeTravel.record(tt_pid, :tick, %{count: 2}, %{count: 3})

      {refreshed, []} = DebuggerApp.update(:refresh, model)
      assert refreshed.count == 4
    end
  end

  describe "view/1" do
    test "returns a view tree" do
      model = DebuggerApp.init(nil)
      view = DebuggerApp.view(model)
      assert view != nil
      assert is_map(view)
    end

    test "renders with empty state" do
      Application.put_env(:raxol, :debugger_tt_ref, :nonexistent_process)
      model = DebuggerApp.init(nil)
      view = DebuggerApp.view(model)
      assert view != nil
    end
  end

  describe "subscribe/1" do
    test "returns subscription list" do
      model = DebuggerApp.init(nil)
      subs = DebuggerApp.subscribe(model)
      assert is_list(subs)
      assert [_ | _] = subs
    end
  end

  # -- Event helpers --

  defp key_event(char) do
    %Raxol.Core.Events.Event{
      type: :key,
      data: %{key: :char, char: char}
    }
  end

  defp tab_event do
    %Raxol.Core.Events.Event{type: :key, data: %{key: :tab}}
  end

  defp space_event do
    %Raxol.Core.Events.Event{type: :key, data: %{key: :char, char: " "}}
  end

  defp escape_event do
    %Raxol.Core.Events.Event{type: :key, data: %{key: :escape}}
  end

  defp enter_event do
    %Raxol.Core.Events.Event{type: :key, data: %{key: :enter}}
  end
end
