defmodule Raxol.Core.Accessibility.EnableDisableTest do
  @moduledoc """
  Tests for the accessibility enable/disable functionality, including
  preference application, announcement handling, and state management.
  """
  use ExUnit.Case, async: false
  import Mox

  alias Raxol.Core.Accessibility, as: Accessibility
  alias Raxol.Core.AccessibilityTestHelper, as: Helper

  setup :verify_on_exit!
  setup :set_mox_global

  setup do
    Raxol.Core.I18n.init()
    on_exit(&Raxol.Core.I18n.cleanup/0)
    :ok
  end

  describe "enable/1 and disable/0" do
    setup do
      prefs_name =
        String.to_atom(
          "user_prefs_enable_disable_" <>
            Integer.to_string(System.unique_integer([:positive]))
        )

      {:ok, context} = Helper.setup_test_preferences_with_events(prefs_name)
      context
    end

    test "enable/1 applies default preferences if none are set", %{
      pref_pid: pref_pid
    } do
      # Set prefs to nil initially
      Raxol.Core.UserPreferences.set(
        Helper.pref_key(:high_contrast),
        nil,
        pref_pid
      )

      Raxol.Core.UserPreferences.set(
        Helper.pref_key(:reduced_motion),
        nil,
        pref_pid
      )

      Raxol.Core.UserPreferences.set(
        Helper.pref_key(:large_text),
        nil,
        pref_pid
      )

      # Disable first to clear handlers etc.
      Accessibility.disable(pref_pid)

      Helper.wait_for_state(fn ->
        Accessibility.get_option(:enabled, pref_pid, false) == false
      end)

      # Enable reads preferences
      Accessibility.enable([], pref_pid)

      Helper.wait_for_state(fn ->
        Accessibility.get_option(:enabled, pref_pid, false) == true
      end)

      # Assert default values
      assert Raxol.Core.UserPreferences.get(
               Helper.pref_key(:high_contrast),
               pref_pid
             ) ==
               false

      assert Raxol.Core.UserPreferences.get(
               Helper.pref_key(:reduced_motion),
               pref_pid
             ) ==
               false

      assert Raxol.Core.UserPreferences.get(
               Helper.pref_key(:large_text),
               pref_pid
             ) ==
               false

      assert Raxol.Core.UserPreferences.get(
               Helper.pref_key(:screen_reader),
               pref_pid
             ) ==
               true

      assert Accessibility.get_text_scale(pref_pid) == 1.0
    end

    test "enable/1 applies custom options over defaults", %{
      pref_pid: pref_pid
    } do
      # Set prefs to nil initially
      Raxol.Core.UserPreferences.set(
        Helper.pref_key(:high_contrast),
        nil,
        pref_pid
      )

      Raxol.Core.UserPreferences.set(
        Helper.pref_key(:reduced_motion),
        nil,
        pref_pid
      )

      Raxol.Core.UserPreferences.set(
        Helper.pref_key(:screen_reader),
        nil,
        pref_pid
      )

      Accessibility.disable(pref_pid)

      Helper.wait_for_state(fn ->
        Accessibility.get_option(:enabled, pref_pid, false) == false
      end)

      custom_opts = [
        high_contrast: true,
        reduced_motion: true,
        screen_reader: false
      ]

      Accessibility.enable(custom_opts, pref_pid)

      Helper.wait_for_state(fn ->
        Accessibility.get_option(:enabled, pref_pid, false) == true
      end)

      assert Accessibility.get_option(:high_contrast, pref_pid, false) == true

      assert Accessibility.get_option(:reduced_motion, pref_pid, false) ==
               true

      assert Accessibility.get_option(:screen_reader, pref_pid, true) == false
      assert Accessibility.get_text_scale(pref_pid) == 1.0
    end

    test "disable/0 stops functionality", %{
      pref_pid: pref_pid
    } do
      Accessibility.enable([], pref_pid)

      Helper.wait_for_state(fn ->
        Accessibility.get_option(:enabled, pref_pid, false) == true
      end)

      assert Accessibility.get_option(:enabled, pref_pid, false) == true
      Accessibility.announce("Test before disable", [], pref_pid)

      assert Accessibility.get_next_announcement(pref_pid) ==
               "Test before disable"

      Accessibility.disable(pref_pid)

      Helper.wait_for_state(fn ->
        Accessibility.get_option(:enabled, pref_pid, false) == false
      end)

      Accessibility.announce("Test after disable", [], pref_pid)
      assert Accessibility.get_next_announcement(pref_pid) == nil
    end
  end
end
