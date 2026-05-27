defmodule Raxol.ACP.Job.MemoType do
  @moduledoc """
  Canonical `MemoType` enum mirrored from the Virtuals ACP contract
  (`enum InteractionLedger.MemoType` in the deployed `createMemo` ABI).

  Memos are passed on-chain as `uint8`. Atoms used in raxol_acp map
  1:1 to the canonical integer ids.

  | atom                  | uint8 |
  |-----------------------|-------|
  | `:message`            | 0     |
  | `:context_url`        | 1     |
  | `:image_url`          | 2     |
  | `:voice_url`          | 3     |
  | `:object_url`         | 4     |
  | `:txhash`             | 5     |
  | `:payable_request`    | 6     |
  | `:payable_transfer`   | 7     |
  | `:payable_fee`        | 8     |
  | `:payable_fee_request`| 9     |

  Source: `@virtuals-protocol/acp-node` 0.3.0-beta.40 bundled ABI for
  `createMemo(uint256,string,uint8,bool,uint8)`.
  """

  @type t ::
          :message
          | :context_url
          | :image_url
          | :voice_url
          | :object_url
          | :txhash
          | :payable_request
          | :payable_transfer
          | :payable_fee
          | :payable_fee_request

  @types [
    :message,
    :context_url,
    :image_url,
    :voice_url,
    :object_url,
    :txhash,
    :payable_request,
    :payable_transfer,
    :payable_fee,
    :payable_fee_request
  ]

  @doc "List every defined memo type atom."
  @spec types() :: [t()]
  def types, do: @types

  @doc """
  Convert an atom to the canonical `uint8` id, or raise on unknown input.
  """
  @spec to_uint8(t()) :: 0..9
  def to_uint8(:message), do: 0
  def to_uint8(:context_url), do: 1
  def to_uint8(:image_url), do: 2
  def to_uint8(:voice_url), do: 3
  def to_uint8(:object_url), do: 4
  def to_uint8(:txhash), do: 5
  def to_uint8(:payable_request), do: 6
  def to_uint8(:payable_transfer), do: 7
  def to_uint8(:payable_fee), do: 8
  def to_uint8(:payable_fee_request), do: 9

  @doc """
  Convert a canonical `uint8` id back to its atom, or `:error` if unknown.
  """
  @spec from_uint8(non_neg_integer()) :: {:ok, t()} | :error
  def from_uint8(0), do: {:ok, :message}
  def from_uint8(1), do: {:ok, :context_url}
  def from_uint8(2), do: {:ok, :image_url}
  def from_uint8(3), do: {:ok, :voice_url}
  def from_uint8(4), do: {:ok, :object_url}
  def from_uint8(5), do: {:ok, :txhash}
  def from_uint8(6), do: {:ok, :payable_request}
  def from_uint8(7), do: {:ok, :payable_transfer}
  def from_uint8(8), do: {:ok, :payable_fee}
  def from_uint8(9), do: {:ok, :payable_fee_request}
  def from_uint8(_), do: :error
end
