defmodule Raxol.Agent.Memory.Stack do
  @moduledoc """
  A `Raxol.Agent.Memory` provider that composes several providers into one.

  The built-in ETS store can run alongside an external semantic service (or
  several) without an agent having to choose between them. The stack is itself a
  `Memory` provider, so `Raxol.Agent.Memory.Manager` and the memory actions see a
  single provider that happens to fan out:

    * `store/2` and `forget/2` go to every provider.
    * `search/2` queries every provider, normalizes each provider's results to a
      `[0, 1]` rank score, merges, dedupes by content (keeping the best), and
      takes the requested limit.
    * `prefetch/2` and `build_system_prompt/1` are inherited from
      `use Raxol.Agent.Memory` and ride on the merged `search/2`.

  The providers are passed in `opts[:providers]` as a list of `{module, opts}`
  (or bare modules). A failing provider degrades to empty/no-op rather than
  breaking the stack. Build the context tuple with
  `Raxol.Agent.Memory.stack_context/3`.
  """

  use Raxol.Agent.Memory

  alias Raxol.Agent.Memory.Record

  @scoped_opts [:agent_id, :limit, :query, :query_tags, :tags]

  @impl Raxol.Agent.Memory
  def store(%Record{} = record, opts \\ []) do
    each_provider(opts, fn {mod, popts} -> safe(fn -> mod.store(record, popts) end) end)
    {:ok, record}
  end

  @impl Raxol.Agent.Memory
  def forget(id, opts \\ []) when is_binary(id) do
    each_provider(opts, fn {mod, popts} -> safe(fn -> mod.forget(id, popts) end) end)
    :ok
  end

  @impl Raxol.Agent.Memory
  def search(query, opts \\ []) do
    limit = Keyword.get(opts, :limit, 5)

    opts
    |> providers()
    |> Enum.flat_map(fn {mod, popts} ->
      normalize(safe_list(fn -> mod.search(query, popts) end))
    end)
    |> Enum.sort_by(& &1.score, :desc)
    |> Enum.uniq_by(&{&1.agent_id, &1.content})
    |> Enum.take(limit)
  end

  # -- provider resolution ----------------------------------------------------

  defp providers(opts) do
    scoped = Keyword.take(opts, @scoped_opts)

    opts
    |> Keyword.get(:providers, [])
    |> Enum.map(fn
      {mod, popts} when is_atom(mod) and is_list(popts) -> {mod, Keyword.merge(popts, scoped)}
      mod when is_atom(mod) -> {mod, scoped}
    end)
  end

  defp each_provider(opts, fun), do: opts |> providers() |> Enum.each(fun)

  # Assign a rank-based `[0, 1]` score per provider so heterogeneous providers
  # (different score scales, or none) merge on comparable footing: the top hit of
  # each provider scores 1.0, scaling down by position.
  defp normalize([]), do: []

  defp normalize(records) do
    count = length(records)

    records
    |> Enum.with_index()
    |> Enum.map(fn {record, index} -> %{record | score: (count - index) / count} end)
  end

  defp safe(fun) do
    fun.()
  rescue
    _ -> :error
  catch
    :exit, _ -> :error
  end

  defp safe_list(fun) do
    case safe(fun) do
      list when is_list(list) -> list
      _ -> []
    end
  end
end
