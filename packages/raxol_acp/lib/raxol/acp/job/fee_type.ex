defmodule Raxol.ACP.Job.FeeType do
  @moduledoc """
  Canonical `FeeType` enum for payable ACP memos.

  Mirrors `enum ACPSimple.FeeType` (verified against
  `@virtuals-protocol/acp-node@0.3.0-beta.40`). Passed on-chain as
  `uint8` in `createPayableMemo`.

  | atom              | uint8 | meaning                                   |
  |-------------------|-------|-------------------------------------------|
  | `:no_fee`         | 0     | no platform fee on the transfer           |
  | `:immediate_fee`  | 1     | flat fee taken immediately                |
  | `:deferred_fee`   | 2     | flat fee deferred to settlement           |
  | `:percentage_fee` | 3     | fee as a percentage (basis points) of amount |
  """

  @type t :: :no_fee | :immediate_fee | :deferred_fee | :percentage_fee

  @types [:no_fee, :immediate_fee, :deferred_fee, :percentage_fee]

  @doc "List every defined fee type atom."
  @spec types() :: [t()]
  def types, do: @types

  @doc "Convert an atom to the canonical `uint8` id."
  @spec to_uint8(t()) :: 0..3
  def to_uint8(:no_fee), do: 0
  def to_uint8(:immediate_fee), do: 1
  def to_uint8(:deferred_fee), do: 2
  def to_uint8(:percentage_fee), do: 3

  @doc "Convert a canonical `uint8` id back to its atom, or `:error`."
  @spec from_uint8(non_neg_integer()) :: {:ok, t()} | :error
  def from_uint8(0), do: {:ok, :no_fee}
  def from_uint8(1), do: {:ok, :immediate_fee}
  def from_uint8(2), do: {:ok, :deferred_fee}
  def from_uint8(3), do: {:ok, :percentage_fee}
  def from_uint8(_), do: :error
end
