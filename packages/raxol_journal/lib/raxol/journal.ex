defmodule Raxol.Journal do
  @moduledoc """
  `Raxol.Journal.*` names for the modules of this package.

  Every function here delegates to the `Raxol.Agent.Journal.*` or
  `Raxol.Agent.Contract` module of the same shape:

  | Alias | Module |
  | --- | --- |
  | `Raxol.Journal` | `Raxol.Agent.Journal` |
  | `Raxol.Journal.FileStore` | `Raxol.Agent.Journal.FileStore` |
  | `Raxol.Journal.FileStore.Reader` | `Raxol.Agent.Journal.FileStore.Reader` |
  | `Raxol.Journal.FileStore.Writer` | `Raxol.Agent.Journal.FileStore.Writer` |
  | `Raxol.Journal.Chain` | `Raxol.Agent.Journal.Chain` |
  | `Raxol.Journal.Tip` | `Raxol.Agent.Journal.Tip` |
  | `Raxol.Journal.Records.Checkpoint` | `Raxol.Agent.Journal.Records.Checkpoint` |
  | `Raxol.Journal.Records.Checkpoint.FileBackend` | `Raxol.Agent.Journal.Records.Checkpoint.FileBackend` |
  | `Raxol.Journal.Contract` | `Raxol.Agent.Contract` |
  | `Raxol.Journal.Contract.Event` | `Raxol.Agent.Contract.Event` |

  An alias carries functions and types only. The structs
  (`%Raxol.Agent.Journal.FileStore{}`, `%Raxol.Agent.Contract.Event{}`), the
  behaviours (`Raxol.Agent.Journal`, `Raxol.Agent.Journal.Records.Checkpoint`)
  and the process and `:persistent_term` names keep their `Raxol.Agent.*` names.

  `Raxol.Journal.Test.*` are not aliases: they are helpers for ExUnit suites.
  """

  alias Raxol.Agent.Journal, as: Target

  @type session_id :: Target.session_id()
  @type handle :: Target.handle()
  @type event :: Target.event()
  @type journal_record :: Target.journal_record()
  @type offset :: Target.offset()

  defdelegate verify(handle), to: Target

  defmodule FileStore do
    @moduledoc "Alias of `Raxol.Agent.Journal.FileStore`."

    alias Raxol.Agent.Journal.FileStore, as: Target

    @type t :: Target.t()

    defdelegate session_dir(session_id, opts \\ []), to: Target
    defdelegate high_watermark(session_id, opts \\ []), to: Target
    defdelegate read_records(session_id, opts \\ []), to: Target
    defdelegate open(session_id, opts \\ []), to: Target
    defdelegate read_meta(journal), to: Target
    defdelegate append(journal, event), to: Target
    defdelegate append_checked(journal, event, check), to: Target
    defdelegate append_many(journal, events, timeout \\ 5_000), to: Target
    defdelegate read(journal, opts \\ []), to: Target
    defdelegate close(journal), to: Target
    defdelegate status(journal), to: Target
    defdelegate verify(journal), to: Target
    defdelegate verify_session(session_id, opts \\ []), to: Target

    defmodule Reader do
      @moduledoc "Alias of `Raxol.Agent.Journal.FileStore.Reader`."

      alias Raxol.Agent.Journal.FileStore.Reader, as: Target

      @type result :: Target.result()

      defdelegate scan(dir, opts \\ []), to: Target
      defdelegate chained?(dir), to: Target
      defdelegate resume_scan(dir), to: Target
      defdelegate last_offset(dir), to: Target
      defdelegate resume_last_offset(dir), to: Target
    end

    defmodule Writer do
      @moduledoc "Alias of `Raxol.Agent.Journal.FileStore.Writer`."

      alias Raxol.Agent.Journal.FileStore.Writer, as: Target

      defdelegate child_spec(opts), to: Target
      defdelegate default_schema_version(), to: Target
      defdelegate start_link(opts), to: Target
      defdelegate whereis(dir), to: Target
      defdelegate append(pid, event), to: Target
      defdelegate append_many(pid, events, timeout \\ 5_000), to: Target
      defdelegate append_checked(pid, event, check), to: Target
      defdelegate flush(pid), to: Target
      defdelegate lock_path(dir), to: Target
      defdelegate lock_holder(dir), to: Target
    end
  end

  defmodule Chain do
    @moduledoc "Alias of `Raxol.Agent.Journal.Chain`."

    alias Raxol.Agent.Journal.Chain, as: Target

    defdelegate genesis(), to: Target
    defdelegate seal(record, prev_hash), to: Target
    defdelegate check(record, prev_hash, raw), to: Target
    defdelegate canonical(value), to: Target
  end

  defmodule Tip do
    @moduledoc "Alias of `Raxol.Agent.Journal.Tip`."

    alias Raxol.Agent.Journal.Tip, as: Target

    defdelegate conversational_types(), to: Target
    defdelegate conversational?(record), to: Target
    defdelegate tip(records, branch \\ "main"), to: Target
  end

  defmodule Records.Checkpoint do
    @moduledoc "Alias of `Raxol.Agent.Journal.Records.Checkpoint`."

    alias Raxol.Agent.Journal.Records.Checkpoint, as: Target

    @type t :: Target.t()
    @type model :: Target.model()

    defdelegate kind(), to: Target
    defdelegate reasons(), to: Target
    defdelegate record_keys(), to: Target
    defdelegate turn_closers(), to: Target
    defdelegate put_backend(backend), to: Target
    defdelegate write(journal, model, opts \\ []), to: Target
    defdelegate restore(journal, opts \\ []), to: Target
    defdelegate restore_checkpoint(journal, records, checkpoint), to: Target
    defdelegate protected_floor(journal, records), to: Target
    defdelegate protected_floor(records), to: Target

    defmodule FileBackend do
      @moduledoc "Alias of `Raxol.Agent.Journal.Records.Checkpoint.FileBackend`."

      alias Raxol.Agent.Journal.Records.Checkpoint.FileBackend, as: Target

      defdelegate write(journal, model, opts), to: Target
      defdelegate restore(journal, opts), to: Target
      defdelegate restore_checkpoint(journal, records, checkpoint), to: Target
      defdelegate protected_floor(journal, records), to: Target
    end
  end

  defmodule Contract do
    @moduledoc "Alias of `Raxol.Agent.Contract`."

    alias Raxol.Agent.Contract, as: Target

    defdelegate encode_line(event), to: Target
    defdelegate sanitize_payload(payload), to: Target
    defdelegate evidence_status(payload), to: Target

    defmodule Event do
      @moduledoc """
      Alias of `Raxol.Agent.Contract.Event`. The struct is
      `%Raxol.Agent.Contract.Event{}`.
      """

      @type t :: Raxol.Agent.Contract.Event.t()
      @type provenance :: Raxol.Agent.Contract.Event.provenance()
      @type actor :: Raxol.Agent.Contract.Event.actor()
    end
  end
end
