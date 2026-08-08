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

  # A blank or short secret makes the HMAC forgeable offline — a declared-but-
  # empty RAXOL_SHARE_SECRET, or a too-short one, must not authenticate a token
  # any anonymous party can compute. Both mint and verify refuse below this.
  @min_secret_bytes 32

  # The share payload's session ids ride inside a signed token; both sign and
  # verify refuse ids that could not name a journal directory (a `:` in the id
  # would also break the `v1:<id>:<exp>` framing, so an unvalidated id mints a
  # permanently unverifiable token).
  @session_id_re ~r/\A[A-Za-z0-9._-]+\z/

  @doc "Whether `secret` is present and long enough to sign/verify with."
  @spec secret_ok?(term()) :: boolean()
  def secret_ok?(secret),
    do: is_binary(secret) and byte_size(secret) >= @min_secret_bytes

  @doc "Whether `session_id` is a shape both sign and verify accept."
  @spec valid_session_id?(term()) :: boolean()
  def valid_session_id?(session_id),
    do: is_binary(session_id) and Regex.match?(@session_id_re, session_id)

  @doc """
  Mint a token for `session_id`. Options: `:ttl_s` (default 24h),
  `:now_s` (injectable clock, unix seconds).

  Raises `ArgumentError` on a blank/short secret or an unverifiable
  `session_id` — a mis-mint fails loudly here rather than printing a link
  that can never verify (or that anyone can forge). Callers gate first with
  `secret_ok?/1` and `valid_session_id?/1`.
  """
  @spec sign(String.t(), String.t(), keyword()) :: String.t()
  def sign(session_id, secret, opts \\ [])
      when is_binary(session_id) and is_binary(secret) do
    unless secret_ok?(secret) do
      raise ArgumentError,
            "share secret must be at least #{@min_secret_bytes} bytes"
    end

    unless valid_session_id?(session_id) do
      raise ArgumentError, "session id #{inspect(session_id)} is not shareable"
    end

    now = Keyword.get(opts, :now_s, System.system_time(:second))
    ttl = Keyword.get(opts, :ttl_s, @default_ttl_s)
    payload = "v1:#{session_id}:#{now + ttl}"
    Base.url_encode64(payload <> ":" <> mac(secret, payload), padding: false)
  end

  @doc """
  Verify a token: `{:ok, session_id}` or `{:error, :invalid | :expired}`.
  A blank/short secret fails closed (`{:error, :invalid}`).
  """
  @spec verify(String.t(), String.t(), keyword()) ::
          {:ok, String.t()} | {:error, :invalid | :expired}
  def verify(token, secret, opts \\ []) when is_binary(secret) do
    now = Keyword.get(opts, :now_s, System.system_time(:second))

    with true <- secret_ok?(secret),
         {:ok, decoded} <- decode(token),
         [payload, tag] <- resplit(decoded),
         true <- :crypto.hash_equals(mac(secret, payload), tag),
         ["v1", session_id, exp] <- String.split(payload, ":", parts: 3),
         {exp_s, ""} <- Integer.parse(exp),
         true <- valid_session_id?(session_id) do
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
