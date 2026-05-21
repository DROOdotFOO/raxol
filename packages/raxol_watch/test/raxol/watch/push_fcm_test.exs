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
end
