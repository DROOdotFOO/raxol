defmodule Raxol.PluginTest do
  use ExUnit.Case, async: true

  alias Raxol.Core.Buffer

  defmodule TestPlugin do

    def init(opts) do
      initial_value = Keyword.get(opts, :initial_value, 0)
      {:ok, %{counter: initial_value, log: []}}
    end

    def handle_input("q", _modifiers, state) do
      {:exit, state}
    end

    def handle_input("+", _modifiers, state) do
      {:ok, %{state | counter: state.counter + 1}}
    end

    def handle_input("-", _modifiers, state) do
      {:ok, %{state | counter: state.counter - 1}}
    end

    def handle_input("e", _modifiers, _state) do
      {:error, :test_error}
    end

    def handle_input(_key, _modifiers, state) do
      {:ok, state}
    end

    def render(buffer, state) do
      Buffer.write_at(buffer, 0, 0, "Counter: #{state.counter}")
    end

    def cleanup(state) do
      # credo:disable-for-next-line Credo.Check.Refactor.AppendSingleItem
      new_state = %{state | log: state.log ++ [:cleanup_called]}

      if new_state.counter == 999 do
        {:error, :cleanup_failed}
      else
        :ok
      end
    end

    def handle_info(:increment, state) do
      {:ok, %{state | counter: state.counter + 1}}
    end

    def handle_info(:exit, state) do
      {:exit, state}
    end

    def handle_info(:error, _state) do
      {:error, :async_error}
    end

    def handle_info(_msg, state) do
      {:ok, state}
    end
  end

  defmodule MinimalPlugin do

    def init(_opts), do: {:ok, %{}}

    def handle_input("q", _modifiers, state), do: {:exit, state}
    def handle_input(_key, _modifiers, state), do: {:ok, state}

    def render(buffer, _state), do: buffer

    def cleanup(_state), do: :ok

    # handle_info is optional - not implemented
  end

  describe "plugin behavior" do
    test "TestPlugin implements all required callbacks" do
      assert function_exported?(TestPlugin, :init, 1)
      assert function_exported?(TestPlugin, :handle_input, 3)
      assert function_exported?(TestPlugin, :render, 2)
      assert function_exported?(TestPlugin, :cleanup, 1)
    end

    test "TestPlugin implements optional handle_info callback" do
      assert function_exported?(TestPlugin, :handle_info, 2)
    end

    test "MinimalPlugin implements required callbacks only" do
      assert function_exported?(MinimalPlugin, :init, 1)
      assert function_exported?(MinimalPlugin, :handle_input, 3)
      assert function_exported?(MinimalPlugin, :render, 2)
      assert function_exported?(MinimalPlugin, :cleanup, 1)
    end

    test "MinimalPlugin does not implement optional callbacks" do
      refute function_exported?(MinimalPlugin, :handle_info, 2)
    end
  end

  describe "init/1" do
    test "initializes with default options" do
      assert {:ok, state} = TestPlugin.init([])
      assert state.counter == 0
      assert state.log == []
    end

    test "initializes with custom options" do
      assert {:ok, state} = TestPlugin.init(initial_value: 42)
      assert state.counter == 42
    end
  end

  describe "handle_input/3" do
    setup do
      {:ok, state} = TestPlugin.init([])
      modifiers = %{ctrl: false, alt: false, shift: false, meta: false}
      {:ok, state: state, modifiers: modifiers}
    end

    test "returns {:ok, new_state} for normal input", %{state: state, modifiers: modifiers} do
      assert {:ok, new_state} = TestPlugin.handle_input("+", modifiers, state)
      assert new_state.counter == 1
    end

    test "returns {:exit, state} for quit command", %{state: state, modifiers: modifiers} do
      assert {:exit, final_state} = TestPlugin.handle_input("q", modifiers, state)
      assert final_state == state
    end

    test "returns {:error, reason} for error input", %{state: state, modifiers: modifiers} do
      assert {:error, :test_error} = TestPlugin.handle_input("e", modifiers, state)
    end

    test "handles multiple inputs correctly", %{state: state, modifiers: modifiers} do
      {:ok, state} = TestPlugin.handle_input("+", modifiers, state)
      assert state.counter == 1

      {:ok, state} = TestPlugin.handle_input("+", modifiers, state)
      assert state.counter == 2

      {:ok, state} = TestPlugin.handle_input("-", modifiers, state)
      assert state.counter == 1
    end
  end

  describe "render/2" do
    test "renders state to buffer" do
      {:ok, state} = TestPlugin.init(initial_value: 42)
      buffer = Buffer.create_blank_buffer(20, 5)

      rendered = TestPlugin.render(buffer, state)
      output = Buffer.to_string(rendered)

      assert output =~ "Counter: 42"
    end

    test "updates buffer on state changes" do
      {:ok, state} = TestPlugin.init([])
      buffer = Buffer.create_blank_buffer(20, 5)

      rendered1 = TestPlugin.render(buffer, state)
      assert Buffer.to_string(rendered1) =~ "Counter: 0"

      state = %{state | counter: 5}
      rendered2 = TestPlugin.render(buffer, state)
      assert Buffer.to_string(rendered2) =~ "Counter: 5"
    end
  end

  describe "cleanup/1" do
    test "returns :ok on successful cleanup" do
      {:ok, state} = TestPlugin.init([])

      assert :ok = TestPlugin.cleanup(state)
    end

    test "returns {:error, reason} on failed cleanup" do
      {:ok, state} = TestPlugin.init(initial_value: 999)

      assert {:error, :cleanup_failed} = TestPlugin.cleanup(state)
    end
  end

  describe "handle_info/2" do
    test "handles async messages" do
      {:ok, state} = TestPlugin.init([])

      assert {:ok, new_state} = TestPlugin.handle_info(:increment, state)
      assert new_state.counter == 1
    end

    test "can signal exit from async message" do
      {:ok, state} = TestPlugin.init([])

      assert {:exit, final_state} = TestPlugin.handle_info(:exit, state)
      assert final_state == state
    end

    test "can return error from async message" do
      {:ok, state} = TestPlugin.init([])

      assert {:error, :async_error} = TestPlugin.handle_info(:error, state)
    end

    test "handles unknown messages" do
      {:ok, state} = TestPlugin.init([])

      assert {:ok, ^state} = TestPlugin.handle_info(:unknown, state)
    end
  end

  # Removed: empty stub test "runs plugin lifecycle" (no assertions, just :ok)

  describe "integration" do
    test "full plugin lifecycle without run/2" do
      modifiers = %{ctrl: false, alt: false, shift: false, meta: false}

      # Initialize
      {:ok, state} = TestPlugin.init(initial_value: 10)
      assert state.counter == 10

      # Handle some inputs
      {:ok, state} = TestPlugin.handle_input("+", modifiers, state)
      assert state.counter == 11

      {:ok, state} = TestPlugin.handle_input("+", modifiers, state)
      assert state.counter == 12

      {:ok, state} = TestPlugin.handle_input("-", modifiers, state)
      assert state.counter == 11

      # Render
      buffer = Buffer.create_blank_buffer(30, 10)
      rendered = TestPlugin.render(buffer, state)
      assert Buffer.to_string(rendered) =~ "Counter: 11"

      # Cleanup
      assert :ok = TestPlugin.cleanup(state)
    end

    test "plugin with async messages" do
      {:ok, state} = TestPlugin.init([])

      # Async increment
      {:ok, state} = TestPlugin.handle_info(:increment, state)
      assert state.counter == 1

      {:ok, state} = TestPlugin.handle_info(:increment, state)
      assert state.counter == 2

      # Render current state
      buffer = Buffer.create_blank_buffer(30, 10)
      rendered = TestPlugin.render(buffer, state)
      assert Buffer.to_string(rendered) =~ "Counter: 2"

      # Exit via async message
      {:exit, _} = TestPlugin.handle_info(:exit, state)
    end
  end
end
