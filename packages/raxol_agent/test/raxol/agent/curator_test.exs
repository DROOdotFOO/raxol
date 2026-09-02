defmodule Raxol.Agent.CuratorTest do
  use ExUnit.Case, async: false

  alias Raxol.Agent.Curator
  alias Raxol.Agent.Skills.Store

  setup do
    base = Path.join(System.tmp_dir!(), "cur_#{System.unique_integer([:positive])}")
    root = Path.join(base, "skills")
    backups = Path.join(base, "backups")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf(base) end)

    sk = :"cur_sk_#{System.unique_integer([:positive])}"

    start_supervised!(%{
      id: sk,
      start: {Store, :start_link, [[name: sk, skills_root: root, external_dirs: []]]}
    })

    %{store: sk, root: root, backups: backups, skills_ctx: {Store, [server: sk]}}
  end

  defp start_curator(ctx, opts) do
    name = :"cur_#{System.unique_integer([:positive])}"

    spec_opts =
      [name: name, skills: ctx.skills_ctx, backups_dir: ctx.backups] ++ opts

    start_supervised!(%{id: name, start: {Curator, :start_link, [spec_opts]}})
    name
  end

  defp create(ctx, name, created_by) do
    {Store, opts} = ctx.skills_ctx
    Store.create(%{name: name, body: "# #{name}", created_by: created_by}, opts)
  end

  describe "skill ageing lifecycle" do
    test "ages an unused agent skill active -> stale -> archived", %{store: sk} = ctx do
      create(ctx, "old", :agent)

      stale = start_curator(ctx, stale_after_days: 0, archive_after_days: 999_999)
      assert %{transitions: [%{name: "old", from: :active, to: :stale}]} = Curator.run(stale)
      assert {:ok, %{state: :stale}} = Store.usage("old", server: sk)

      archive = start_curator(ctx, stale_after_days: 0, archive_after_days: 0)
      assert %{transitions: ts} = Curator.run(archive)
      assert Enum.any?(ts, &(&1.name == "old" and &1.to == :archived))
      assert {:error, :not_found} = Store.get("old", server: sk)
      refute "old" in Enum.map(Store.list(server: sk), & &1.name)
    end

    test "never ages user-created or pinned skills", %{store: sk} = ctx do
      create(ctx, "mine", :user)
      create(ctx, "pinned", :agent)
      Store.pin("pinned", server: sk)

      cur = start_curator(ctx, stale_after_days: 0, archive_after_days: 0)
      assert %{transitions: []} = Curator.run(cur)
    end

    test "leaves recently-active skills alone", ctx do
      create(ctx, "fresh", :agent)
      cur = start_curator(ctx, stale_after_days: 1, archive_after_days: 90)
      assert %{transitions: []} = Curator.run(cur)
    end
  end

  describe "dry run" do
    test "reports transitions without applying or writing a backup",
         %{store: sk, backups: backups} = ctx do
      create(ctx, "d", :agent)
      cur = start_curator(ctx, stale_after_days: 0, archive_after_days: 999_999)

      assert %{transitions: [%{name: "d", to: :stale}], backup: nil} =
               Curator.run(cur, dry_run: true)

      assert {:ok, %{state: :active}} = Store.usage("d", server: sk)
      refute File.exists?(backups)
    end
  end

  describe "backup and rollback" do
    test "rollback restores a deleted skill from the latest backup", %{store: sk} = ctx do
      create(ctx, "keep", :agent)
      cur = start_curator(ctx, stale_after_days: 999_999, archive_after_days: 999_999)

      assert %{transitions: [], backup: path} = Curator.run(cur)
      assert is_binary(path) and File.exists?(path)

      Store.delete("keep", server: sk)
      assert {:error, :not_found} = Store.get("keep", server: sk)

      assert {:ok, restored} = Curator.rollback(cur)
      assert restored == path
      assert {:ok, _} = Store.get("keep", server: sk)
    end

    test "rollback with no backup returns an error", ctx do
      cur = start_curator(ctx, [])
      assert {:error, :no_backup} = Curator.rollback(cur)
    end
  end
end
