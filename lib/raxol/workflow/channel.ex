defmodule Raxol.Workflow.Channel do
  @moduledoc """
  Typed reducer declaration for a state-map key.

  Registered on a `Raxol.Workflow.Graph` via `Graph.add_channel/4`.
  Channels are metadata only -- they do not add nodes or edges. At a
  join (`Graph.add_join/4`), the runtime merges branch states by
  applying each channel's reducer to the corresponding key across all
  branches.

  ## Example

      Graph.add_channel(graph, :findings, into: :findings, with: &Map.merge/2)

  This declares that any branch that writes to the `:findings` key
  contributes a partial value; the join merges all contributions using
  `Map.merge/2`.

  ## Reducer contract

  The `with` reducer is a 2-arity function `(left, right) -> merged`.
  Branch states are folded left-to-right in `upstream_ids` order:

      [branch_a_value, branch_b_value, branch_c_value]
      |> Enum.reduce(&reducer.(&2, &1))

  Keys for which no channel is declared use last-write-wins by branch
  index (the rightmost branch's value wins).
  """

  @type t :: %__MODULE__{
          name: atom() | binary(),
          into: atom() | binary(),
          with: (any(), any() -> any())
        }

  @enforce_keys [:name, :into, :with]
  defstruct [:name, :into, :with]
end
