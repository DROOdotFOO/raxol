defmodule Raxol.Symphony.PromptBuilder.Memo do
  @moduledoc """
  Single-writer owner for the `Raxol.Symphony.PromptBuilder` parsed-template
  memo.

  Reads of the memo go straight to `:persistent_term` (lock-free, the hot
  render path). Every WRITE funnels through this one GenServer so the
  read-modify-write on the single memo entry -- a bounded FIFO map from
  template string to parsed AST -- is serialized.

  Without a single writer, concurrent parses of distinct new templates
  race: each reads the same memo, each computes a new map, and the last
  `:persistent_term.put` wins, so an update is lost and the FIFO `order`
  can drift past the cap or evict the wrong slot. One writer makes the
  bound hold.

  The process is a lazily-started, unsupervised singleton (this package
  ships no application tree, and `PromptBuilder` is also called
  standalone). A crash loses nothing durable: `:persistent_term` retains
  the last memo and the next write restarts the owner.
  """

  use GenServer

  @empty_memo %{map: %{}, order: []}

  # Short write-path deadline: a wedged singleton (mailbox backup during a
  # global-GC storm) must never stall a prompt build. On timeout the write
  # degrades to a no-op, identical in cost to a cache miss (re-parse next call).
  @write_timeout_ms 1_000

  @doc """
  Serialize a bounded FIFO insert of `parsed` under `template` into the
  `:persistent_term` memo at `key`, capped at `max` entries.

  A no-op (no write, so no needless global GC) when `template` is already
  memoized -- which is what keeps two concurrent writers of the same new
  template from appending it to `order` twice.

  The memo is a pure performance cache: a write is always best-effort. If the
  single-writer is absent, dies mid-call (TOCTOU `:noproc`), or wedges past
  `@write_timeout_ms` (`:timeout`), the write degrades to a silent no-op --
  the caller's parse result is unaffected, the memo simply is not updated this
  time and the template re-parses on the next call. A memo write failure must
  never propagate out of `Raxol.Symphony.PromptBuilder.build/2`.
  """
  @spec memoize(term(), pos_integer(), binary(), term()) :: :ok
  def memoize(key, max, template, parsed)
      when is_integer(max) and max > 0 and is_binary(template) do
    ensure_started()
    GenServer.call(__MODULE__, {:memoize, key, max, template, parsed}, @write_timeout_ms)
  catch
    # A broken/absent/wedged writer degrades to a best-effort no-op. Exit
    # shapes: `:noproc` (orphan died between `whereis` and `call`, or was never
    # started), `:timeout` (call deadline), and the `{reason, {GenServer, :call, _}}`
    # wrappers `GenServer.call` raises for a crash mid-call.
    :exit, _reason -> :ok
  end

  @impl true
  def init(_), do: {:ok, %{}}

  @impl true
  def handle_call({:memoize, key, max, template, parsed}, _from, state) do
    memo = :persistent_term.get(key, @empty_memo)

    case Map.has_key?(memo.map, template) do
      true ->
        :ok

      false ->
        :persistent_term.put(key, put_bounded(memo, max, template, parsed))
    end

    {:reply, :ok, state}
  end

  # FIFO insert into the bounded memo: evict the oldest template when full so
  # the entry never grows past `max` across live template reloads.
  defp put_bounded(%{map: map, order: order}, max, template, parsed) do
    if map_size(map) >= max do
      {evict, rest} = List.pop_at(order, 0)

      %{
        map: map |> Map.delete(evict) |> Map.put(template, parsed),
        order: rest ++ [template]
      }
    else
      %{map: Map.put(map, template, parsed), order: order ++ [template]}
    end
  end

  defp ensure_started do
    case GenServer.whereis(__MODULE__) do
      nil ->
        # start/3 (not start_link) so the singleton is not tied to a transient
        # worker Task's lifetime; the name resolves the start race.
        case GenServer.start(__MODULE__, :ok, name: __MODULE__) do
          {:ok, _pid} -> :ok
          {:error, {:already_started, _pid}} -> :ok
        end

      _pid ->
        :ok
    end
  end
end
