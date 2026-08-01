defmodule Raxol.Agent.Reattach.FileReader do
  @moduledoc """
  The read-side reattach implementation (U4, AD-15/FI-12) — the default behind
  `Raxol.Agent.Reattach.attach/3`.

  It resolves `session_id` to its on-disk directory via
  `Raxol.Agent.Journal.FileStore.session_dir/2` (the same base `open/2` uses),
  reads the durable records through the tolerant
  `Raxol.Agent.Journal.FileStore.Reader` — never the single-writer append path,
  so it works against a dead-BEAM / tar'd / replay-only session and writes
  NOTHING — slices history per `policy`, and starts a
  `Raxol.Agent.Reattach.Tailer` that follows the durable tail from `from_offset`
  onward.

  Live delivery is FILE-based, not bus-based: the Tailer re-scans the journal
  and delivers each new durable record to the attaching process as
  `{:reattach_live, session_id, record}` in offset order. Because it only ever
  observes records already framed on disk, it can never deliver a
  not-yet-durable id as "live" — the I3 publish-ahead window (N-JS7) is closed
  by construction, so `read(0..o−1) ++ attach_live(o..)` equals the full durable
  stream as a sequence (P-JS5).
  """

  @behaviour Raxol.Agent.Reattach

  alias Raxol.Agent.Journal.FileStore
  alias Raxol.Agent.Journal.FileStore.Reader
  alias Raxol.Agent.Journal.Tip
  alias Raxol.Agent.Reattach.Tailer

  @impl Raxol.Agent.Reattach
  def attach(session_id, from_offset, policy, opts \\ []) do
    # `opts` may carry :base_dir (OQ-JS5); session_dir/2 reads only that key.
    dir = FileStore.session_dir(session_id, opts)
    subscriber = Keyword.get(opts, :subscriber, self())

    with :ok <- validate_policy(policy),
         {:ok, records} <- read(dir) do
      history = history_slice(records, from_offset, policy)
      {:ok, live} = Tailer.start(dir, session_id, from_offset, subscriber)
      {:ok, %{history: history, from_offset: from_offset, live: live}}
    end
  end

  # Read the durable records through the tolerant Reader (writerless-safe). A
  # damaged journal is surfaced as an error and never returned as records.
  defp read(dir) do
    case Reader.scan(dir) do
      {:ok, records} -> {:ok, records}
      {:damaged, _partial} -> {:error, :damaged}
    end
  end

  # {:from_offset, n}: the durable records in n..(from_offset−1), in order.
  defp history_slice(records, from_offset, {:from_offset, n}) do
    Enum.filter(records, fn %{"id" => id} -> id >= n and id < from_offset end)
  end

  # :none: no history — the live tail from from_offset is the whole delivery.
  defp history_slice(_records, _from_offset, :none), do: []

  # :tip: the single conversational-tip record (the resume point), or none when
  # the branch has no conversational record. Branch "main" — the frozen default;
  # attach/3 carries no branch parameter (branch-aware reattach is a later unit).
  defp history_slice(records, _from_offset, :tip) do
    case Tip.tip(records) do
      {:tip, offset} -> Enum.filter(records, fn %{"id" => id} -> id == offset end)
      :no_tip -> []
    end
  end

  # The frozen history_policy shapes. An out-of-contract policy is rejected here
  # rather than crashing on a non-matching history_slice clause.
  defp validate_policy({:from_offset, n}) when is_integer(n) and n >= 0, do: :ok
  defp validate_policy(:tip), do: :ok
  defp validate_policy(:none), do: :ok
  defp validate_policy(other), do: {:error, {:invalid_policy, other}}
end
