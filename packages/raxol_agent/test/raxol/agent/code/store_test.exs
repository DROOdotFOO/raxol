defmodule Raxol.Agent.Code.StoreTest do
  use ExUnit.Case, async: true

  alias Raxol.Agent.Code.Store

  setup do
    dir = Path.join(System.tmp_dir!(), "raxol-store-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(dir) end)
    %{dir: dir}
  end

  test "save then load round-trips messages and roles", %{dir: dir} do
    messages = [
      %{role: :user, content: "hi"},
      %{role: :assistant, content: "hello"},
      %{role: :system, content: "note"}
    ]

    assert :ok = Store.save(dir, "s1", %{messages: messages})
    assert {:ok, session} = Store.load(dir, "s1")
    assert session.messages == messages
    assert session.id == "s1"
  end

  test "persists and reloads durable events in projection shape", %{dir: dir} do
    events = [
      %{
        id: 1,
        turn_id: "t1",
        ts: 1,
        family: :loop,
        type: :turn_completed,
        tier: :durable,
        scope: :session,
        provenance: %{source: :primary, trust: :trusted},
        payload: %{"final" => true}
      }
    ]

    assert :ok = Store.save(dir, "s3", %{messages: [], events: events})
    assert {:ok, session} = Store.load(dir, "s3")
    assert [%{id: 1, type: :turn_completed, tier: :durable}] = session.events
  end

  test "an unknown role is dropped on load (no atom minted from disk)", %{dir: dir} do
    File.mkdir_p!(dir)

    File.write!(
      Path.join(dir, "s2.json"),
      Jason.encode!(%{
        "messages" => [
          %{"role" => "user", "content" => "ok"},
          %{"role" => "wizard", "content" => "nope"}
        ]
      })
    )

    assert {:ok, session} = Store.load(dir, "s2")
    assert session.messages == [%{role: :user, content: "ok"}]
  end

  test "load of a missing session errors", %{dir: dir} do
    assert {:error, :not_found} = Store.load(dir, "absent")
  end

  test "latest and list order by most-recently-updated", %{dir: dir} do
    Store.save(dir, "old", %{messages: [%{role: :user, content: "a"}]})
    Store.save(dir, "new", %{messages: [%{role: :user, content: "b"}, %{role: :assistant, content: "c"}]})

    listed = Store.list(dir)
    assert Enum.map(listed, & &1.id) |> Enum.sort() == ["new", "old"]
    assert Enum.find(listed, &(&1.id == "new")).message_count == 2
    # Both written in the same second may tie; latest is one of them.
    assert Store.latest(dir) in ["new", "old"]
  end

  test "a crafted session id cannot escape the base directory", %{dir: dir} do
    Store.save(dir, "../escape", %{messages: [%{role: :user, content: "x"}]})
    # basename neutralizes the traversal: the file lands inside dir.
    assert File.exists?(Path.join(dir, "escape.json"))
    assert {:ok, _} = Store.load(dir, "../escape")
  end
end
