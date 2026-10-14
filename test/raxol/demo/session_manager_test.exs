defmodule Raxol.Demo.SessionManagerTest do
  use ExUnit.Case, async: false
  @moduletag :capture_log

  alias Raxol.Demo.SessionManager

  setup do
    start_supervised!(SessionManager)
    :ok
  end

  describe "create_session/1" do
    test "creates a session and returns session id" do
      assert {:ok, session_id} = SessionManager.create_session("127.0.0.1")
      assert is_binary(session_id)
      assert byte_size(session_id) > 0
    end

    test "increments session count" do
      assert SessionManager.session_count() == 0

      {:ok, _} = SessionManager.create_session("127.0.0.1")
      assert SessionManager.session_count() == 1

      {:ok, _} = SessionManager.create_session("127.0.0.2")
      assert SessionManager.session_count() == 2
    end

    test "tracks sessions per IP" do
      assert SessionManager.sessions_for_ip("192.168.1.1") == 0

      {:ok, _} = SessionManager.create_session("192.168.1.1")
      assert SessionManager.sessions_for_ip("192.168.1.1") == 1

      {:ok, _} = SessionManager.create_session("192.168.1.1")
      assert SessionManager.sessions_for_ip("192.168.1.1") == 2
    end

    test "enforces max sessions per IP" do
      ip = "10.0.0.1"

      for _ <- 1..10 do
        {:ok, _} = SessionManager.create_session(ip)
      end

      assert {:error, :max_sessions_per_ip_reached} = SessionManager.create_session(ip)
    end

    test "different IPs have separate limits" do
      for _ <- 1..10 do
        {:ok, _} = SessionManager.create_session("10.0.0.1")
      end

      assert {:ok, _} = SessionManager.create_session("10.0.0.2")
    end
  end

  describe "remove_session/1" do
    test "removes session and decrements count" do
      {:ok, session_id} = SessionManager.create_session("127.0.0.1")
      assert SessionManager.session_count() == 1

      SessionManager.remove_session(session_id)
      Process.sleep(10)

      assert SessionManager.session_count() == 0
    end

    test "decrements IP session count" do
      ip = "192.168.1.1"
      {:ok, session_id} = SessionManager.create_session(ip)
      assert SessionManager.sessions_for_ip(ip) == 1

      SessionManager.remove_session(session_id)
      Process.sleep(10)

      assert SessionManager.sessions_for_ip(ip) == 0
    end

    test "allows new session after removal" do
      ip = "10.0.0.1"
      sessions =
        for _ <- 1..10 do
          {:ok, id} = SessionManager.create_session(ip)
          id
        end

      SessionManager.remove_session(hd(sessions))
      Process.sleep(10)

      assert {:ok, _} = SessionManager.create_session(ip)
    end

    test "handles removing non-existent session" do
      SessionManager.remove_session("non-existent")
    end
  end

  describe "touch_session/1" do
    test "updates session last activity" do
      {:ok, session_id} = SessionManager.create_session("127.0.0.1")
      SessionManager.touch_session(session_id)
    end

    test "handles non-existent session" do
      SessionManager.touch_session("non-existent")
    end
  end

  describe "session_count/0" do
    test "returns zero initially" do
      assert SessionManager.session_count() == 0
    end

    test "returns correct count after operations" do
      {:ok, id1} = SessionManager.create_session("1.1.1.1")
      {:ok, _id2} = SessionManager.create_session("2.2.2.2")
      assert SessionManager.session_count() == 2

      SessionManager.remove_session(id1)
      Process.sleep(10)

      assert SessionManager.session_count() == 1
    end
  end

  describe "sessions_for_ip/1" do
    test "returns zero for unknown IP" do
      assert SessionManager.sessions_for_ip("unknown") == 0
    end
  end
end
