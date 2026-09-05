defmodule Raxol.Animation.StateSettingsContractTest do
  @moduledoc """
  The animation settings contract: `StateManager.get_settings/0` returns a map
  on every path, including the one where the server was started by
  `ensure_started/0` rather than by `Framework.init/2`.

  `ensure_started/0` starts the singleton unlinked. A rendering engine or
  ExUnit process that happens to be the first caller can still exit; the
  server, and any in-flight animations, must outlive that.
  """

  use ExUnit.Case, async: false

  alias Raxol.Animation.Adaptation
  alias Raxol.Animation.Framework
  alias Raxol.Animation.StateManager
  alias Raxol.Animation.StateServer
  alias Raxol.Core.UserPreferences

  setup do
    prefs_name = __MODULE__.UserPreferences

    {:ok, _pid} =
      start_supervised({UserPreferences, [name: prefs_name, test_mode?: true]})

    stop_state_server()
    on_exit(&stop_state_server/0)

    {:ok, %{prefs: prefs_name}}
  end

  defp stop_state_server do
    case Process.whereis(StateServer) do
      nil ->
        :ok

      pid ->
        try do
          GenServer.stop(pid, :normal, 1000)
        catch
          :exit, _ -> :ok
        end
    end
  end

  describe "settings shape" do
    test "get_settings/0 returns a map when the server starts itself" do
      settings = StateManager.get_settings()

      assert is_map(settings), "expected a map, got: #{inspect(settings)}"
    end

    test "create_animation/2 falls back to the default duration" do
      animation =
        Framework.create_animation(:lazy_started, %{
          type: :fade,
          from: 0,
          to: 1,
          target_path: [:opacity]
        })

      assert animation.duration == Raxol.Core.Defaults.animation_duration_ms()
    end

    test "create_animation/2 survives the server dying under a live framework",
         %{prefs: prefs} do
      Framework.init(%{default_duration: 111}, prefs)
      assert StateManager.get_settings().default_duration == 111

      # Explicit stop, not a linked-caller exit: the server can still die
      # (supervisor restart, test cleanup) and the next call must recreate it.
      stop_state_server()

      animation =
        Framework.create_animation(:after_restart, %{
          type: :fade,
          from: 0,
          to: 1,
          target_path: [:opacity]
        })

      assert animation.duration == Raxol.Core.Defaults.animation_duration_ms()
    end

    test "killing the process that called ensure_started does not drop the server" do
      parent = self()

      starter =
        spawn(fn ->
          StateManager.ensure_started()
          send(parent, {:started, Process.whereis(StateServer)})
          Process.sleep(:infinity)
        end)

      assert_receive {:started, pid}, 500
      assert is_pid(pid)
      ref = Process.monitor(pid)

      Process.exit(starter, :kill)

      refute_receive {:DOWN, ^ref, :process, ^pid, _}, 100
      assert Process.alive?(pid)
      assert Process.whereis(StateServer) == pid
    end

    test "an unrelated process exit does not drop in-flight animations", %{
      prefs: prefs
    } do
      Framework.init(%{}, prefs)

      Framework.create_animation(:keep_alive, %{
        type: :fade,
        from: 0.0,
        to: 1.0,
        duration: 50,
        easing: :linear,
        target_path: [:opacity]
      })

      assert :ok = Framework.start_animation(:keep_alive, "box", %{}, prefs)

      starter =
        spawn(fn ->
          StateManager.ensure_started()
          Process.sleep(:infinity)
        end)

      Process.exit(starter, :kill)
      Process.sleep(10)

      assert StateManager.get_active_animation("box", :keep_alive)

      Process.sleep(60)

      model = %{elements: %{"box" => %{opacity: 0.0}}}
      animated = Framework.apply_animations_to_state(model, prefs)
      assert_in_delta get_in(animated, [:elements, "box", :opacity]), 1.0, 0.01
    end

    test "start_animation/2 reads accessibility flags off a self-started server" do
      # `Lifecycle.do_start_animation/4` reads :reduced_motion,
      # :cognitive_accessibility and :disable_all_animations off the same
      # settings, so the whole create-then-start path has to survive a server
      # nobody has initialized.
      Framework.create_animation(:flags, %{
        type: :fade,
        duration: 10,
        from: 0,
        to: 1,
        target_path: [:opacity]
      })

      assert :ok == Framework.start_animation(:flags, "element")
    end

    test "re_adapt_animations_if_needed/1 tolerates cleared settings", %{
      prefs: prefs
    } do
      Framework.init(%{}, prefs)
      # `Framework.stop/0` clears the settings back to an empty map.
      Framework.stop()

      assert [] == Adaptation.re_adapt_animations_if_needed(prefs)
    end
  end

  describe "init options" do
    test "init/2 accepts the documented keyword form", %{prefs: prefs} do
      assert :ok ==
               Framework.init(
                 [reduced_motion: true, default_duration: 42],
                 prefs
               )

      settings = StateManager.get_settings()
      assert settings.reduced_motion == true
      assert settings.default_duration == 42
    end

    test "init/2 still accepts a settings map", %{prefs: prefs} do
      assert :ok == Framework.init(%{default_duration: 43}, prefs)
      assert StateManager.get_settings().default_duration == 43
    end
  end

  describe "state server contract" do
    test "a supervisor-style child spec yields map settings" do
      {:ok, pid} = StateServer.start_link(name: StateServer)

      assert %{} == StateServer.get_settings(pid)
    end

    test "settings can be seeded through the :settings option" do
      {:ok, pid} =
        StateServer.start_link(name: StateServer, settings: %{frame_ms: 7})

      assert %{frame_ms: 7} == StateServer.get_settings(pid)
    end

    test "storing non-map settings is rejected rather than corrupting state" do
      assert_raise FunctionClauseError, fn ->
        StateManager.init(reduced_motion: true)
      end
    end
  end
end
