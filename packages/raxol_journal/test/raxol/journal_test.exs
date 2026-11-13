defmodule Raxol.JournalTest do
  use ExUnit.Case, async: true

  @pairs [
    {Raxol.Journal, Raxol.Agent.Journal},
    {Raxol.Journal.FileStore, Raxol.Agent.Journal.FileStore},
    {Raxol.Journal.FileStore.Reader, Raxol.Agent.Journal.FileStore.Reader},
    {Raxol.Journal.FileStore.Writer, Raxol.Agent.Journal.FileStore.Writer},
    {Raxol.Journal.Chain, Raxol.Agent.Journal.Chain},
    {Raxol.Journal.Tip, Raxol.Agent.Journal.Tip},
    {Raxol.Journal.Records.Checkpoint, Raxol.Agent.Journal.Records.Checkpoint},
    {Raxol.Journal.Records.Checkpoint.FileBackend,
     Raxol.Agent.Journal.Records.Checkpoint.FileBackend},
    {Raxol.Journal.Contract, Raxol.Agent.Contract},
    {Raxol.Journal.Contract.Event, Raxol.Agent.Contract.Event}
  ]

  # Exported, but not part of what an alias carries: struct and behaviour
  # plumbing, the Writer's GenServer callbacks, and the `@doc false` functions.
  @internal [
    __struct__: 0,
    __struct__: 1,
    behaviour_info: 1,
    init: 1,
    handle_call: 3,
    handle_cast: 2,
    handle_info: 2,
    terminate: 2,
    code_change: 3,
    global_name: 1,
    list_segments: 1,
    parse_proc_stat: 1,
    classify_ps: 1,
    nesting_within_bound?: 1
  ]

  for {aliased, target} <- @pairs do
    test "#{inspect(aliased)} carries every public function of #{inspect(target)}" do
      assert Code.ensure_loaded?(unquote(aliased))

      public = unquote(target).__info__(:functions) -- @internal
      assert public -- unquote(aliased).__info__(:functions) == []
    end
  end

  test "an alias returns what its module returns" do
    record = %{"id" => 1, "type" => "turn_started"}

    assert Raxol.Journal.Chain.canonical(record) == Raxol.Agent.Journal.Chain.canonical(record)

    assert Raxol.Journal.Tip.conversational_types() ==
             Raxol.Agent.Journal.Tip.conversational_types()

    assert Raxol.Journal.Contract.evidence_status(%{"evidence" => "absent"}) == :absent

    assert Raxol.Journal.FileStore.Writer.default_schema_version() ==
             Raxol.Agent.Journal.FileStore.Writer.default_schema_version()
  end

  test "a journal opened through the alias is the module's struct" do
    base = Path.join(System.tmp_dir!(), "raxol_alias_#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf(base) end)

    assert {:ok, %Raxol.Agent.Journal.FileStore{} = journal} =
             Raxol.Journal.FileStore.open("alias", base_dir: base)

    assert {:ok, 1} = Raxol.Journal.FileStore.append(journal, %{"type" => "turn_started"})
    assert {:ok, [%{"id" => 1}]} = Raxol.Journal.FileStore.read(journal)
    assert Raxol.Journal.verify(journal) == {:error, :unchained}
    assert :ok = Raxol.Journal.FileStore.close(journal)
  end
end
