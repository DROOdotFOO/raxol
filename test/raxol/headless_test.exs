defmodule Raxol.HeadlessTest do
  use ExUnit.Case, async: false

  alias Raxol.Headless
  import ExUnit.CaptureLog, only: [capture_log: 1]

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

  defmodule SizeApp do
    use Raxol.Core.Runtime.Application

    @impl true
    def init(%{width: w, height: h}), do: %{init_size: {w, h}, resized: nil}

    @impl true
    def update(
          %Raxol.Core.Events.Event{type: :resize, data: %{width: w, height: h}},
          model
        ),
        do: {%{model | resized: {w, h}}, []}

    def update(_message, model), do: {model, []}

    @impl true
    def view(_model), do: Raxol.Core.Renderer.View.text("sized")

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

    # `Raxol.start_link/2` CALLS `init/1`, so admitting a module on "a beam
    # exists for this name" starts whatever was named. 527 modules on this tree
    # export `init/1` against 53 that implement TEA, and this is one of the
    # former: a `BaseManager` GenServer whose `init/1` would have run here
    # outside any supervisor.
    test "refuses a real module that is not a Raxol application" do
      assert {:error,
              {:not_a_raxol_application, Raxol.Terminal.Buffer.BufferServer}} =
               Headless.start(Raxol.Terminal.Buffer.BufferServer, id: :not_app)
    end

    # The gate asks the behaviour first, but it cannot ask ONLY that: the
    # runtime does not, and `Raxol.Examples.Demos.IntegratedAccessibilityDemo`
    # is a TEA app in this repo that never declares it. This module is that
    # shape deliberately -- three callbacks, no `use`, no `@behaviour`.
    defmodule UndeclaredApp do
      def init(_context), do: %{}
      def update(_message, model), do: {model, []}
      def view(_model), do: Raxol.Core.Renderer.View.text("undeclared")
    end

    test "accepts a TEA app that never declared the behaviour" do
      refute Raxol.Core.Runtime.Application in List.flatten(
               Keyword.get_values(
                 UndeclaredApp.module_info(:attributes),
                 :behaviour
               )
             )

      assert {:ok, :undeclared} =
               Headless.start(UndeclaredApp, id: :undeclared)
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

      {:ok, text} = Headless.screenshot(:ss_test)
      assert text =~ "Count: 0"
      assert text =~ "Panel: a"
    end

    test "returns error for nonexistent session" do
      assert {:error, :not_found} = Headless.screenshot(:no_such)
    end

    # The frame is the one the render drew, from that call's reply. A cast
    # the engine takes between drawing and a separate read used to blank it:
    # `{:update_size, _}`, which the dispatcher sends once it learns the
    # engine and which swaps in a fresh buffer, is one the runtime always
    # sends just after start.
    test "returns the drawn frame when a resize reaches the engine first" do
      {:ok, id} = Headless.start(TestApp, id: :ss_race, width: 40, height: 10)

      %{lifecycle: lifecycle, dispatcher: dispatcher, engine: engine} =
        session_pids(id)

      # Let the startup messages land, so the engine's queue holds only what
      # this test puts there.
      for pid <- [lifecycle, dispatcher, engine], do: :sys.get_state(pid)

      :ok = :sys.suspend(engine)
      :erlang.trace(engine, true, [:receive])
      screenshot = Task.async(fn -> Headless.screenshot(id) end)

      assert_receive {:trace, ^engine, :receive,
                      {:"$gen_call", _, :render_frame_sync_buffer}}

      # Queued behind the render call: a local send lands before cast returns.
      GenServer.cast(engine, {:update_size, %{width: 40, height: 10}})
      :ok = :sys.resume(engine)

      assert {:ok, text} = Task.await(screenshot)
      assert text =~ "Count: 0"
    end
  end

  describe "send_key/3" do
    test "returns only once update/2 has handled the key" do
      {:ok, id} = Headless.start(TestApp, id: :key_handled)

      assert :ok = answer_with_dispatcher_held(id, &Headless.send_key(&1, "="))
      assert {:ok, %{count: 1}} = Headless.get_model(id)
    end

    # The call holds the session manager, which serves every other session,
    # so losing the dispatcher mid-call must cost this caller alone.
    test "answers an error, and keeps serving, when the dispatcher dies on the key" do
      {:ok, id} = Headless.start(TestApp, id: :key_lost)
      {:ok, bystander} = Headless.start(TestApp, id: :key_bystander)

      assert {:error, {:dispatch_failed, :killed}} =
               answer_with_dispatcher_held(
                 id,
                 &Headless.send_key(&1, "="),
                 &Process.exit(&1, :kill)
               )

      assert {:ok, %{count: 0}} = Headless.get_model(bystander)
    end
  end

  describe "send_resize/3" do
    test "returns only once update/2 has handled the resize" do
      {:ok, id} = Headless.start(TestApp, id: :resize_handled)

      assert :ok =
               answer_with_dispatcher_held(id, &Headless.send_resize(&1, 30, 8))

      assert {:ok, %{width: 30, height: 8}} = Headless.get_buffer(id)
    end
  end

  describe "send_key_and_screenshot/3" do
    test "sends key and returns updated screenshot" do
      {:ok, _} = Headless.start(TestApp, id: :kas_test, width: 40, height: 10)

      {:ok, text} = Headless.send_key_and_screenshot(:kas_test, "=")
      assert text =~ "Count: 1"
    end

    test "handles special keys" do
      {:ok, _} = Headless.start(TestApp, id: :tab_test, width: 40, height: 10)

      {:ok, text} = Headless.send_key_and_screenshot(:tab_test, :tab)
      assert text =~ "Panel: b"
    end
  end

  describe "get_model/1" do
    test "returns the current model" do
      {:ok, _} = Headless.start(TestApp, id: :model_test)

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

    # The ToolSynchronizer is linked to Headless, not to the lifecycle, so
    # nothing but Headless's own `:DOWN` handling can stop it when the app dies
    # on its own. Left running, it keeps its telemetry handler and the session's
    # MCP resources registered for a session `list/0` no longer reports.
    test "stops the session's tool synchronizer when the lifecycle dies" do
      registry =
        Process.whereis(Raxol.MCP.Registry) ||
          start_supervised!({Raxol.MCP.Registry, name: Raxol.MCP.Registry})

      {:ok, id} = Headless.start(TestApp, id: :sync_down_test)

      %{lifecycle_pid: lifecycle_pid, synchronizer_pid: sync_pid} =
        :sys.get_state(Headless).sessions[id]

      assert is_pid(sync_pid)
      context_uri = "raxol://session/#{id}/context"
      assert context_uri in resource_uris(registry)

      sync_ref = Process.monitor(sync_pid)
      lifecycle_ref = Process.monitor(lifecycle_pid)
      Process.exit(lifecycle_pid, :kill)
      assert_receive {:DOWN, ^lifecycle_ref, :process, _, :killed}

      assert_receive {:DOWN, ^sync_ref, :process, _, _}, 2_000
      refute id in Headless.list()
      refute context_uri in resource_uris(registry)

      refute Enum.any?(
               :telemetry.list_handlers([:raxol, :runtime, :view_tree_updated]),
               &String.starts_with?(&1.id, "tool_sync_#{id}_")
             )
    end
  end

  defp resource_uris(registry) do
    registry |> Raxol.MCP.Registry.list_resources() |> Enum.map(& &1.uri)
  end

  describe "file loading" do
    test "loads module from example script" do
      {:ok, id} =
        Headless.start("examples/getting_started/counter.exs",
          id: :counter_test
        )

      assert id == :counter_test

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

    # The tight budget belongs to the wedged call and to nothing else. Left in
    # force afterwards it also governs the recovery compile these tests do to
    # prove the manager survived -- and that compile is real work racing a
    # 150ms clock, which is the repo's most reliable macOS flake shape. It came
    # true on 2026-09-02: the 1.17.3/macOS nightly cell timed out compiling
    # `def noop, do: :ok`, and reported the budget error for it. Recovery is
    # asserted against the production budget, which is what recovery means.
    defp with_compile_budget(ms, fun) do
      prev = Application.get_env(:raxol, :headless_compile_timeout_ms)
      Application.put_env(:raxol, :headless_compile_timeout_ms, ms)

      try do
        fun.()
      after
        if prev,
          do: Application.put_env(:raxol, :headless_compile_timeout_ms, prev),
          else: Application.delete_env(:raxol, :headless_compile_timeout_ms)
      end
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
      path = script(dir, ~s|:timer.sleep(:infinity)|)
      manager = Process.whereis(Headless)

      # The ANSWER, not the clock. A wedge and a slow compile look identical on a
      # stopwatch, and timing assertions are this repo's most reliable source of
      # macOS flakes -- what makes this case a wedge is that no answer ever comes,
      # so the answer coming at all is the whole proof.
      assert {:error, {:compile_timed_out, ^path, 150}} =
               with_compile_budget(150, fn ->
                 Headless.start(path, id: :wedge)
               end)

      # Not just alive: still able to compile, after a compile was killed out
      # from under the code server.
      assert Process.whereis(Headless) == manager

      good = script(dir, ~s|def noop, do: :ok|)

      assert {:error, :no_tea_module_found} =
               Headless.start(good, id: :after_wedge)
    end

    # The regression guard for the case above, which is the one the budget
    # leaked into. A leak only ever shows up as a slow-runner flake -- the
    # 2026-09-02 macOS nightly cell lost a 150ms race to compile
    # `def noop, do: :ok` -- so this reproduces it deterministically with a
    # budget nothing could meet, rather than waiting for a loaded machine.
    test "the wedge's budget does not govern the compile after it", %{dir: dir} do
      wedge = script(dir, ~s|:timer.sleep(:infinity)|)

      assert {:error, {:compile_timed_out, ^wedge, 1}} =
               with_compile_budget(1, fn ->
                 Headless.start(wedge, id: :budget_scope_wedge)
               end)

      # A leaked budget answers `{:compile_timed_out, _, 1}` here instead.
      good = script(dir, ~s|def noop, do: :ok|)

      assert {:error, :no_tea_module_found} =
               Headless.start(good, id: :budget_scope_after)
    end

    # The case above passes even when the kill does not land, because a
    # non-trapping body dies of anything. `:brutal_kill` is a Supervisor
    # shutdown SPEC; to `Process.exit/2` it is an ordinary, trappable reason, so
    # a body that traps exits outlived its own budget -- one leaked process per
    # hostile call, each still holding the code server's claim on the module
    # name it was compiling, which denies that name to every later script for
    # the life of the VM. So this asserts the corpse and the freed name, not
    # merely that the caller was answered.
    test "a body that traps exits is killed anyway, freeing its module name", %{
      dir: dir
    } do
      # The compiling process IS the module body's process, so the body can hand
      # its own pid back here. Nothing else can: the compile runs in a child the
      # manager spawns and never names.
      Process.register(self(), :headless_trap_probe)
      n = System.unique_integer([:positive])
      name = "HeadlessTrapProbe#{n}"
      wedge = Path.join(dir, "trap_#{n}.exs")

      File.write!(wedge, """
      defmodule #{name} do
        Process.flag(:trap_exit, true)
        send(:headless_trap_probe, {:compiling, self()})
        :timer.sleep(:infinity)
      end
      """)

      assert {:error, {:compile_timed_out, ^wedge, 150}} =
               with_compile_budget(150, fn ->
                 Headless.start(wedge, id: :trap_wedge)
               end)

      assert_received {:compiling, compiler}

      # Monitoring after the fact races with a kill that already landed, and
      # `:noproc` is that race resolving the right way.
      ref = Process.monitor(compiler)
      assert_receive {:DOWN, ^ref, :process, ^compiler, reason}, 1_000
      assert reason in [:killed, :noproc]

      # The point of killing it rather than merely answering the caller: the
      # module name it held is usable again.
      good = Path.join(dir, "trap_ok_#{n}.exs")
      File.write!(good, "defmodule #{name} do\n  def noop, do: :ok\nend\n")

      assert {:error, :no_tea_module_found} =
               Headless.start(good, id: :after_trap)
    end

    # `Code.string_to_quoted/2` charlist-converts its input before parsing, so
    # invalid encoding RAISES instead of answering -- inside `handle_call`, which
    # takes the singleton and every unrelated session it holds. Reachable through
    # the confined path too: the root check tests only the extension, so any
    # binary file named `*.exs` inside the root is this.
    test "a file that is not valid UTF-8 is answered, not raised", %{dir: dir} do
      path = Path.join(dir, "mojibake.exs")
      File.write!(path, <<0xFF, 0xFE, "defmodule Mojibake do\nend\n">>)
      manager = Process.whereis(Headless)

      assert {:error, {:unparseable_file, ^path, message}} =
               Headless.start(path, id: :mojibake)

      assert is_binary(message)

      assert Process.whereis(Headless) == manager

      assert {:ok, :after_mojibake} =
               Headless.start(TestApp, id: :after_mojibake)
    end

    # Declaring `@behaviour Raxol.Core.Runtime.Application` and implementing
    # none of it compiles: Elixir warns about the missing callbacks, it does not
    # refuse. So a gate that accepts the ATTRIBUTE admits a module nothing can
    # drive, and the session that follows renders an empty frame forever -- a
    # silent do-nothing where there used to be a clean error. Reachable from
    # `mix raxol.render`, `Raxol.MCP.Test.start_session/2` and `raxol_start`'s
    # `path` once a root is configured.
    #
    # `tea_module?/1` is shared with the module branch, so this pins the compile
    # branch specifically: it is the one that regressed when the check moved
    # from exports to the attribute.
    test "a module that declares the behaviour but implements nothing is refused",
         %{dir: dir} do
      n = System.unique_integer([:positive])
      path = Path.join(dir, "decl_only_#{n}.exs")

      File.write!(path, """
      defmodule HeadlessDeclOnly#{n} do
        @behaviour Raxol.Core.Runtime.Application
      end
      """)

      assert {:error, :no_tea_module_found} =
               Headless.start(path, id: :decl_only)
    end
  end

  describe "custom dimensions" do
    test "respects width and height options" do
      {:ok, _} = Headless.start(TestApp, id: :dim_test, width: 60, height: 15)

      {:ok, text} = Headless.screenshot(:dim_test)
      lines = String.split(text, "\n")
      assert length(lines) <= 15
    end

    # `Raxol.Headless.start/2` and `send_resize/3` take the pilot's own sizes,
    # so they clamp (with a warning) instead of refusing; the MCP tool in
    # front of them refuses. Either way the app is told the size it is drawn
    # at, and the engine never allocates past the ceiling.
    test "a size past the terminal size ceiling starts at the ceiling" do
      log =
        capture_log(fn ->
          {:ok, _} =
            Headless.start(SizeApp,
              id: :oversize_start,
              width: 100_000,
              height: 100_000
            )
        end)

      assert log =~ "100000x100000 is past the terminal size ceiling"

      assert {:ok, %{init_size: {4096, 256}}} =
               Headless.get_model(:oversize_start)

      %{engine: engine} = session_pids(:oversize_start)
      state = GenServer.call(engine, {:get_state})
      assert {state.width, state.height} == {4096, 256}
      assert {state.buffer.width, state.buffer.height} == {4096, 256}
    end

    test "a resize past the ceiling reaches the app and the engine at the ceiling, warning once" do
      {:ok, _} =
        Headless.start(SizeApp, id: :oversize_resize, width: 80, height: 24)

      log =
        capture_log(fn ->
          :ok = Headless.send_resize(:oversize_resize, 100_000, 100_000)

          assert {:ok, %{resized: {4096, 256}}} =
                   Headless.get_model(:oversize_resize)

          # Still oversized, still at the ceiling: no second warning.
          :ok = Headless.send_resize(:oversize_resize, 50_000, 9_000)

          assert {:ok, %{resized: {4096, 256}}} =
                   Headless.get_model(:oversize_resize)
        end)

      assert length(String.split(log, "past the terminal size ceiling")) == 2

      %{engine: engine} = session_pids(:oversize_resize)
      state = GenServer.call(engine, {:get_state})
      assert {state.width, state.height} == {4096, 256}
      assert {state.buffer.width, state.buffer.height} == {4096, 256}

      :ok = Headless.send_resize(:oversize_resize, 120, 40)
      assert {:ok, %{resized: {120, 40}}} = Headless.get_model(:oversize_resize)
      assert {:ok, frame} = Headless.get_buffer(:oversize_resize)
      assert {frame.width, frame.height} == {120, 40}
    end
  end

  # On a VM attached to a terminal `:io.columns/0` and `:io.rows/0` answer.
  # The rendering engine used to take that size in every environment, and
  # only the dispatcher's `{:update_size, _}` brought a headless session back
  # to the size it asked for; a frame drawn before then was the terminal's
  # size. Here the Headless server's group leader answers like a 132x43
  # terminal and, should the engine still measure it, holds the dispatcher
  # from that moment until the read's render call is in the engine's queue,
  # so the correction lands behind it.
  describe "start/2 on a VM attached to a terminal" do
    test "renders at the requested size, not the terminal's" do
      headless = Process.whereis(Headless)
      {:group_leader, original} = Process.info(headless, :group_leader)
      test_pid = self()
      tty = spawn_link(fn -> terminal(original, test_pid, 132, 43) end)
      true = Process.group_leader(headless, tty)

      started =
        try do
          Headless.start(TestApp, id: :tty_size, width: 50, height: 12)
        after
          Process.group_leader(headless, original)
        end

      assert {:ok, id} = started

      # `session_pids/1` asks the Lifecycle for its state, which it gives only
      # after it has cast the engine its initial renders; those renders block
      # on a held dispatcher, so the read's call queues behind them.
      %{engine: engine} = session_pids(id)
      :erlang.trace(engine, true, [:receive])
      buffer = Task.async(fn -> Headless.get_buffer(id) end)

      receive do
        {:held_dispatcher, dispatcher} ->
          assert_receive {:trace, ^engine, :receive,
                          {:"$gen_call", _, :render_frame_sync_buffer}}

          :ok = :sys.resume(dispatcher)
      after
        0 -> :ok
      end

      assert {:ok, frame} = Task.await(buffer)
      assert {frame.width, frame.height} == {50, 12}
    end
  end

  # An IO device that answers geometry requests as a `columns` x `rows`
  # terminal and relays every other request to `original`. The process asking
  # for the columns is a Lifecycle in its init/1; its dispatcher is already
  # running, and is suspended before the answer goes back.
  defp terminal(original, test_pid, columns, rows) do
    receive do
      {:io_request, from, reply_as, {:get_geometry, :columns}} ->
        dispatcher = linked_dispatcher(from)
        :ok = :sys.suspend(dispatcher)
        send(test_pid, {:held_dispatcher, dispatcher})
        send(from, {:io_reply, reply_as, columns})

      {:io_request, from, reply_as, {:get_geometry, :rows}} ->
        send(from, {:io_reply, reply_as, rows})

      other ->
        send(original, other)
    end

    terminal(original, test_pid, columns, rows)
  end

  defp linked_dispatcher(lifecycle) do
    {:links, links} = Process.info(lifecycle, :links)

    Enum.find(links, fn pid ->
      is_pid(pid) and
        initial_call(pid) == {Raxol.Core.Runtime.Events.Dispatcher, :init, 1}
    end)
  end

  defp initial_call(pid) do
    case Process.info(pid, :dictionary) do
      {:dictionary, dict} -> Keyword.get(dict, :"$initial_call")
      nil -> nil
    end
  end

  # Runs `input` against session `id` with its dispatcher suspended, and
  # answers what `input` returned. While the dispatcher is suspended nothing
  # can run update/2, so an `input` that returns then has not waited for its
  # event to be handled: that fails the test. One that waits is holding a call
  # the dispatcher has yet to take, and once that call arrives `release` is
  # applied to the dispatcher.
  defp answer_with_dispatcher_held(id, input, release \\ &:sys.resume/1) do
    %{lifecycle: lifecycle, dispatcher: dispatcher, engine: engine} =
      session_pids(id)

    # Let the startup messages land, so no call but the one `input` makes
    # reaches the dispatcher.
    for pid <- [lifecycle, dispatcher, engine], do: :sys.get_state(pid)

    :ok = :sys.suspend(dispatcher)
    :erlang.trace(dispatcher, true, [:receive])
    %Task{ref: ref} = task = Task.async(fn -> input.(id) end)

    receive do
      {^ref, result} ->
        :ok = :sys.resume(dispatcher)

        flunk(
          "returned #{inspect(result)} while the dispatcher was suspended, " <>
            "before update/2 could run"
        )

      {:trace, ^dispatcher, :receive, {:"$gen_call", _from, _request}} ->
        release.(dispatcher)
    end

    Task.await(task)
  end

  defp session_pids(id) do
    %{sessions: %{^id => %{lifecycle_pid: lifecycle}}} =
      :sys.get_state(Headless)

    state = GenServer.call(lifecycle, :get_full_state)

    %{
      lifecycle: lifecycle,
      dispatcher: state.dispatcher_pid,
      engine: state.rendering_engine_pid
    }
  end
end
