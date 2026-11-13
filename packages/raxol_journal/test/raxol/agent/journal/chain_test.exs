defmodule Raxol.Agent.Journal.ChainTest do
  use ExUnit.Case, async: true

  alias Raxol.Agent.Journal
  alias Raxol.Agent.Journal.Chain
  alias Raxol.Agent.Journal.FileStore

  @moduletag :capture_log
  @golden Path.expand("../../../invariants/fixtures/golden", __DIR__)

  setup do
    base = Path.join(System.tmp_dir!(), "raxol_chain_#{System.unique_integer([:positive])}")
    File.mkdir_p!(base)
    on_exit(fn -> File.rm_rf(base) end)
    {:ok, base: base, session: "chain-#{System.unique_integer([:positive])}"}
  end

  defp open!(base, session, opts \\ []) do
    {:ok, j} = FileStore.open(session, [base_dir: base, chain: true] ++ opts)
    j
  end

  # Listed, not globbed: a pattern built from `base` reads its `\` (Windows
  # temp dirs) as escapes and matched no segments.
  defp segments(base, session) do
    dir = base |> Path.join(session) |> Path.join("journal")

    dir
    |> File.ls!()
    |> Enum.filter(&String.ends_with?(&1, ".jsonl"))
    |> Enum.sort()
    |> Enum.map(&Path.join(dir, &1))
  end

  defp head(base, session),
    do: base |> Path.join(session) |> Path.join("HEAD") |> File.read!() |> Jason.decode!()

  defp strip_meta_flag!(dir) do
    path = Path.join(dir, "meta.json")
    meta = path |> File.read!() |> Jason.decode!()
    assert meta["chain"] == true
    File.write!(path, meta |> Map.delete("chain") |> Jason.encode!())
  end

  describe "chained append" do
    test "every record links to the previous one across segments and survives reopen",
         %{base: base, session: session} do
      j = open!(base, session, segment_cap: 256)
      for n <- 1..6, do: {:ok, ^n} = FileStore.append(j, %{"type" => "chunk", "n" => n})

      assert length(segments(base, session)) > 1
      assert {:ok, records} = FileStore.read(j)
      assert hd(records)["prev_hash"] == Chain.genesis()

      for [prev, next] <- Enum.chunk_every(records, 2, 1, :discard) do
        assert next["prev_hash"] == prev["hash"]
      end

      assert head(base, session)["tip_hash"] == List.last(records)["hash"]
      assert Journal.verify(j) == :ok
      :ok = FileStore.close(j)

      # The mode lives in meta.json: an opener that does not ask for a chain
      # still extends it.
      {:ok, j} = FileStore.open(session, base_dir: base, segment_cap: 256)
      assert {:ok, 7} = FileStore.append(j, %{"type" => "chunk", "n" => 7})
      assert {:ok, records} = FileStore.read(j)
      assert List.last(records)["prev_hash"] == Enum.at(records, 5)["hash"]
      assert FileStore.verify(j) == :ok
      assert FileStore.status(j) == :ok
      :ok = FileStore.close(j)
    end

    test "the hash depends on content, not on key order or atom keys" do
      {:ok, line_a, hash_a} = Chain.seal(%{"b" => [1, %{"y" => 2, "x" => 1}], "a" => "s"}, "p")
      {:ok, line_b, hash_b} = Chain.seal(%{a: "s", b: [1, %{x: 1, y: 2}]}, "p")

      assert hash_a == hash_b
      assert IO.iodata_to_binary(line_a) == IO.iodata_to_binary(line_b)
      assert {:ok, _line, other} = Chain.seal(%{"a" => "s"}, "p")
      refute other == hash_a
    end

    # The canonical bytes are a disk format: every chained journal ever
    # written is checked against them. Spelled out by hand, so a change in
    # how strings are escaped (a Jason default, say) fails here instead of
    # marking every existing chained journal damaged.
    test "canonical bytes and hash are pinned for strings that need escaping" do
      text = "a\u001Fb\u007Fc\u009Bdé😀/\"\\"
      genesis = Chain.genesis()
      hash = "12d2a39fc9af6d50fe0c5739d4263e27775aab3fd0f1e1433bc90e4f9944c95c"

      spelled =
        ~S(a\u001Fb) <>
          <<0x7F>> <> "c" <> <<0xC2, 0x9B>> <> "dé" <> <<0xF0, 0x9F, 0x98, 0x80>> <> ~S(/\"\\)

      line =
        ~S({"hash":") <>
          hash <>
          ~S(","id":7,"prev_hash":") <>
          genesis <>
          ~S(","text":") <> spelled <> ~S(","type":"pin"})

      assert IO.iodata_to_binary(Chain.canonical(text)) == ~S(") <> spelled <> ~S(")

      assert {:ok, sealed, ^hash} =
               Chain.seal(%{"type" => "pin", "id" => 7, "text" => text}, genesis)

      assert IO.iodata_to_binary(sealed) == line
      assert Chain.check(Jason.decode!(line), genesis, line) == :ok

      assert :crypto.hash(:sha256, String.replace(line, ~s("hash":"#{hash}",), "")) ==
               Base.decode16!(hash, case: :lower)
    end

    test "append_many writes consecutive offsets in one call; any bad event appends nothing",
         %{base: base, session: session} do
      j = open!(base, session)
      {:ok, 1} = FileStore.append(j, %{"type" => "a"})

      assert {:error, {:float, ["px"]}} =
               FileStore.append_many(j, [%{"type" => "b"}, %{"type" => "c", "px" => 1.5}])

      assert {:ok, [2, 3, 4]} = FileStore.append_many(j, Enum.map(~w(b c d), &%{"type" => &1}))
      assert {:ok, records} = FileStore.read(j)
      assert Enum.map(records, & &1["type"]) == ~w(a b c d)
      assert FileStore.verify(j) == :ok
      :ok = FileStore.close(j)
    end

    test "a float is refused and the chain carries on", %{base: base, session: session} do
      j = open!(base, session)

      assert {:error, {:float, ["payload", "qty", 1]}} =
               FileStore.append(j, %{"payload" => %{"qty" => [1, 2.5]}})

      assert {:ok, 1} = FileStore.append(j, %{"payload" => %{"qty" => "2.5"}})
      assert FileStore.verify(j) == :ok
      :ok = FileStore.close(j)
    end
  end

  describe "damage" do
    test "flipping any byte of any committed record reports that record's offset",
         %{base: base, session: session} do
      # A cap below one record puts each record in its own segment, so the
      # flips also cover every segment boundary and the final newline.
      j = open!(base, session, segment_cap: 64)
      for n <- 1..3, do: {:ok, ^n} = FileStore.append(j, %{"type" => "chunk", "n" => n})
      # Rotation opens the next (empty) segment eagerly; it holds no record.
      segs = Enum.filter(segments(base, session), &(File.stat!(&1).size > 0))
      assert length(segs) == 3

      for {path, offset} <- Enum.with_index(segs, 1) do
        pristine = File.read!(path)

        for at <- 0..(byte_size(pristine) - 1) do
          <<pre::binary-size(^at), byte, post::binary>> = pristine
          File.write!(path, <<pre::binary, Bitwise.bxor(byte, 1), post::binary>>)

          assert Journal.verify(j) == {:broken, offset},
                 "flip at byte #{at} of record #{offset} was not reported there"

          assert FileStore.status(j) == {:damaged, offset}
          assert {:error, :damaged} = FileStore.read(j)
        end

        File.write!(path, pristine)
      end

      assert FileStore.verify(j) == :ok
      :ok = FileStore.close(j)
    end

    test "losing the last committed record is damage, and a restarted writer will not extend it",
         %{base: base, session: session} do
      j = open!(base, session)
      for n <- 1..3, do: FileStore.append(j, %{"type" => "chunk", "n" => n})
      :ok = FileStore.close(j)

      [seg] = segments(base, session)
      [l1, l2, _l3] = String.split(File.read!(seg), "\n", trim: true)
      File.write!(seg, l1 <> "\n" <> l2 <> "\n")
      head_before = head(base, session)

      j = open!(base, session)
      assert FileStore.verify(j) == {:broken, 3}
      assert FileStore.status(j) == {:damaged, 3}
      assert FileStore.append(j, %{"type" => "chunk"}) == {:error, :damaged}
      assert head(base, session) == head_before
      :ok = FileStore.close(j)
    end

    test "a torn line above the HEAD anchor is a crash mid-write and is healed",
         %{base: base, session: session} do
      j = open!(base, session)
      for n <- 1..2, do: FileStore.append(j, %{"type" => "chunk", "n" => n})
      :ok = FileStore.close(j)

      [seg] = segments(base, session)
      File.write!(seg, ~s({"id":3,"type":"chu), [:append])

      j = open!(base, session)
      assert FileStore.status(j) == :ok
      assert {:ok, 3} = FileStore.append(j, %{"type" => "chunk", "n" => 3})
      assert FileStore.verify(j) == :ok
      :ok = FileStore.close(j)
    end
  end

  describe "mode" do
    test "chain: true on an existing unchained journal is refused; verify says unchained",
         %{base: base, session: session} do
      {:ok, j} = FileStore.open(session, base_dir: base)
      {:ok, 1} = FileStore.append(j, %{"type" => "chunk"})
      assert FileStore.verify(j) == {:error, :unchained}
      :ok = FileStore.close(j)

      assert FileStore.open(session, base_dir: base, chain: true) == {:error, :unchained_journal}
      assert FileStore.verify_session(session, base_dir: base) == {:error, :unchained}
    end

    test "stripping the chain flag from meta.json does not switch checking off",
         %{base: base, session: session} do
      j = open!(base, session)
      for n <- 1..3, do: {:ok, ^n} = FileStore.append(j, %{"type" => "chunk", "n" => n})
      :ok = FileStore.close(j)

      strip_meta_flag!(Path.join(base, session))
      [seg] = segments(base, session)
      File.write!(seg, String.replace(File.read!(seg), ~s("n":2), ~s("n":9)))

      assert FileStore.verify_session(session, base_dir: base) == {:broken, 1}
      assert FileStore.read_records(session, base_dir: base) == {:error, :damaged}

      for opts <- [[], [chain: true]] do
        assert {:ok, j} = FileStore.open(session, [base_dir: base] ++ opts)
        assert FileStore.read(j) == {:error, :damaged}
        assert FileStore.status(j) == {:damaged, 1}
        assert FileStore.verify(j) == {:broken, 1}
        assert FileStore.append(j, %{"type" => "chunk"}) == {:error, :damaged}
        :ok = FileStore.close(j)
      end
    end

    test "either remaining chain marker, HEAD's tip_hash or the records' hashes, is enough",
         %{base: base, session: session} do
      j = open!(base, session)
      for n <- 1..2, do: {:ok, ^n} = FileStore.append(j, %{"type" => "chunk", "n" => n})
      :ok = FileStore.close(j)

      dir = Path.join(base, session)
      [seg] = segments(base, session)
      pristine = %{seg => File.read!(seg), head: File.read!(Path.join(dir, "HEAD"))}
      strip_meta_flag!(dir)

      # Only the records still say chained.
      head_path = Path.join(dir, "HEAD")
      File.write!(head_path, head(base, session) |> Map.delete("tip_hash") |> Jason.encode!())
      assert FileStore.verify_session(session, base_dir: base) == {:broken, 1}
      assert FileStore.read_records(session, base_dir: base) == {:error, :damaged}

      # Only HEAD still says chained.
      File.write!(head_path, pristine.head)

      unhashed =
        pristine[seg]
        |> String.split("\n", trim: true)
        |> Enum.map_join(
          &(&1
            |> Jason.decode!()
            |> Map.drop(["hash", "prev_hash"])
            |> Jason.encode!()
            |> Kernel.<>("\n"))
        )

      File.write!(seg, unhashed)
      assert FileStore.verify_session(session, base_dir: base) == {:broken, 1}
      assert FileStore.read_records(session, base_dir: base) == {:error, :damaged}
    end

    test "the frozen corpora keep their chain mode; a de-flagged 1.2.0 corpus is damage",
         %{base: base} do
      for {version, session} <- [{"1.0.0", "golden-v1"}, {"1.1.0", "golden-v11"}] do
        File.cp_r!(Path.join([@golden, "v#{version}", session]), Path.join(base, session))
        assert {:ok, [_ | _]} = FileStore.read_records(session, base_dir: base)
        assert FileStore.verify_session(session, base_dir: base) == {:error, :unchained}
      end

      File.cp_r!(Path.join([@golden, "v1.2.0", "golden-v12"]), Path.join(base, "golden-v12"))
      assert FileStore.verify_session("golden-v12", base_dir: base) == :ok

      strip_meta_flag!(Path.join(base, "golden-v12"))
      assert FileStore.verify_session("golden-v12", base_dir: base) == {:broken, 1}
      assert FileStore.read_records("golden-v12", base_dir: base) == {:error, :damaged}
    end
  end
end
