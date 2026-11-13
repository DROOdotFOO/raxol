defmodule Raxol.Agent.Journal.PrivateTest do
  # async: false -- starts Writers under the shared :global name space and
  # changes file modes.
  use ExUnit.Case, async: false

  import Bitwise, only: [band: 2]

  alias Raxol.Agent.Journal.FileStore

  @moduletag :unix_only
  @moduletag :capture_log

  setup do
    base = Path.join(System.tmp_dir!(), "raxol_private_#{System.unique_integer([:positive])}")
    File.mkdir_p!(base)
    File.chmod!(base, 0o755)
    on_exit(fn -> File.rm_rf(base) end)
    {:ok, base: base, session: "private-#{System.unique_integer([:positive])}"}
  end

  defp mode(path), do: band(File.lstat!(path).mode, 0o777)

  defp files(dir) do
    dir
    |> Path.join("**")
    |> Path.wildcard(match_dot: true)
    |> Enum.filter(&File.regular?/1)
  end

  describe "private: true" do
    test "every directory is 0700 and every file the writer creates is 0600",
         %{base: base, session: session} do
      {:ok, j} =
        FileStore.open(session, base_dir: base, private: true, chain: true, segment_cap: 64)

      for n <- 1..3, do: {:ok, ^n} = FileStore.append(j, %{"type" => "chunk", "n" => n})
      assert FileStore.status(j) == :ok

      dir = Path.join(base, session)

      for sub <- ["", "journal", "snapshots"],
          do: assert(mode(Path.join(dir, sub)) == 0o700, "#{sub}/ is not 0700")

      created = files(dir)
      names = Enum.map(created, &Path.relative_to(&1, dir))
      assert "meta.json" in names and "HEAD" in names and "writer.lock" in names
      assert Enum.count(names, &String.starts_with?(&1, "journal/")) >= 3

      for path <- created, do: assert(mode(path) == 0o600, "#{path} is not 0600")

      :ok = FileStore.close(j)
    end

    test "an existing session dir of ours is tightened to 0700", %{base: base, session: session} do
      dir = Path.join(base, session)
      File.mkdir_p!(Path.join(dir, "journal"))
      File.chmod!(dir, 0o755)
      File.chmod!(Path.join(dir, "journal"), 0o755)

      {:ok, j} = FileStore.open(session, base_dir: base, private: true)
      assert mode(dir) == 0o700
      assert mode(Path.join(dir, "journal")) == 0o700
      :ok = FileStore.close(j)
    end

    test "a group-writable session dir is refused and left untouched",
         %{base: base, session: session} do
      dir = Path.join(base, session)
      File.mkdir_p!(dir)
      File.chmod!(dir, 0o770)

      assert {:error, {:untrusted_dir, _reason}} =
               FileStore.open(session, base_dir: base, private: true)

      assert mode(dir) == 0o770
      refute File.exists?(Path.join(dir, "journal"))
    end

    test "a symlinked session dir is refused", %{base: base, session: session} do
      target = Path.join(base, "elsewhere")
      File.mkdir_p!(target)
      File.chmod!(target, 0o700)
      :ok = File.ln_s(target, Path.join(base, session))

      assert {:error, {:untrusted_dir, _reason}} =
               FileStore.open(session, base_dir: base, private: true)

      assert File.ls!(target) == []
    end

    test "a group-writable or symlinked base dir is refused", %{base: base, session: session} do
      writable = Path.join(base, "writable")
      File.mkdir_p!(writable)
      File.chmod!(writable, 0o775)

      assert {:error, {:untrusted_dir, _reason}} =
               FileStore.open(session, base_dir: writable, private: true)

      refute File.exists?(Path.join(writable, session))

      real = Path.join(base, "real")
      File.mkdir_p!(real)
      File.chmod!(real, 0o700)
      link = Path.join(base, "link")
      :ok = File.ln_s(real, link)

      assert {:error, {:untrusted_dir, _reason}} =
               FileStore.open(session, base_dir: link, private: true)

      assert File.ls!(real) == []
    end

    test "a missing base dir is created 0700", %{base: base, session: session} do
      fresh = Path.join(base, "fresh")
      {:ok, j} = FileStore.open(session, base_dir: fresh, private: true)
      assert mode(fresh) == 0o700
      :ok = FileStore.close(j)
    end
  end
end
