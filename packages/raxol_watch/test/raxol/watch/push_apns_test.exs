defmodule Raxol.Watch.Push.APNSTest do
  use ExUnit.Case, async: false

  alias Raxol.Watch.Push.APNS

  setup do
    on_exit(fn ->
      Application.delete_env(:raxol_watch, APNS)
    end)

    :ok
  end

  describe "push/2 config errors" do
    test "returns error when no dispatcher is configured" do
      Application.put_env(:raxol_watch, APNS, topic: "io.example.app")

      assert APNS.push("device_token", %{title: "t", body: "b"}) ==
               {:error, :no_apns_dispatcher_configured}
    end

    test "returns error when no topic is configured" do
      Application.put_env(:raxol_watch, APNS, dispatcher: SomeDispatcher)

      assert APNS.push("device_token", %{title: "t", body: "b"}) ==
               {:error, :no_apns_topic_configured}
    end

    test "returns error when topic is an empty string" do
      Application.put_env(:raxol_watch, APNS,
        dispatcher: SomeDispatcher,
        topic: ""
      )

      assert APNS.push("device_token", %{title: "t", body: "b"}) ==
               {:error, :no_apns_topic_configured}
    end

    test "returns error when topic is not a binary" do
      Application.put_env(:raxol_watch, APNS,
        dispatcher: SomeDispatcher,
        topic: :not_a_string
      )

      assert {:error, {:bad_apns_topic, :not_a_string}} =
               APNS.push("device_token", %{title: "t", body: "b"})
    end
  end

  describe "build_payload/1: base shape" do
    test "builds the conventional aps wrapper with title, body, badge, category" do
      payload = APNS.build_payload(%{title: "T", body: "B", badge: 3, category: "raxol_chat"})

      assert payload == %{
               "aps" => %{
                 "alert" => %{"title" => "T", "body" => "B"},
                 "badge" => 3,
                 "category" => "raxol_chat"
               }
             }
    end

    test "defaults badge to 0 and category to raxol_alert" do
      payload = APNS.build_payload(%{title: "T", body: "B"})

      assert payload["aps"]["badge"] == 0
      assert payload["aps"]["category"] == "raxol_alert"
    end
  end

  describe "build_payload/1: priority (W2)" do
    test "high priority sets sound and interruption-level: time-sensitive" do
      payload = APNS.build_payload(%{title: "T", body: "B", priority: :high})

      assert payload["aps"]["sound"] == "default"
      assert payload["aps"]["interruption-level"] == "time-sensitive"
    end

    test "normal priority omits sound and interruption-level" do
      payload = APNS.build_payload(%{title: "T", body: "B", priority: :normal})

      refute Map.has_key?(payload["aps"], "sound")
      refute Map.has_key?(payload["aps"], "interruption-level")
    end
  end

  describe "build_payload/1: media (W2)" do
    test "audio_url adds mutable-content: 1 and raxol.audio_url custom data" do
      payload =
        APNS.build_payload(%{
          title: "Alice",
          body: "Voice",
          audio_url: "https://cdn.example.com/v.m4a"
        })

      assert payload["aps"]["mutable-content"] == 1
      assert payload["raxol.audio_url"] == "https://cdn.example.com/v.m4a"
    end

    test "image_url adds mutable-content: 1 and raxol.image_url custom data" do
      payload =
        APNS.build_payload(%{
          title: "Bob",
          body: "Photo",
          image_url: "https://cdn.example.com/p.jpg"
        })

      assert payload["aps"]["mutable-content"] == 1
      assert payload["raxol.image_url"] == "https://cdn.example.com/p.jpg"
    end

    test "media_type atom serializes as string in custom data" do
      payload =
        APNS.build_payload(%{
          title: "t",
          body: "b",
          image_url: "https://x.png",
          media_type: :sticker
        })

      assert payload["raxol.media_type"] == "sticker"
    end

    test "no media leaves mutable-content unset" do
      payload = APNS.build_payload(%{title: "t", body: "b"})
      refute Map.has_key?(payload["aps"], "mutable-content")
    end
  end

  describe "build_payload/1: location (W2)" do
    test "location passes through under raxol.location custom data" do
      loc = %{lat: 37.7749, lng: -122.4194, label: "SF"}
      payload = APNS.build_payload(%{title: "t", body: "b", location: loc})

      assert payload["raxol.location"] == loc
    end

    test "location does not set mutable-content (no asset to fetch)" do
      payload =
        APNS.build_payload(%{title: "t", body: "b", location: %{lat: 0.0, lng: 0.0}})

      refute Map.has_key?(payload["aps"], "mutable-content")
    end
  end

  describe "build_payload/1: body_long (W2)" do
    test "body_long passes through when distinct from body" do
      payload =
        APNS.build_payload(%{
          title: "t",
          body: "short glance",
          body_long: "full detailed text..."
        })

      assert payload["raxol.body_long"] == "full detailed text..."
    end

    test "body_long is omitted when it matches body (deduplication)" do
      payload =
        APNS.build_payload(%{
          title: "t",
          body: "same text",
          body_long: "same text"
        })

      refute Map.has_key?(payload, "raxol.body_long")
    end

    test "nil body_long is omitted" do
      payload = APNS.build_payload(%{title: "t", body: "b", body_long: nil})
      refute Map.has_key?(payload, "raxol.body_long")
    end
  end

  describe "build_payload/1: kitchen sink" do
    test "all rich fields populate the payload correctly together" do
      notif = %{
        title: "Alice",
        body: "...",
        body_long: "Full long content from Alice's voice message transcription.",
        priority: :high,
        category: "raxol_chat",
        badge: 2,
        audio_url: "https://cdn.example.com/v.m4a",
        image_url: "https://cdn.example.com/thumb.jpg",
        media_type: :video_thumb,
        location: %{lat: 1.0, lng: 2.0, label: "Home"}
      }

      payload = APNS.build_payload(notif)

      assert payload["aps"]["category"] == "raxol_chat"
      assert payload["aps"]["badge"] == 2
      assert payload["aps"]["sound"] == "default"
      assert payload["aps"]["interruption-level"] == "time-sensitive"
      assert payload["aps"]["mutable-content"] == 1
      assert payload["raxol.audio_url"] == "https://cdn.example.com/v.m4a"
      assert payload["raxol.image_url"] == "https://cdn.example.com/thumb.jpg"
      assert payload["raxol.media_type"] == "video_thumb"
      assert payload["raxol.location"] == %{lat: 1.0, lng: 2.0, label: "Home"}
      assert payload["raxol.body_long"] =~ "Full long content"
    end
  end
end
