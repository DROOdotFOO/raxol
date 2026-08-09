defmodule Raxol.Agent.Auth.Pkce do
  @moduledoc """
  A PKCE (RFC 7636) verifier/challenge pair for the browser OAuth flows raxol
  runs itself.

  PKCE is what makes a loopback redirect safe to use without a client secret.
  The challenge travels to the provider in the browser URL; the verifier never
  leaves this process until the code exchange. Any other local process can
  connect to our loopback port and hand us an authorization code, but that code
  was minted against *its* challenge, so exchanging it with *our* verifier
  fails. That binding, not the port being loopback, is what keeps an injected
  code from becoming a stored credential.

  `new/1` takes an optional verifier so a test can pin the pair; production
  callers use `new/0` and get 32 bytes of `:crypto.strong_rand_bytes/1`.
  """

  # RFC 7636 §4.1 allows 43..128 characters; 32 random bytes base64url-encode
  # to exactly 43, the low end of the range and 256 bits of entropy.
  @verifier_bytes 32

  @method "S256"

  @type t :: %__MODULE__{
          verifier: String.t(),
          challenge: String.t(),
          method: String.t()
        }

  @enforce_keys [:verifier, :challenge]
  defstruct verifier: nil, challenge: nil, method: @method

  @doc "A fresh pair, or one derived from `verifier` when given."
  @spec new(String.t() | nil) :: t()
  def new(verifier \\ nil)

  def new(nil), do: new(random_verifier())

  def new(verifier) when is_binary(verifier) and verifier != "" do
    %__MODULE__{
      verifier: verifier,
      challenge: challenge(verifier),
      method: @method
    }
  end

  @doc """
  The S256 challenge for `verifier`: base64url of its SHA-256 digest, unpadded
  per RFC 7636 §4.2.
  """
  @spec challenge(String.t()) :: String.t()
  def challenge(verifier) when is_binary(verifier) do
    :sha256
    |> :crypto.hash(verifier)
    |> Base.url_encode64(padding: false)
  end

  @doc "The challenge method these pairs use (`\"S256\"`)."
  @spec method() :: String.t()
  def method, do: @method

  defp random_verifier do
    @verifier_bytes
    |> :crypto.strong_rand_bytes()
    |> Base.url_encode64(padding: false)
  end
end

defimpl Inspect, for: Raxol.Agent.Auth.Pkce do
  import Inspect.Algebra

  # The verifier is the secret half of the pair: it is what turns an
  # authorization code into a credential. Keep it out of logs and crash
  # reports, the same way the wallet keys elsewhere in the tree are redacted.
  def inspect(pkce, opts) do
    concat([
      "#Raxol.Agent.Auth.Pkce<challenge: ",
      to_doc(pkce.challenge, opts),
      ", verifier: [REDACTED]>"
    ])
  end
end
