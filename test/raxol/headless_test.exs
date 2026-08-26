defmodule Raxol.HeadlessTest do
  use ExUnit.Case, async: false

  alias Raxol.Headless

  # Minimal TEA app for testing
  defmodule TestApp do
    use Raxol.Core.Runtime.Application

    @impl true
    def init(_context), do: %{count: 0, panel: :a}

    @impl true
    def update(message, model) do
      case message do
        :increment ->
          {%{model | count: model.count + 1}, []}

        %Raxol.Core.Events.Event{type: :key, data: %{key: :tab}} ->
          {%{model | panel: :b}, []}

        %Raxol.Core.Events.Event{type: :key, data: %{key: :char, char: "q"}} ->
          {model, [Directive.stop()]}

        %Raxol.Core.Events.Event{type: :key, data: %{key: :char, char: "="}} ->
          {%{model | count: model.count + 1}, []}

        _ ->
          {model, []}
      end
    end

    @impl true
    def view(model) do
      Raxol.Core.Renderer.View.column(
        children: [
          Raxol.Core.Renderer.View.text("Count: #{model.count}"),
          Raxol.Core.Renderer.View.text("Panel: #{model.panel}")
        ]
      )
    end

    @impl true
    def subscriptions(_model), do: []
  end

  setup do
    # The app-level Headless may or may not be running depending on
    # test mode. Ensure one exists, clean slate for each test.
    pid =
      case Process.whereis(Headless) do
        nil ->
          start_supervised!({Headless, [name: Headless]})

        existing ->
          # Clean up leftover sessions from prior tests
          for id <- GenServer.call(existing, :list_sessions) do
            try do
              GenServer.call(existing, {:stop_session, id}, 2_000)
            catch
              :exit, _ -> :ok
            end
          end

          existing
      end

    on_exit(fn ->
      if Process.alive?(pid) do
        for id <- GenServer.call(pid, :list_sessions) do
          try do
            GenServer.call(pid, {:stop_session, id}, 2_000)
          catch
            :exit, _ -> :ok
          end
        end
      end
    end)

    :ok
  end

  describe "start/2 and stop/1" do
    test "starts a session from a module" do
      {:ok, id} = Headless.start(TestApp, id: :test_start)
      assert id == :test_start
    end

    test "derives id from module name" do
      {:ok, id} = Headless.start(TestApp, [])
      assert id == :test_app
    end

    test "rejects duplicate session ids" do
      {:ok, _} = Headless.start(TestApp, id: :dupe_test)

      assert {:error, {:already_started, :dupe_test}} =
               Headless.start(TestApp, id: :dupe_test)
    end

    test "returns error for unknown module" do
      assert {:error, {:module_not_found, NoSuchModule}} =
               Headless.start(NoSuchModule, id: :bad)
    end

    test "returns error for missing file" do
      assert {:error, {:file_not_found, _}} =
               Headless.start("nonexistent.exs", id: :bad)
    end

    test "stop removes session" do
      {:ok, _} = Headless.start(TestApp, id: :stop_test)
      :ok = Headless.stop(:stop_test)
      assert {:error, :not_found} = Headless.screenshot(:stop_test)
    end

    test "stop is idempotent for missing sessions" do
      assert :ok = Headless.stop(:never_existed)
    end
  end

  describe "screenshot/1" do
    test "captures text from the rendered buffer" do
      {:ok, _} = Headless.start(TestApp, id: :ss_test, width: 40, height: 10)
      Process.sleep(300)

      {:ok, text} = Headless.screenshot(:ss_test)
      assert text =~ "Count: 0"
      assert text =~ "Panel: a"
    end

    test "returns error for nonexistent session" do
      assert {:error, :not_found} = Headless.screenshot(:no_such)
    end
  end

  describe "send_key/3" do
    test "dispatches a key event" do
      {:ok, _} = Headless.start(TestApp, id: :key_test)
      Process.sleep(200)

      :ok = Headless.send_key(:key_test, "=")
      Process.sleep(100)

      {:ok, model} = Headless.get_model(:key_test)
      assert model.count == 1
    end
  end

  describe "send_key_and_screenshot/3" do
    test "sends key and returns updated screenshot" do
      {:ok, _} = Headless.start(TestApp, id: :kas_test, width: 40, height: 10)
      Process.sleep(300)

      {:ok, text} = Headless.send_key_and_screenshot(:kas_test, "=")
      assert text =~ "Count: 1"
    end

    test "handles special keys" do
      {:ok, _} = Headless.start(TestApp, id: :tab_test, width: 40, height: 10)
      Process.sleep(300)

      {:ok, text} = Headless.send_key_and_screenshot(:tab_test, :tab)
      assert text =~ "Panel: b"
    end
  end

  describe "get_model/1" do
    test "returns the current model" do
      {:ok, _} = Headless.start(TestApp, id: :model_test)
      Process.sleep(200)

      {:ok, model} = Headless.get_model(:model_test)
      assert model.count == 0
      assert model.panel == :a
    end

    test "returns error for nonexistent session" do
      assert {:error, :not_found} = Headless.get_model(:nope)
    end
  end

  describe "list/0" do
    test "returns active session ids" do
      {:ok, _} = Headless.start(TestApp, id: :list_a)
      {:ok, _} = Headless.start(TestApp, id: :list_b)

      sessions = Headless.list()
      assert :list_a in sessions
      assert :list_b in sessions
    end

    test "empty when no sessions" do
      assert Headless.list() == []
    end
  end

  describe "process monitoring" do
    test "removes session when lifecycle process dies" do
      {:ok, _} = Headless.start(TestApp, id: :monitor_test)
      Process.sleep(200)

      {:ok, model} = Headless.get_model(:monitor_test)
      assert model.count == 0

      # Quit command kills the lifecycle
      Headless.send_key(:monitor_test, "q")

      # Poll for monitor cleanup (macOS CI can be slow).
      # Headless.list/0 returns [] if the server itself stopped, which also
      # means the session is gone -- treat that as success.
      Enum.reduce_while(1..40, nil, fn _, _ ->
        Process.sleep(50)
        sessions = Headless.list()
        if :monitor_test in sessions, do: {:cont, nil}, else: {:halt, :ok}
      end)

      refute :monitor_test in Headless.list()
    end
  end

  describe "file loading" do
    test "loads module from example script" do
      {:ok, id} =
        Headless.start("examples/getting_started/counter.exs", id: :counter_test)

      assert id == :counter_test
      Process.sleep(300)

      {:ok, text} = Headless.screenshot(:counter_test)
      assert text =~ "Count"
    end
  end

  # `Code.compile_quoted/2` EXECUTES module bodies, so whoever chooses the script
  # chooses what runs here -- and here is the singleton holding every other
  # caller's session. The body can end its own process three ways, of which a
  # `rescue` sees one, and it need not end at all: a body that never returns does
  # not kill this GenServer, it wedges it. Each case asserts BOTH halves: the
  # answer the caller gets, and that unrelated callers are still served.
  describe "start/2 with a script that misbehaves at compile time" do
    setup do
      dir =
        Path.join(
          System.tmp_dir!(),
          "raxol_headless_compile_#{System.unique_integer([:positive])}"
        )

      File.mkdir_p!(dir)
      on_exit(fn -> File.rm_rf!(dir) end)
      %{dir: dir}
    end

    # A fresh module name per script: these are compiled for real into this VM,
    # and reusing a name would only add redefinition noise.
    defp script(dir, body) do
      n = System.unique_integer([:positive])
      path = Path.join(dir, "hostile_#{n}.exs")
      File.write!(path, "defmodule HostileScript#{n} do\n  #{body}\nend\n")
      path
    end

    test "a body that raises is answered, not propagated", %{dir: dir} do
      path = script(dir, ~s|raise "boom at module scope"|)
      manager = Process.whereis(Headless)

      assert {:error, {:compile_failed, ^path, message}} =
               Headless.start(path, id: :raiser)

      assert message =~ "boom at module scope"

      assert Process.whereis(Headless) == manager
      assert {:ok, :after_raise} = Headless.start(TestApp, id: :after_raise)
    end

    test "a body that throws is answered, which `rescue` alone never did", %{
      dir: dir
    } do
      path = script(dir, ~s|throw(:thrown_at_module_scope)|)
      manager = Process.whereis(Headless)

      assert {:error, {:compile_failed, ^path, message}} =
               Headless.start(path, id: :thrower)

      assert message =~ "thrown_at_module_scope"

      assert Process.whereis(Headless) == manager
      assert {:ok, :after_throw} = Headless.start(TestApp, id: :after_throw)
    end

    test "a body that exits is answered, which `rescue` alone never did", %{
      dir: dir
    } do
      path = script(dir, ~s|exit(:exited_at_module_scope)|)
      manager = Process.whereis(Headless)

      assert {:error, {:compile_failed, ^path, message}} =
               Headless.start(path, id: :exiter)

      assert message =~ "exited_at_module_scope"

      assert Process.whereis(Headless) == manager
      assert {:ok, :after_exit} = Headless.start(TestApp, id: :after_exit)
    end

    test "a body that never returns is answered on a budget", %{dir: dir} do
      prev = Application.get_env(:raxol, :headless_compile_timeout_ms)
      Application.put_env(:raxol, :headless_compile_timeout_ms, 150)

      on_exit(fn ->
        if prev,
          do: Application.put_env(:raxol, :headless_compile_timeout_ms, prev),
          else: Application.delete_env(:raxol, :headless_compile_timeout_ms)
      end)

      path = script(dir, ~s|:timer.sleep(:infinity)|)
      manager = Process.whereis(Headless)

      # The ANSWER, not the clock. A wedge and a slow compile look identical on a
      # stopwatch, and timing assertions are this repo's most reliable source of
      # macOS flakes -- what makes this case a wedge is that no answer ever comes,
      # so the answer coming at all is the whole proof.
      assert {:error, {:compile_timed_out, ^path, 150}} =
               Headless.start(path, id: :wedge)

      # Not just alive: still able to compile, after a compile was brutal-killed
      # out from under the code server.
      assert Process.whereis(Headless) == manager

      good = script(dir, ~s|def noop, do: :ok|)

      assert {:error, :no_tea_module_found} =
               Headless.start(good, id: :after_wedge)
    end
  end

  describe "custom dimensions" do
    test "respects width and height options" do
      {:ok, _} = Headless.start(TestApp, id: :dim_test, width: 60, height: 15)
      Process.sleep(300)

      {:ok, text} = Headless.screenshot(:dim_test)
      lines = String.split(text, "\n")
      assert length(lines) <= 15
    end
  end
end
