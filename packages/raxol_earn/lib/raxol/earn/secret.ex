defmodule Raxol.Earn.Secret do
  @moduledoc """
  An opaque wrapper around sensitive bytes (an EOA private key) that refuses to
  reveal itself through `Inspect`, logging, or string interpolation.

  A raw private key held in an adapter's config map leaks the moment that map
  is inspected: an unhandled crash makes OTP's default error report `inspect`
  the call arguments (which include the adapter) into the log, and `dbg/1` or an
  exception carrying the value does the same. Wrapping the bytes here means those
  paths print `#Raxol.Earn.Secret<redacted>` instead of the key. The bytes are
  recovered only at the signing call site via `reveal/1`.

  This does not protect the key while it is in BEAM memory; it closes the
  accidental-disclosure paths: logs, crash dumps, inspect output.
  """

  @enforce_keys [:bytes]
  defstruct [:bytes]

  @opaque t :: %__MODULE__{bytes: binary()}

  @doc "Wrap raw bytes. Returns the value unchanged if already wrapped."
  @spec new(binary() | t()) :: t()
  def new(%__MODULE__{} = secret), do: secret
  def new(bytes) when is_binary(bytes), do: %__MODULE__{bytes: bytes}

  @doc "Reveal the wrapped bytes for use at a signing call site."
  @spec reveal(t()) :: binary()
  def reveal(%__MODULE__{bytes: bytes}), do: bytes

  defimpl Inspect do
    def inspect(_secret, _opts), do: "#Raxol.Earn.Secret<redacted>"
  end
end
