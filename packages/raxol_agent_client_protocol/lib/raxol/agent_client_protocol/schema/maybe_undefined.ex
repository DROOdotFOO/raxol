defmodule Raxol.AgentClientProtocol.Schema.MaybeUndefined do
  @moduledoc """
  A three-state value type: `:undefined`, `nil` (null), or `{:value, term}`.

  Distinguishes a missing field (undefined) from an explicitly null field.
  This is load-bearing for partial-update semantics where omitting a field
  means "don't change" and setting it to null means "clear".

  ## JSON serialization

  - `:undefined` -> field is omitted from JSON output
  - `nil` -> `null`
  - `{:value, x}` -> the JSON encoding of `x`

  > #### Interim module {: .warning}
  > This is the faithful f1729 port (including its `{:skip}` encode sentinel,
  > consumed only by struct-local `to_json` helpers). It is scheduled to be
  > replaced by the `Schema.Codec`-integrated `Maybe` design
  > (`acp-maybe-meta-design.md`) after the G1 design gate.

  Ported from the MIT `f1729/agent_client_protocol` (c) 2025 f1729; see NOTICE.md.
  """

  @type t(value) :: :undefined | nil | {:value, value}

  @doc "Returns true if the value is undefined."
  @spec undefined?(t(term())) :: boolean()
  def undefined?(:undefined), do: true
  def undefined?(_), do: false

  @doc "Returns true if the value is null."
  @spec null?(t(term())) :: boolean()
  def null?(nil), do: true
  def null?(_), do: false

  @doc "Returns true if the value carries a value."
  @spec value?(t(term())) :: boolean()
  def value?({:value, _}), do: true
  def value?(_), do: false

  @doc "Returns the inner value, or nil if undefined or null."
  @spec value(t(value)) :: value | nil when value: term()
  def value({:value, v}), do: v
  def value(_), do: nil

  @doc "Maps a function over the value, preserving undefined/null."
  @spec map_value(t(value), (value -> mapped)) :: t(mapped) when value: term(), mapped: term()
  def map_value(:undefined, _fun), do: :undefined
  def map_value(nil, _fun), do: nil
  def map_value({:value, v}, fun), do: {:value, fun.(v)}

  @doc """
  Applies partial-update semantics against a current value.

  - `:undefined` -> returns the current value unchanged (don't change)
  - `nil` -> returns nil (clear)
  - `{:value, v}` -> returns v (set)
  """
  @spec update_to(t(value), value | nil) :: value | nil when value: term()
  def update_to(:undefined, current), do: current
  def update_to(nil, _current), do: nil
  def update_to({:value, v}, _current), do: v

  @doc """
  Encodes for JSON serialization. Returns `{:skip}` for undefined (the caller
  omits the field), `nil` for null, or the value itself.
  """
  @spec to_json(t(term())) :: {:skip} | nil | term()
  def to_json(:undefined), do: {:skip}
  def to_json(nil), do: nil
  def to_json({:value, v}), do: v

  @doc """
  Decodes from JSON deserialization. Call with `:missing` if the key was not
  present, or with the raw value if it was.
  """
  @spec from_json(:missing | term()) :: t(term())
  def from_json(:missing), do: :undefined
  def from_json(nil), do: nil
  def from_json(v), do: {:value, v}
end
