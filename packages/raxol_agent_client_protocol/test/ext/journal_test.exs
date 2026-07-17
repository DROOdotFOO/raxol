defmodule Raxol.AgentClientProtocol.Ext.JournalTest do
  @moduledoc """
  THE OFFSET LAW (§1.3 / J8) and the decision-time `high_watermark` (§1.3.2 / J2)
  for the `Raxol.AgentClientProtocol.Ext.Journal` behaviour and its ETS impl
  `Raxol.AgentClientProtocol.Ext.Journal.Mem`.

  Every positive contour ships its named dead-injector negative control (the bus
  §9 discipline): the cached-counter `high_watermark` that lags the store is the
  J2 dead control.
  """
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Raxol.AgentClientProtocol.Ext.Journal.Mem
  alias Raxol.AgentClientProtocol.Ext.Journal.Record
  alias Raxol.AgentClientProtocol.Ext.Journal.Writer

  defp hex, do: 6 |> :crypto.strong_rand_bytes() |> Base.encode16(case: :lower)

  defp open(sid \\ nil) do
    sid = sid || "sess-" <> hex()
    {:ok, j} = Mem.open(sid)
    {sid, j}
  end

  # -- Finding 4 (LOW): ETS protection posture --------------------------------
  #
  # DROOdotFOO flagged the `:public` table (any co-resident process can forge
  # offsets) and asked for `:protected`. `:protected` is architecturally
  # infeasible here: the table is owned by a process that OUTLIVES the Writer (the
  # C14 restart tip-fold precondition), while the single-publisher Writer — a
  # DIFFERENT process — appends cross-process; `:protected` forbids all non-owner
  # writes, breaking every append. Offset integrity is instead enforced by the
  # single-publisher law (exactly one Writer per session via the unique Registry).
  # This test pins the posture so a silent flip is caught, and asserts the
  # co-resident cross-process append the mode must keep working.

  test "Mem journal is :public by architectural necessity (cross-process single-publisher writes)" do
    {_sid, j} = open()
    assert :ets.info(j.table, :protection) == :public

    # A non-owner process (standing in for the Writer) must be able to append —
    # exactly what :protected would forbid and why it cannot be used here.
    parent = self()

    spawn(fn ->
      {:ok, %Record{offset: o}} =
        Mem.append(j, %{kind: "k", payload: %{}, taint: "system"})

      send(parent, {:appended, o})
    end)

    # The cross-process append succeeded (offset 1) — it did not raise on a
    # non-owner write, which is exactly the property :protected would remove.
    assert_receive {:appended, 1}
    assert Mem.high_watermark(j) == 1
  end

  # -- Mem: the offset law, sequential ----------------------------------------

  test "an empty session has high_watermark 0 and an empty read" do
    {_sid, j} = open()
    assert Mem.high_watermark(j) == 0
    assert {:ok, []} = Mem.read(j, 1, 100)
  end

  test "append assigns contiguous offsets from 1, strictly increasing, fully stamped" do
    {sid, j} = open()

    for i <- 1..10 do
      {:ok, %Record{} = rec} =
        Mem.append(j, %{
          kind: "session_update",
          payload: %{"i" => i},
          taint: "agent"
        })

      assert rec.offset == i
      assert rec.session_id == sid
      assert rec.kind == "session_update"
      assert rec.payload == %{"i" => i}
      assert rec.taint == "agent"
      assert is_integer(rec.ts_hook)
    end

    assert Mem.high_watermark(j) == 10
    {:ok, recs} = Mem.read(j, 1, 10)
    assert Enum.map(recs, & &1.offset) == Enum.to_list(1..10)
  end

  test "read is an inclusive, offset-ordered range; an inverted range is empty" do
    {_sid, j} = open()

    for i <- 1..5,
        do: Mem.append(j, %{kind: "k", payload: %{"i" => i}, taint: "system"})

    {:ok, recs} = Mem.read(j, 2, 4)
    assert Enum.map(recs, & &1.offset) == [2, 3, 4]
    assert {:ok, []} = Mem.read(j, 4, 2)
  end

  # -- J2: decision-time high_watermark (reads the store, never a counter) -----

  test "high_watermark reads the store max at call time (decision-time-fold)" do
    {_sid, j} = open()

    for i <- 1..3,
        do: Mem.append(j, %{kind: "k", payload: %{"i" => i}, taint: "system"})

    assert Mem.high_watermark(j) == 3

    # An out-of-band durable write (what a second appender / on-disk store would
    # produce) is observed immediately — a cached counter would miss it.
    rec = %Record{
      offset: 4,
      session_id: j.session_id,
      kind: "k",
      payload: %{},
      taint: "system",
      ts_hook: 0
    }

    true = :ets.insert(j.table, {4, rec})
    assert Mem.high_watermark(j) == 4
  end

  # The J2 dead control: a journal whose high_watermark returns a counter frozen
  # at open (never re-reading the store) lags the durable state — the exact bug
  # the decision-time law forbids.
  defmodule CachedCounterJournal do
    @moduledoc false
    @behaviour Raxol.AgentClientProtocol.Ext.Journal

    alias Raxol.AgentClientProtocol.Ext.Journal.Mem

    @enforce_keys [:inner]
    defstruct [:inner]

    @impl true
    def open(session_id, _opts \\ []) do
      {:ok, inner} = Mem.open(session_id)
      {:ok, %__MODULE__{inner: inner}}
    end

    @impl true
    def append(%__MODULE__{inner: inner}, entry), do: Mem.append(inner, entry)

    @impl true
    def read(%__MODULE__{inner: inner}, from, to), do: Mem.read(inner, from, to)

    # DEAD: ignores the store, always reports "empty".
    @impl true
    def high_watermark(%__MODULE__{}), do: 0

    @impl true
    def close(%__MODULE__{inner: inner}), do: Mem.close(inner)
  end

  test "DEAD cached-counter high_watermark lags the durable store (J2 negative control)" do
    {:ok, j} = CachedCounterJournal.open("sess-" <> hex())

    for i <- 1..3,
        do:
          CachedCounterJournal.append(j, %{
            kind: "k",
            payload: %{"i" => i},
            taint: "system"
          })

    {:ok, recs} = CachedCounterJournal.read(j, 1, 10)
    assert length(recs) == 3

    # The store truly holds 3; the cached counter reports 0 — DEMONSTRATING the
    # lag the invariant rejects (a decision-time impl MUST return 3).
    assert CachedCounterJournal.high_watermark(j) == 0
    refute CachedCounterJournal.high_watermark(j) == length(recs)

    # Contrast: the real Mem impl returns the store max.
    {_sid, mem} = open()

    for i <- 1..3,
        do: Mem.append(mem, %{kind: "k", payload: %{"i" => i}, taint: "system"})

    assert Mem.high_watermark(mem) == length(recs)
  end

  # -- J8: offset law under CONCURRENT appends (via the single-publisher Writer) --

  property "offset law: concurrent appends through the Writer are contiguous, monotone, no gap/dup" do
    check all(n <- integer(1..40), max_runs: 20) do
      sid = "sess-" <> hex()
      {:ok, j} = Mem.open(sid)

      writer =
        start_supervised!(
          %{
            id: {:writer, sid},
            start: {Writer, :start_link, [[session_id: sid, journal: {Mem, j}, name: nil]]},
            restart: :temporary
          },
          restart: :temporary
        )

      # Fan out n concurrent appenders; the single Writer serializes them, which
      # is what makes atomic offset assignment (§1.3.1) hold under concurrency.
      results =
        1..n
        |> Enum.map(fn i ->
          Task.async(fn ->
            Writer.append(writer, "session_update", %{"i" => i}, "agent")
          end)
        end)
        |> Task.await_many(5_000)

      offsets = for {:ok, rec} <- results, do: rec.offset

      # Genesis session_created took offset 1; the n updates take 2..n+1, unique.
      assert Enum.sort(offsets) == Enum.to_list(2..(n + 1))
      assert length(Enum.uniq(offsets)) == n

      {:ok, all} = Mem.read(j, 1, Mem.high_watermark(j))
      assert Enum.map(all, & &1.offset) == Enum.to_list(1..(n + 1))
      assert [%Record{kind: "session_created", offset: 1} | rest] = all
      assert Enum.all?(rest, &(&1.kind == "session_update"))
      assert Mem.high_watermark(j) == n + 1

      stop_supervised({:writer, sid})
    end
  end
end
