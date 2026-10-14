defmodule Raxol.Core.UserPreferencesTest do
  @moduledoc """
  Tests for the Raxol.Core.UserPreferences GenServer.

  Each test starts a uniquely-named instance via start_supervised! to avoid
  conflicts with the global singleton that the application supervision tree
  may have running.
  """
  use ExUnit.Case, async: false

  alias Raxol.Core.UserPreferences

  # Start a fresh, isolated UserPreferences instance for each test.
  setup do
    name =
      String.to_atom("user_prefs_test_#{System.unique_integer([:positive])}")

    pid = start_supervised!({UserPreferences, [test_mode?: true, name: name]})

    {:ok, name: name, pid: pid}
  end

  describe "default_preferences/0" do
    test "returns a map with expected top-level keys" do
      defaults = UserPreferences.default_preferences()

      assert is_map(defaults)
      assert Map.has_key?(defaults, :theme)
      assert Map.has_key?(defaults, :terminal)
      assert Map.has_key?(defaults, :accessibility)
      assert Map.has_key?(defaults, :keybindings)
    end

    test "default theme active_id is :default" do
      defaults = UserPreferences.default_preferences()

      assert defaults.theme.active_id == :default
    end

    test "default accessibility settings" do
      defaults = UserPreferences.default_preferences()

      assert defaults.accessibility.enabled == true
      assert defaults.accessibility.screen_reader == true
      assert defaults.accessibility.high_contrast == false
      assert defaults.accessibility.reduced_motion == false
      assert defaults.accessibility.keyboard_focus == true
      assert defaults.accessibility.large_text == false
      assert defaults.accessibility.silence_announcements == false
    end
  end

  describe "get_all/1" do
    test "returns the full default preferences map on a fresh instance", ctx do
      all = UserPreferences.get_all(ctx.name)
      defaults = UserPreferences.default_preferences()

      assert all.theme == defaults.theme
      assert all.accessibility == defaults.accessibility
    end
  end

  describe "get/2" do
    test "retrieves a top-level preference by atom key", ctx do
      theme = UserPreferences.get(:theme, ctx.name)

      assert theme == %{active_id: :default}
    end

    test "retrieves a nested preference by key path list", ctx do
      value = UserPreferences.get([:accessibility, :high_contrast], ctx.name)

      assert value == false
    end

    test "returns nil for a non-existent key", ctx do
      value = UserPreferences.get(:nonexistent, ctx.name)

      assert value == nil
    end

    test "returns nil for a non-existent nested path", ctx do
      value = UserPreferences.get([:theme, :nonexistent], ctx.name)

      assert value == nil
    end
  end

  describe "set/3" do
    test "sets a top-level preference", ctx do
      :ok = UserPreferences.set(:keybindings, %{quit: "ctrl+q"}, ctx.name)
      assert_receive {:preferences_applied, _}, 1000

      result = UserPreferences.get(:keybindings, ctx.name)

      assert result == %{quit: "ctrl+q"}
    end

    test "sets a nested preference by key path", ctx do
      :ok =
        UserPreferences.set(
          [:accessibility, :high_contrast],
          true,
          ctx.name
        )

      assert_receive {:preferences_applied, _}, 1000

      assert UserPreferences.get([:accessibility, :high_contrast], ctx.name) ==
               true
    end

    test "returns :ok when setting same value (no change)", ctx do
      # The default is false
      :ok =
        UserPreferences.set(
          [:accessibility, :high_contrast],
          false,
          ctx.name
        )

      # Should still return :ok even when value is unchanged
      assert :ok ==
               UserPreferences.set(
                 [:accessibility, :high_contrast],
                 false,
                 ctx.name
               )
    end

    test "updates are visible via get/2", ctx do
      :ok =
        UserPreferences.set(
          [:accessibility, :reduced_motion],
          true,
          ctx.name
        )

      assert_receive {:preferences_applied, _}, 1000

      assert UserPreferences.get([:accessibility, :reduced_motion], ctx.name) ==
               true
    end

    test "sends {:preferences_applied, _} message on value change", ctx do
      :ok =
        UserPreferences.set(
          [:accessibility, :large_text],
          true,
          ctx.name
        )

      assert_receive {:preferences_applied, _name}, 1000
    end
  end

  describe "set_preferences/2" do
    test "deep merges new preferences into existing ones", ctx do
      new_prefs = %{
        accessibility: %{high_contrast: true, reduced_motion: true}
      }

      :ok = UserPreferences.set_preferences(new_prefs, ctx.name)
      assert_receive {:preferences_applied, _}, 1000

      all = UserPreferences.get_all(ctx.name)

      # Merged values
      assert all.accessibility.high_contrast == true
      assert all.accessibility.reduced_motion == true
      # Untouched values preserved
      assert all.accessibility.enabled == true
      assert all.accessibility.screen_reader == true
      assert all.accessibility.large_text == false
    end

    test "preserves top-level keys not present in the update", ctx do
      original_terminal = UserPreferences.get(:terminal, ctx.name)

      :ok =
        UserPreferences.set_preferences(
          %{accessibility: %{large_text: true}},
          ctx.name
        )

      assert_receive {:preferences_applied, _}, 1000

      assert UserPreferences.get(:terminal, ctx.name) == original_terminal
    end

    test "sends {:preferences_applied, _} message", ctx do
      :ok =
        UserPreferences.set_preferences(
          %{keybindings: %{copy: "ctrl+c"}},
          ctx.name
        )

      assert_receive {:preferences_applied, _}, 1000
    end
  end

  describe "reset_to_defaults_for_test!/1" do
    test "restores all preferences to defaults after modifications", ctx do
      :ok =
        UserPreferences.set(
          [:accessibility, :high_contrast],
          true,
          ctx.name
        )

      assert_receive {:preferences_applied, _}, 1000

      assert UserPreferences.get([:accessibility, :high_contrast], ctx.name) ==
               true

      :ok = UserPreferences.reset_to_defaults_for_test!(ctx.name)

      defaults = UserPreferences.default_preferences()

      assert UserPreferences.get([:accessibility, :high_contrast], ctx.name) ==
               defaults.accessibility.high_contrast
    end

    test "returns :ok when process is not running" do
      assert :ok ==
               UserPreferences.reset_to_defaults_for_test!(:nonexistent_process)
    end
  end

  describe "get_theme_id/1" do
    test "returns :default for a fresh instance", ctx do
      assert UserPreferences.get_theme_id(ctx.name) == :default
    end

    test "returns the theme id after setting it", ctx do
      # Ensure the atom exists so normalize_theme_id can convert it
      _ = :solarized

      :ok =
        UserPreferences.set(
          [:theme, :active_id],
          :solarized,
          ctx.name
        )

      assert_receive {:preferences_applied, _}, 1000

      assert UserPreferences.get_theme_id(ctx.name) == :solarized
    end

    test "returns :default when theme is set to nil", ctx do
      :ok = UserPreferences.set([:theme, :active_id], nil, ctx.name)
      assert_receive {:preferences_applied, _}, 1000

      # nil -> falls through to get(:theme, ...) which returns the map,
      # which normalize_theme_id/1 handles as a non-atom/non-binary -> :default
      assert UserPreferences.get_theme_id(ctx.name) == :default
    end
  end

  describe "save!/1" do
    test "returns :ok on successful save", ctx do
      result = UserPreferences.save!(ctx.name)

      assert result == :ok
    end
  end

  describe "concurrent set operations" do
    test "all sets are applied correctly", ctx do
      keys =
        [:enabled, :screen_reader, :high_contrast, :reduced_motion, :large_text]

      Enum.each(keys, fn key ->
        :ok =
          UserPreferences.set([:accessibility, key], true, ctx.name)
      end)

      # Drain all notification messages
      Enum.each(keys, fn _key ->
        receive do
          {:preferences_applied, _} -> :ok
        after
          1000 -> :ok
        end
      end)

      all = UserPreferences.get_all(ctx.name)

      Enum.each(keys, fn key ->
        assert all.accessibility[key] == true,
               "Expected accessibility.#{key} to be true"
      end)
    end
  end

  describe "default_preferences/0 terminal section" do
    import ExUnit.CaptureLog

    # The key is read from :raxol_core first, then from :raxol_terminal's app
    # env. Clear both and put back whatever was there.
    setup do
      saved =
        for app <- [:raxol_core, :raxol_terminal] do
          {app, Application.fetch_env(app, :default_terminal_preferences)}
        end

      Enum.each(saved, fn {app, _} ->
        Application.delete_env(app, :default_terminal_preferences)
      end)

      on_exit(fn ->
        Enum.each(saved, fn
          {app, {:ok, value}} -> Application.put_env(app, :default_terminal_preferences, value)
          {app, :error} -> Application.delete_env(app, :default_terminal_preferences)
        end)
      end)

      :ok
    end

    test "is empty when unset" do
      assert UserPreferences.default_preferences().terminal == %{}
    end

    test "uses a configured map" do
      Application.put_env(:raxol_core, :default_terminal_preferences, %{width: 120})

      assert UserPreferences.default_preferences().terminal == %{width: 120}
    end

    test "calls a configured {m, f, a}" do
      Application.put_env(:raxol_core, :default_terminal_preferences, {Map, :new, [[width: 132]]})

      assert UserPreferences.default_preferences().terminal == %{width: 132}
    end

    test "falls back to the :raxol_terminal app env" do
      Application.put_env(:raxol_terminal, :default_terminal_preferences, %{width: 80})

      assert UserPreferences.default_preferences().terminal == %{width: 80}
    end

    test ":raxol_core config overrides the :raxol_terminal default" do
      Application.put_env(:raxol_terminal, :default_terminal_preferences, %{width: 80})
      Application.put_env(:raxol_core, :default_terminal_preferences, %{width: 100})

      assert UserPreferences.default_preferences().terminal == %{width: 100}
    end

    for {label, value} <- [
          {"a keyword list", [width: 80]},
          {"nil", nil},
          {"a two-tuple", {Map, :new}},
          {"an mfa whose module does not exist", {Raxol.NoSuchModule, :defaults, []}},
          {"an mfa that returns a non-map", {Kernel, :self, []}}
        ] do
      test "warns and yields %{} for #{label}" do
        Application.put_env(
          :raxol_core,
          :default_terminal_preferences,
          unquote(Macro.escape(value))
        )

        log =
          capture_log([level: :warning], fn ->
            assert UserPreferences.default_preferences().terminal == %{}
          end)

        assert log =~ "Ignoring :default_terminal_preferences"
      end
    end
  end
end
