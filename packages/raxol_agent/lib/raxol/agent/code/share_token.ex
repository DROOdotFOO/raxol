defmodule Raxol.Agent.Code.ShareToken do
  @moduledoc """
  Signed, expiring tokens for read-only session sharing.

  A token binds a session id to an expiry under an HMAC (SHA-256) of a
  host-held secret — offline-verifiable, no state, no Phoenix coupling.
  The TUI's `/share` mints one; `Raxol.Agent.Code.ShareLive` (or any
  host surface) verifies it before replaying the session. Possession of
  a valid token grants READ access to that one session until expiry;
  treat tokens like the transcripts they unlock.
  """

  @default_ttl_s 86_400

  # The share payload's session ids ride inside a signed token, but the
  # verifier still refuses ids that could not name a journal directory —
  # defense in depth against a signing-side bug.
  @session_id_re ~r/\A[A-Za-z0-9._-]+\z/

  @doc """
  Mint a token for `session_id`. Options: `:ttl_s` (default 24h),
  `:now_s` (injectable clock, unix seconds).
  """
  @spec sign(String.t(), String.t(), keyword()) :: String.t()
  def sign(session_id, secret, opts \\ [])
      when is_binary(session_id) and is_binary(secret) do
    now = Keyword.get(opts, :now_s, System.system_time(:second))
    ttl = Keyword.get(opts, :ttl_s, @default_ttl_s)
    payload = "v1:#{session_id}:#{now + ttl}"
    Base.url_encode64(payload <> ":" <> mac(secret, payload), padding: false)
  end

  @doc """
  Verify a token: `{:ok, session_id}` or `{:error, :invalid | :expired}`.
  """
  @spec verify(String.t(), String.t(), keyword()) ::
          {:ok, String.t()} | {:error, :invalid | :expired}
  def verify(token, secret, opts \\ []) when is_binary(secret) do
    now = Keyword.get(opts, :now_s, System.system_time(:second))

    with {:ok, decoded} <- decode(token),
         [payload, tag] <- resplit(decoded),
         true <- :crypto.hash_equals(mac(secret, payload), tag),
         ["v1", session_id, exp] <- String.split(payload, ":", parts: 3),
         {exp_s, ""} <- Integer.parse(exp),
         true <- Regex.match?(@session_id_re, session_id) do
      if now <= exp_s, do: {:ok, session_id}, else: {:error, :expired}
    else
      _mismatch -> {:error, :invalid}
    end
  end

  defp decode(token) when is_binary(token),
    do: Base.url_decode64(token, padding: false)

  defp decode(_token), do: :error

  # The MAC is the fixed-size 32-byte suffix; everything before the last
  # separator is the payload.
  defp resplit(decoded) when byte_size(decoded) > 33 do
    payload_size = byte_size(decoded) - 33

    case decoded do
      <<payload::binary-size(^payload_size), ?:, tag::binary-size(32)>> ->
        [payload, tag]

      _other ->
        :error
    end
  end

  defp resplit(_decoded), do: :error

  defp mac(secret, payload), do: :crypto.mac(:hmac, :sha256, secret, payload)
end
