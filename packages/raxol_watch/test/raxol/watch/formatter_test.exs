defmodule Raxol.Watch.FormatterTest do
  use ExUnit.Case, async: true

  alias Raxol.Watch.Formatter

  describe "format_announcement/2" do
    test "formats a simple announcement" do
      notif = Formatter.format_announcement("Server restarted")
      assert notif.title == "Raxol"
      assert notif.body == "Server restarted"
      assert notif.priority == :normal
      assert notif.badge == 0
      assert is_list(notif.actions)
    end

    test "maps high priority to high push priority with badge" do
      notif = Formatter.format_announcement("CRITICAL: Memory exhausted", :high)
      assert notif.priority == :high
      assert notif.badge == 1
    end

    test "maps low priority to silent push" do
      notif = Formatter.format_announcement("Background sync done", :low)
      assert notif.priority == :silent
    end

    test "high priority includes acknowledge action" do
      notif = Formatter.format_announcement("Alert!", :high)
      action_ids = Enum.map(notif.actions, & &1.id)
      assert "acknowledge" in action_ids
    end

    test "truncates long messages" do
      long = String.duplicate("x", 300)
      notif = Formatter.format_announcement(long)
      assert String.length(notif.body) <= Formatter.max_body_length()
      assert String.ends_with?(notif.body, "...")
    end

    test "does not truncate short messages" do
      notif = Formatter.format_announcement("Short")
      assert notif.body == "Short"
    end
  end

  describe "format_model_summary/2" do
    test "formats projections as multi-line body" do
      notif =
        Formatter.format_model_summary([
          {"Memory", "48 MB"},
          {"Processes", "412"},
          {"Status", "Healthy"}
        ])

      assert notif.body =~ "Memory: 48 MB"
      assert notif.body =~ "Processes: 412"
      assert notif.body =~ "Status: Healthy"
      assert notif.priority == :normal
      assert notif.category == "raxol_status"
    end

    test "accepts custom title" do
      notif = Formatter.format_model_summary("Dashboard", [{"CPU", "38%"}])
      assert notif.title == "Dashboard"
    end

    test "truncates long summaries" do
      projections = for i <- 1..50, do: {"Key #{i}", String.duplicate("v", 20)}
      notif = Formatter.format_model_summary(projections)
      assert String.length(notif.body) <= Formatter.max_body_length()
    end
  end

  describe "backward compatibility (W1 extensions)" do
    test "existing constructors carry nil-defaulted media fields" do
      notif = Formatter.format_announcement("hi")

      assert Map.has_key?(notif, :audio_url)
      assert Map.has_key?(notif, :image_url)
      assert Map.has_key?(notif, :media_type)
      assert Map.has_key?(notif, :location)

      assert notif.audio_url == nil
      assert notif.image_url == nil
      assert notif.media_type == nil
      assert notif.location == nil
    end

    test "every constructor preserves the untruncated text under :body_long" do
      long = String.duplicate("x", 300)
      notif = Formatter.format_announcement(long)

      assert String.length(notif.body) <= Formatter.max_body_length()
      assert notif.body_long == long
    end
  end

  describe "format_audio/4" do
    test "carries the audio_url and uses chat category + actions by default" do
      notif = Formatter.format_audio("Alice", "Voice message", "https://cdn.example.com/v.m4a")

      assert notif.title == "Alice"
      assert notif.body == "Voice message"
      assert notif.body_long == "Voice message"
      assert notif.audio_url == "https://cdn.example.com/v.m4a"
      assert notif.category == "raxol_chat"

      action_ids = Enum.map(notif.actions, & &1.id)
      assert "reply" in action_ids
      assert "mute" in action_ids
    end

    test "honors :priority, :category, :badge, :actions overrides" do
      notif =
        Formatter.format_audio("t", "b", "https://x.m4a",
          priority: :high,
          category: "custom_cat",
          badge: 5,
          actions: [%{id: "ok", label: "OK"}]
        )

      assert notif.priority == :high
      assert notif.category == "custom_cat"
      assert notif.badge == 5
      assert notif.actions == [%{id: "ok", label: "OK"}]
    end
  end

  describe "format_image/4" do
    test "carries image_url + media_type :photo by default" do
      notif = Formatter.format_image("t", "b", "https://x.jpg")
      assert notif.image_url == "https://x.jpg"
      assert notif.media_type == :photo
    end

    test "honors :media_type override" do
      notif = Formatter.format_image("t", "b", "https://x.jpg", media_type: :video_thumb)
      assert notif.media_type == :video_thumb
    end
  end

  describe "format_sticker/4" do
    test "sets media_type to :sticker" do
      notif = Formatter.format_sticker("t", "b", "https://sticker.png")
      assert notif.media_type == :sticker
      assert notif.image_url == "https://sticker.png"
    end
  end

  describe "format_location/4" do
    test "carries the location map" do
      loc = %{lat: 37.7749, lng: -122.4194, label: "SF"}
      notif = Formatter.format_location("t", "Where I am", loc)

      assert notif.location == loc
      assert notif.category == "raxol_chat"
    end

    test "accepts location without label" do
      loc = %{lat: 0.0, lng: 0.0}
      notif = Formatter.format_location("t", "b", loc)
      assert notif.location == loc
    end

    test "rejects integer coordinates at the function head" do
      assert_raise FunctionClauseError, fn ->
        Formatter.format_location("t", "b", %{lat: 37, lng: -122})
      end
    end
  end

  describe "format_long_message/3" do
    test "truncates body for the glance, keeps full text in body_long" do
      long = String.duplicate("x", 300)
      notif = Formatter.format_long_message("Title", long)

      assert String.length(notif.body) <= Formatter.max_body_length()
      assert notif.body_long == long
      assert notif.category == "raxol_chat"
    end
  end

  describe "format_chat_message/3" do
    test "is shaped like format_long_message but documented for chat use" do
      notif = Formatter.format_chat_message("Alice", "Hi there")

      assert notif.title == "Alice"
      assert notif.body == "Hi there"
      assert notif.body_long == "Hi there"
      assert notif.category == "raxol_chat"
      assert Enum.any?(notif.actions, &(&1.id == "reply"))
    end
  end

  describe "actions_for_category/1" do
    test "returns chat action set" do
      ids = Enum.map(Formatter.actions_for_category(:chat), & &1.id)
      assert ids == ["reply", "mute", "pin", "delete", "dismiss"]
    end

    test "returns default action set for :status and :alert" do
      ids_status = Enum.map(Formatter.actions_for_category(:status), & &1.id)
      ids_alert = Enum.map(Formatter.actions_for_category(:alert), & &1.id)

      assert ids_status == ["details", "dismiss"]
      assert ids_alert == ["details", "dismiss"]
    end
  end
end
