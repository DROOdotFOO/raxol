defmodule Raxol.Harness.Fixture.Envelope do
  @moduledoc """
  One decoded fixture line beyond the header — the `%Envelope{}` wire shape
  from `harness-spec-protocol.md` §2, with `body` decoded into a
  `Raxol.Harness.Fixture.Event`.

  `offset` is the 1-based line number in the source file; per the fixture
  design ("offset = line number", 06-projection §1.1) this is what
  `attach{from_offset}` / `seek{to_offset}` replay-from-offset tests key
  off. It is set by the loader, never present in the JSON on disk.
  """

  alias Raxol.Harness.Fixture.Event

  @enforce_keys [:v, :session_id, :kind, :body]
  defstruct [:v, :session_id, :kind, :body, :offset]

  @type t :: %__MODULE__{
          v: pos_integer(),
          session_id: String.t(),
          kind: :event | :command,
          body: Event.t(),
          offset: pos_integer() | nil
        }
end
