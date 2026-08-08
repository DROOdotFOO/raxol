defmodule Raxol.Agent.Code.ShareToken do
  @moduledoc """
  Signed, expiring tokens for read-only session sharing.

  A token binds a session id AND its scope to an expiry under an HMAC
  (SHA-256) of a host-held secret — offline-verifiable, no state, no
  Phoenix coupling. The TUI's `/share` mints one;
  `Raxol.Agent.Code.ShareLive` (or any host surface) verifies it before
  replaying the session. Possession of a valid token grants READ access
  to that one session until expiry; treat tokens like the transcripts
  they unlock.

  ## Scope

  Session ids are unique within a journal base, not across a host: every
  multi-tenant tenant writes its own `<tenants_root>/<user>/sessions`
  tree, and `sess-<seconds>-<n>` ids can coincide between them. A token
  carrying only an id would therefore name a session ambiguously — the
  viewer would have to guess a base, and a guess that lands in another
  tenant's tree is a cross-tenant read.

  So the scope (the empty string for the host's own default base, else a
  tenant name) is inside the signed bytes, and the verifier hands it back
  for the reader to resolve a base from. A token minted for one tenant
  cannot be replayed against another's tree without breaking the MAC.

  Scope and session id are both colon-free by construction, which is what
  lets the `v2:<scope>:<id>:<exp>` framing round-trip unambiguously.
  """

  @default_ttl_s 86_400

  # A blank or short secret makes the HMAC forgeable offline — a declared-but-
  # empty RAXOL_SHARE_SECRET, or a too-short one, must not authenticate a token
  # any anonymous party can compute. Both mint and verify refuse below this.
  @min_secret_bytes 32

  # The share payload's session ids ride inside a signed token; both sign and
  # verify refuse ids that could not name a journal directory (a `:` in the id
  # would also break the `v2:<scope>:<id>:<exp>` framing, so an unvalidated id
  # mints a permanently unverifiable token). `.` and `..` match the charset but
  # are dot segments, not names — the same pair `Raxol.SSH.Server.sanitize_tenant/1`
  # refuses, excluded here so the two id validators cannot disagree.
  @session_id_re ~r/\A[A-Za-z0-9._-]+\z/
  @dot_segments [".", ".."]

  # The empty scope means the host's own default journal base. A non-empty one
  # is a tenant name, held to the same shape `Raxol.SSH.Server.sanitize_tenant/1`
  # produces so it can only ever name a directory that tenancy created.
  @scope_re ~r/\A[a-z0-9][a-z0-9._-]{0,63}\z/

  @doc "Whether `secret` is present and long enough to sign/verify with."
  @spec secret_ok?(term()) :: boolean()
  def secret_ok?(secret),
    do: is_binary(secret) and byte_size(secret) >= @min_secret_bytes

  @doc "Whether `session_id` is a shape both sign and verify accept."
  @spec valid_session_id?(term()) :: boolean()
  def valid_session_id?(session_id),
    do:
      is_binary(session_id) and session_id not in @dot_segments and
        Regex.match?(@session_id_re, session_id)

  @doc """
  Whether `scope` is a shape both sign and verify accept: `""` (the host's
  default journal base) or a tenant name.
  """
  @spec valid_scope?(term()) :: boolean()
  def valid_scope?(""), do: true

  def valid_scope?(scope),
    do:
      is_binary(scope) and scope not in @dot_segments and
        Regex.match?(@scope_re, scope)

  @doc """
  Mint a token for `session_id`. Options: `:scope` (default `""`, the
  host's own journal base), `:ttl_s` (default 24h), `:now_s` (injectable
  clock, unix seconds).

  Raises `ArgumentError` on a blank/short secret, an unverifiable
  `session_id`, or an unverifiable `:scope` — a mis-mint fails loudly here
  rather than printing a link that can never verify (or that anyone can
  forge). Callers gate first with `secret_ok?/1`, `valid_session_id?/1`,
  and `valid_scope?/1`.
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

    scope = Keyword.get(opts, :scope, "")

    unless valid_scope?(scope) do
      raise ArgumentError, "share scope #{inspect(scope)} is not shareable"
    end

    now = Keyword.get(opts, :now_s, System.system_time(:second))
    ttl = Keyword.get(opts, :ttl_s, @default_ttl_s)
    payload = "v2:#{scope}:#{session_id}:#{now + ttl}"
    Base.url_encode64(payload <> ":" <> mac(secret, payload), padding: false)
  end

  @doc """
  Verify a token: `{:ok, %{session_id: id, scope: scope}}` or
  `{:error, :invalid | :expired}`. A blank/short secret fails closed
  (`{:error, :invalid}`).

  The scope comes back so the caller can resolve the journal base the id
  is meaningful in; a caller that ignores it is reading an ambiguous id.
  """
  @spec verify(String.t(), String.t(), keyword()) ::
          {:ok, %{session_id: String.t(), scope: String.t()}}
          | {:error, :invalid | :expired}
  def verify(token, secret, opts \\ []) when is_binary(secret) do
    now = Keyword.get(opts, :now_s, System.system_time(:second))

    with true <- secret_ok?(secret),
         {:ok, decoded} <- decode(token),
         [payload, tag] <- resplit(decoded),
         true <- :crypto.hash_equals(mac(secret, payload), tag),
         ["v2", scope, session_id, exp] <-
           String.split(payload, ":", parts: 4),
         {exp_s, ""} <- Integer.parse(exp),
         true <- valid_session_id?(session_id),
         true <- valid_scope?(scope) do
      if now <= exp_s,
        do: {:ok, %{session_id: session_id, scope: scope}},
        else: {:error, :expired}
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
