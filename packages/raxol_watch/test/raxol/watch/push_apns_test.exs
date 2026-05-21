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
end
