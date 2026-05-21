defmodule Raxol.Core.Accessibility.AnnouncementTest do
  use ExUnit.Case, async: false
  import Mox

  alias Raxol.Core.Accessibility, as: Accessibility
  alias Raxol.Core.AccessibilityTestHelper, as: Helper

  setup :verify_on_exit!
  setup :set_mox_global

  setup do
    Raxol.Core.I18n.init()
    :ok
  end

  describe "announce/2 related functions" do
    setup do
      prefs_name =
        String.to_atom(
          "user_prefs_announce_" <>
            Integer.to_string(System.unique_integer([:positive]))
        )

      Helper.setup_test_preferences_with_events(prefs_name)
    end

    test "announce/2 adds announcement to queue", %{pref_pid: pref_pid} do
      ref = System.unique_integer([:positive])
      :ok = Accessibility.subscribe_to_announcements(ref)

      Accessibility.announce("Test announcement", [], pref_pid)

      assert_receive {:announcement_added, ^ref,
                      %{message: "Test announcement", priority: :normal, interrupt: false}},
                     1000

      :ok = Accessibility.unsubscribe_from_announcements(ref)
    end

    test "get_next_announcement/0 retrieves and removes announcement", %{
      pref_pid: pref_pid
    } do
      ref = System.unique_integer([:positive])
      :ok = Accessibility.subscribe_to_announcements(ref)

      Accessibility.announce("First", [], pref_pid)
      Accessibility.announce("Second", [], pref_pid)

      assert_receive {:announcement_added, ^ref, %{message: "First"}}, 1000
      assert_receive {:announcement_added, ^ref, %{message: "Second"}}, 1000

      assert Accessibility.get_next_announcement(pref_pid) == "First"
      assert Accessibility.get_next_announcement(pref_pid) == "Second"
      assert Accessibility.get_next_announcement(pref_pid) == nil

      :ok = Accessibility.unsubscribe_from_announcements(ref)
    end

    test "clear_announcements/0 clears the queue", %{pref_pid: pref_pid} do
      ref = System.unique_integer([:positive])
      :ok = Accessibility.subscribe_to_announcements(ref)

      Accessibility.announce("Test", [], pref_pid)
      assert_receive {:announcement_added, ^ref, %{message: "Test"}}, 1000

      Accessibility.clear_announcements()
      assert_receive {:announcements_cleared, ^ref}, 1000

      assert Accessibility.get_next_announcement(pref_pid) == nil

      :ok = Accessibility.unsubscribe_from_announcements(ref)
    end

    test "announce/2 does nothing when screen reader is disabled", %{
      pref_pid: pref_pid
    } do
      ref = System.unique_integer([:positive])
      :ok = Accessibility.subscribe_to_announcements(ref)

      Raxol.Core.UserPreferences.set(
        Helper.pref_key(:screen_reader),
        false,
        pref_pid
      )

      Accessibility.announce("Should not be announced", [], pref_pid)

      refute_receive {:announcement_added, ^ref, _}, 1000
      assert Accessibility.get_next_announcement(pref_pid) == nil

      :ok = Accessibility.unsubscribe_from_announcements(ref)
    end

    test "announce/2 handles priority and interrupt options", %{
      pref_pid: pref_pid
    } do
      Accessibility.announce("Normal", [], pref_pid)
      Accessibility.announce("High", [priority: :high], pref_pid)
      Accessibility.announce("Low", [priority: :low], pref_pid)
      assert Accessibility.get_next_announcement(pref_pid) == "High"
      Accessibility.announce("Interrupting", [interrupt: true], pref_pid)
      assert Accessibility.get_next_announcement(pref_pid) == "Interrupting"
      assert Accessibility.get_next_announcement(pref_pid) == nil
    end

    test "announce/2 broadcasts priority and interrupt to subscribers", %{
      pref_pid: pref_pid
    } do
      ref = System.unique_integer([:positive])
      :ok = Accessibility.subscribe_to_announcements(ref)

      Accessibility.announce("urgent", [priority: :high, interrupt: true], pref_pid)

      assert_receive {:announcement_added, ^ref,
                      %{
                        message: "urgent",
                        priority: :high,
                        interrupt: true,
                        timestamp: ts
                      }},
                     1000

      assert is_integer(ts)

      :ok = Accessibility.unsubscribe_from_announcements(ref)
    end

    test "announce/2 respects :silence_announcements setting", %{
      pref_pid: pref_pid
    } do
      Raxol.Core.UserPreferences.set(
        Helper.pref_key(:silence_announcements),
        true,
        pref_pid
      )

      Accessibility.announce("Should not be announced", [], pref_pid)
      assert Accessibility.get_next_announcement(pref_pid) == nil
    end
  end
end
