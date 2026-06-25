defmodule Raxol.Payments.Secret do
  @moduledoc """
  An opaque wrapper around sensitive bytes (a private key) that refuses to
  reveal itself through `Inspect`, logging, or string interpolation.

  A raw private key held in plain process state or a config map leaks the
  moment that state is inspected: an unhandled GenServer crash makes OTP's
  default error report `inspect` the process state into the log, and `dbg/1`
  or an exception carrying the value does the same. Wrapping the bytes here
  means those paths print `#Raxol.Payments.Secret<redacted>` instead of the
  key. The bytes are recovered only at the signing call site via `reveal/1`.

  This does not protect the key while it is in BEAM memory (it is not zeroed,
  and nothing prevents a determined caller from `reveal/1`-ing it). It closes
  the accidental-disclosure paths: logs, crash dumps, inspect output.

      secret = Raxol.Payments.Secret.new(private_key_bytes)
      inspect(secret)            #=> "#Raxol.Payments.Secret<redacted>"
      Raxol.Payments.Secret.reveal(secret) == private_key_bytes  #=> true
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
    def inspect(_secret, _opts), do: "#Raxol.Payments.Secret<redacted>"
  end
end
