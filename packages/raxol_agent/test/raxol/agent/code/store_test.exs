defmodule Raxol.Agent.Code.StoreTest do
  use ExUnit.Case, async: true

  alias Raxol.Agent.Code.Store

  setup do
    dir =
      Path.join(
        System.tmp_dir!(),
        "raxol-store-#{System.unique_integer([:positive])}"
      )

    on_exit(fn -> File.rm_rf!(dir) end)
    %{dir: dir}
  end

  test "title, parent, and cwd round-trip and appear in list/1", %{dir: dir} do
    :ok =
      Store.save(dir, "sess-t", %{
        messages: [],
        events: [],
        cwd: "/work",
        title: "fix bug",
        parent: "sess-orig"
      })

    assert {:ok, session} = Store.load(dir, "sess-t")
    assert session.title == "fix bug"
    assert session.parent == "sess-orig"
    assert session.cwd == "/work"

    assert [summary] = Store.list(dir)
    assert summary.title == "fix bug"
    assert summary.cwd == "/work"
  end

  test "sessions saved without title/parent load with defaults", %{dir: dir} do
    :ok = Store.save(dir, "sess-old", %{messages: []})
    assert {:ok, session} = Store.load(dir, "sess-old")
    assert session.title == ""
    assert session.parent == nil
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

  test "an unknown role is dropped on load (no atom minted from disk)", %{
    dir: dir
  } do
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

    Store.save(dir, "new", %{
      messages: [
        %{role: :user, content: "b"},
        %{role: :assistant, content: "c"}
      ]
    })

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

  describe "durability (the conversation lives only here)" do
    test "a save is atomic: no reader ever sees a partial file", %{dir: dir} do
      # A torn write decodes as damaged, load/2 reports :not_found, and the
      # surface reads that as "starting fresh" -- silently discarding the
      # conversation, which the journal does not carry.
      Store.save(dir, "s", %{messages: [%{role: :user, content: "keep me"}]})

      # The write goes via a temp file in the same dir and is renamed over the
      # target, so at no point is the target itself a prefix.
      assert File.ls!(dir) == ["s.json"]
      assert {:ok, %{messages: [%{content: "keep me"}]}} = Store.load(dir, "s")
    end

    test "a temp file left by a crashed save is not listed as a session", %{
      dir: dir
    } do
      Store.save(dir, "s", %{messages: []})
      File.write!(Path.join(dir, "s.json.tmp.999"), "{partial")

      assert Enum.map(Store.list(dir), & &1.id) == ["s"]
    end

    test "an unencodable payload errors instead of raising", %{dir: dir} do
      # save/3 promises {:error, reason}; a caller written against that
      # contract must not be taken down by an encoder raise.
      assert {:error, {:encode_failed, _}} =
               Store.save(dir, "s", %{messages: [], events: [%{bad: self()}]})

      # And nothing half-written was left behind.
      refute File.exists?(Path.join(dir, "s.json"))
      assert File.ls!(dir) == []
    end
  end

  describe "optimistic concurrency (the store is shared)" do
    test "a save refuses when the session moved on since it was read", %{
      dir: dir
    } do
      :ok = Store.save(dir, "s", %{messages: [%{role: :user, content: "a"}]})
      {:ok, read} = Store.load(dir, "s")

      # Another surface (the TUI, an MCP turn) persists in between.
      :ok =
        Store.save(dir, "s", %{
          messages: [%{role: :user, content: "a"}, %{role: :assistant, content: "b"}]
        })

      assert {:error, :stale} =
               Store.save(
                 dir,
                 "s",
                 %{messages: [%{role: :user, content: "mine only"}]},
                 expect_rev: read.rev
               )

      # The other surface's turn survived rather than being overwritten.
      assert {:ok, %{messages: [_, %{content: "b"}]}} = Store.load(dir, "s")
    end

    test "a save proceeds when nothing moved", %{dir: dir} do
      :ok = Store.save(dir, "s", %{messages: [%{role: :user, content: "a"}]})
      {:ok, read} = Store.load(dir, "s")

      assert :ok =
               Store.save(
                 dir,
                 "s",
                 %{messages: [%{role: :user, content: "b"}]},
                 expect_rev: read.rev
               )
    end

    test "an expectation on a session that does not exist yet is satisfiable",
         %{dir: dir} do
      assert :ok =
               Store.save(dir, "fresh", %{messages: []}, expect_rev: nil)
    end
  end
end
