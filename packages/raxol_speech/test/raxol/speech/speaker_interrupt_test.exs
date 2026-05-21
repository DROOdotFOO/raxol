defmodule Raxol.Speech.SpeakerInterruptTest do
  use ExUnit.Case, async: false

  alias Raxol.Speech.{Speaker, TTS.Tracking}

  setup do
    start_supervised!(Tracking)
    start_supervised!({Speaker, tts_backend: Tracking})
    Tracking.clear()
    :ok
  end

  defp wait_for_calls(n) do
    Enum.reduce_while(1..50, nil, fn _, _ ->
      if length(Tracking.calls()) >= n do
        {:halt, :ok}
      else
        Process.sleep(10)
        {:cont, nil}
      end
    end)
  end

  describe "priority interrupt" do
    test "high-priority announcement calls stop/0 before speak/1" do
      send(Speaker, {:announcement_added, make_ref(),
                     %{message: "URGENT", priority: :high}})

      assert :ok = wait_for_calls(2)
      assert [:stop, {:speak, "URGENT"}] = Tracking.calls()
    end

    test "normal-priority announcement does NOT call stop/0 first" do
      send(Speaker, {:announcement_added, make_ref(),
                     %{message: "info", priority: :normal}})

      assert :ok = wait_for_calls(1)
      assert [{:speak, "info"}] = Tracking.calls()
    end

    test "back-to-back high-priority announcements each interrupt" do
      send(Speaker, {:announcement_added, make_ref(),
                     %{message: "first", priority: :high}})
      send(Speaker, {:announcement_added, make_ref(),
                     %{message: "second", priority: :high}})

      assert :ok = wait_for_calls(4)
      assert [:stop, {:speak, "first"}, :stop, {:speak, "second"}] = Tracking.calls()
    end

    test "low-priority announcement is treated as normal (no interrupt)" do
      send(Speaker, {:announcement_added, make_ref(),
                     %{message: "low", priority: :low}})

      assert :ok = wait_for_calls(1)
      assert [{:speak, "low"}] = Tracking.calls()
    end
  end
end
