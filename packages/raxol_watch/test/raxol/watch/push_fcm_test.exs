defmodule Raxol.Watch.Push.FCMTest do
  use ExUnit.Case, async: false

  alias Raxol.Watch.Push.FCM

  setup do
    on_exit(fn ->
      Application.delete_env(:raxol_watch, FCM)
    end)

    :ok
  end

  describe "push/2 config errors" do
    test "returns error when no dispatcher is configured" do
      Application.put_env(:raxol_watch, FCM, [])

      assert FCM.push("device_token", %{title: "t", body: "b"}) ==
               {:error, :no_fcm_dispatcher_configured}
    end
  end

  describe "build_notification_object/1: base + image (W3)" do
    test "returns title + body for plain notifications" do
      assert FCM.build_notification_object(%{title: "T", body: "B"}) == %{
               "title" => "T",
               "body" => "B"
             }
    end

    test "adds image field when image_url present" do
      result =
        FCM.build_notification_object(%{
          title: "T",
          body: "B",
          image_url: "https://cdn.example.com/p.jpg"
        })

      assert result == %{
               "title" => "T",
               "body" => "B",
               "image" => "https://cdn.example.com/p.jpg"
             }
    end

    test "omits image field when image_url is nil or empty" do
      for url <- [nil, ""] do
        refute Map.has_key?(
                 FCM.build_notification_object(%{title: "T", body: "B", image_url: url}),
                 "image"
               )
      end
    end
  end

  describe "build_data_payload/1: base shape" do
    test "always includes category + JSON-encoded actions" do
      data = FCM.build_data_payload(%{title: "t", body: "b", actions: []})

      assert data["category"] == "raxol_alert"
      assert data["actions"] == "[]"
    end

    test "JSON-encodes the actions list" do
      actions = [%{id: "ok", label: "OK"}, %{id: "no", label: "No"}]
      data = FCM.build_data_payload(%{title: "t", body: "b", actions: actions})

      decoded = Jason.decode!(data["actions"])
      assert decoded == [%{"id" => "ok", "label" => "OK"}, %{"id" => "no", "label" => "No"}]
    end

    test "respects custom category" do
      data = FCM.build_data_payload(%{title: "t", body: "b", actions: [], category: "raxol_chat"})

      assert data["category"] == "raxol_chat"
    end
  end

  describe "build_data_payload/1: media (W3)" do
    test "audio_url string passes through under raxol_audio_url" do
      data =
        FCM.build_data_payload(%{
          title: "t",
          body: "b",
          actions: [],
          audio_url: "https://cdn.example.com/v.m4a"
        })

      assert data["raxol_audio_url"] == "https://cdn.example.com/v.m4a"
    end

    test "media_type atom serializes as string" do
      data =
        FCM.build_data_payload(%{
          title: "t",
          body: "b",
          actions: [],
          media_type: :sticker
        })

      assert data["raxol_media_type"] == "sticker"
    end

    test "no media fields keeps the data shape minimal" do
      data = FCM.build_data_payload(%{title: "t", body: "b", actions: []})

      refute Map.has_key?(data, "raxol_audio_url")
      refute Map.has_key?(data, "raxol_media_type")
      refute Map.has_key?(data, "raxol_location")
      refute Map.has_key?(data, "raxol_body_long")
    end
  end

  describe "build_data_payload/1: location (W3)" do
    test "location is JSON-encoded (FCM data values must be strings)" do
      loc = %{lat: 37.7749, lng: -122.4194, label: "SF"}

      data = FCM.build_data_payload(%{title: "t", body: "b", actions: [], location: loc})

      assert is_binary(data["raxol_location"])

      assert Jason.decode!(data["raxol_location"]) == %{
               "lat" => 37.7749,
               "lng" => -122.4194,
               "label" => "SF"
             }
    end

    test "location without label works too" do
      loc = %{lat: 0.0, lng: 0.0}

      data = FCM.build_data_payload(%{title: "t", body: "b", actions: [], location: loc})

      assert Jason.decode!(data["raxol_location"]) == %{"lat" => 0.0, "lng" => 0.0}
    end
  end

  describe "build_data_payload/1: body_long (W3)" do
    test "body_long is included when distinct from body" do
      data =
        FCM.build_data_payload(%{
          title: "t",
          body: "short",
          actions: [],
          body_long: "full long content"
        })

      assert data["raxol_body_long"] == "full long content"
    end

    test "body_long is omitted when it matches body" do
      data =
        FCM.build_data_payload(%{
          title: "t",
          body: "same",
          actions: [],
          body_long: "same"
        })

      refute Map.has_key?(data, "raxol_body_long")
    end
  end

  describe "build_data_payload/1: all-string contract" do
    test "every data value is a string (FCM requirement)" do
      data =
        FCM.build_data_payload(%{
          title: "t",
          body: "short",
          actions: [%{id: "ok", label: "OK"}],
          audio_url: "https://x.m4a",
          media_type: :photo,
          location: %{lat: 1.0, lng: 2.0},
          body_long: "long body"
        })

      for {key, value} <- data do
        assert is_binary(value), "data[#{inspect(key)}] = #{inspect(value)} is not a string"
      end
    end
  end
end
