defmodule Raxol.Agent.Code.ShareLiveTest do
  # Callback-level tests (the Symphony DashboardLive pattern): mount and
  # handle_info are exercised directly; the ~H template is compile-checked
  # by Phoenix.LiveView itself. async: false — the share secret rides
  # app env.
  use ExUnit.Case, async: false

  alias Raxol.Agent.Code.Replay
  alias Raxol.Agent.Code.ShareLive
  alias Raxol.Agent.Code.ShareToken
  alias Raxol.Agent.Journal.FileStore

  @secret "share-live-secret"

  setup do
    Application.put_env(:raxol_agent, :share_secret, @secret)
    on_exit(fn -> Application.delete_env(:raxol_agent, :share_secret) end)

    base =
      Path.join(
        System.tmp_dir!(),
        "raxol-share-live-#{System.os_time(:millisecond)}-" <>
          "#{System.unique_integer([:positive])}"
      )

    prev = System.get_env("RAXOL_SESSIONS_DIR")
    System.put_env("RAXOL_SESSIONS_DIR", base)

    on_exit(fn ->
      if prev,
        do: System.put_env("RAXOL_SESSIONS_DIR", prev),
        else: System.delete_env("RAXOL_SESSIONS_DIR")

      File.rm_rf!(base)
    end)

    %{base: base}
  end

  # A minimal socket: `connected?/1` reads transport_pid; callbacks only
  # touch assigns.
  defp socket(connected?) do
    %Phoenix.LiveView.Socket{
      assigns: %{__changed__: %{}},
      transport_pid: if(connected?, do: self())
    }
  end

  defp seed_session(session_id) do
    {:ok, journal} = FileStore.open(session_id, [])

    events = [
      %{
        v: 0,
        session_id: session_id,
        turn_id: "t1",
        ts: 1,
        family: :loop,
        type: :turn_started,
        tier: :durable,
        payload: %{"prompt" => "shared prompt"}
      },
      %{
        v: 0,
        session_id: session_id,
        turn_id: "t1",
        ts: 2,
        family: :loop,
        type: :item_started,
        tier: :durable,
        payload: %{"item_id" => "i1", "item_type" => "message"}
      },
      %{
        v: 0,
        session_id: session_id,
        turn_id: "t1",
        ts: 3,
        family: :loop,
        type: :item_completed,
        tier: :durable,
        payload: %{
          "item_id" => "i1",
          "item_type" => "message",
          "content" => "shared answer"
        }
      },
      %{
        v: 0,
        session_id: session_id,
        turn_id: "t1",
        ts: 4,
        family: :loop,
        type: :turn_completed,
        tier: :durable,
        payload: %{"final" => true}
      }
    ]

    Enum.each(events, fn event ->
      {:ok, _offset} = FileStore.append(journal, event)
    end)

    :ok = FileStore.close(journal)
  end

  test "a valid token replays the session's transcript (static mount)" do
    seed_session("sess-shared")
    token = ShareToken.sign("sess-shared", @secret)

    {:ok, socket} = ShareLive.mount(%{"token" => token}, %{}, socket(false))

    assert socket.assigns.error == nil
    assert socket.assigns.session_id == "sess-shared"
    assert socket.assigns.transcript =~ "> shared prompt"
    assert socket.assigns.transcript =~ "shared answer"
  end

  test "a connected mount attaches live and folds new records" do
    seed_session("sess-live")
    token = ShareToken.sign("sess-live", @secret)

    {:ok, socket} = ShareLive.mount(%{"token" => token}, %{}, socket(true))
    assert socket.assigns.transcript =~ "shared answer"

    # A record arriving over the live tail folds into the transcript.
    live_record = %{
      "id" => 5,
      "turn_id" => "t2",
      "ts" => 5,
      "family" => "loop",
      "type" => "turn_started",
      "tier" => "durable",
      "payload" => %{"prompt" => "a later prompt"}
    }

    {:noreply, socket} =
      ShareLive.handle_info({:reattach_live, "sess-live", live_record}, socket)

    assert socket.assigns.transcript =~ "> a later prompt"
  end

  test "invalid and expired tokens close the view" do
    {:ok, socket} =
      ShareLive.mount(%{"token" => "garbage"}, %{}, socket(false))

    assert socket.assigns.error =~ "invalid share link"

    expired = ShareToken.sign("sess-x", @secret, now_s: 0, ttl_s: 1)

    {:ok, socket} =
      ShareLive.mount(%{"token" => expired}, %{}, socket(false))

    assert socket.assigns.error =~ "expired"
  end

  test "the transcript honors rewind markers like --replay does" do
    seed_session("sess-rw")

    {:ok, journal} = FileStore.open("sess-rw", [])

    marker = %{
      v: 0,
      session_id: "sess-rw",
      turn_id: nil,
      ts: 9,
      family: :meta,
      type: :rewind,
      tier: :durable,
      payload: %{"dropped_turn" => "t1"}
    }

    {:ok, _offset} = FileStore.append(journal, marker)
    :ok = FileStore.close(journal)

    token = ShareToken.sign("sess-rw", @secret)
    {:ok, socket} = ShareLive.mount(%{"token" => token}, %{}, socket(false))

    refute socket.assigns.transcript =~ "shared answer"
  end

  test "decode_records is what both replay and the share surface fold" do
    seed_session("sess-parity")
    {:ok, records} = FileStore.read_records("sess-parity")
    text = records |> Replay.decode_records() |> Replay.transcript_text()
    assert text =~ "shared answer"
  end
end
