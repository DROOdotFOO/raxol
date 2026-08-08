defmodule Raxol.Agent.Code.ShareTokenTest do
  use ExUnit.Case, async: true

  alias Raxol.Agent.Code.ShareToken

  # >= 32 bytes: the minimum an HMAC key must be to sign/verify.
  @secret String.duplicate("share-secret-", 4)

  test "round-trips a session id within its ttl" do
    token = ShareToken.sign("sess-1-2", @secret, now_s: 1_000, ttl_s: 60)
    assert {:ok, "sess-1-2"} = ShareToken.verify(token, @secret, now_s: 1_050)
  end

  test "expires" do
    token = ShareToken.sign("sess-1-2", @secret, now_s: 1_000, ttl_s: 60)

    assert {:error, :expired} =
             ShareToken.verify(token, @secret, now_s: 1_061)
  end

  test "rejects tampering and wrong secrets" do
    token = ShareToken.sign("sess-1-2", @secret)
    other = String.duplicate("other-secret-", 4)

    assert {:error, :invalid} = ShareToken.verify(token, other)
    assert {:error, :invalid} = ShareToken.verify(token <> "x", @secret)
    assert {:error, :invalid} = ShareToken.verify("", @secret)
    assert {:error, :invalid} = ShareToken.verify("not-base64!!", @secret)

    # Re-signing a different session under another secret never verifies.
    forged = ShareToken.sign("sess-other", String.duplicate("attacker", 5))
    assert {:error, :invalid} = ShareToken.verify(forged, @secret)
  end

  describe "secret hardening (offline forgery)" do
    test "verify fails closed on a blank or short secret" do
      token = ShareToken.sign("sess-1-2", @secret)

      # A declared-but-empty RAXOL_SHARE_SECRET ("") must not authenticate a
      # token anyone can HMAC with the empty key.
      assert {:error, :invalid} = ShareToken.verify(token, "")
      assert {:error, :invalid} = ShareToken.verify(token, "short")

      # And a token forged under the empty key does not slip through.
      forged =
        Base.url_encode64(
          "v1:sess-1-2:9999999999:" <>
            :crypto.mac(:hmac, :sha256, "", "v1:sess-1-2:9999999999"),
          padding: false
        )

      assert {:error, :invalid} = ShareToken.verify(forged, "")
    end

    test "sign raises on a blank or short secret" do
      assert_raise ArgumentError, fn -> ShareToken.sign("sess-1-2", "") end
      assert_raise ArgumentError, fn -> ShareToken.sign("sess-1-2", "short") end
    end

    test "secret_ok?/1 gates length" do
      refute ShareToken.secret_ok?("")
      refute ShareToken.secret_ok?(String.duplicate("x", 31))
      assert ShareToken.secret_ok?(String.duplicate("x", 32))
      refute ShareToken.secret_ok?(nil)
    end
  end

  describe "session id validation (unverifiable-token prevention)" do
    test "sign raises on an id that could never verify" do
      # A colon breaks the v1:<id>:<exp> framing; a slash fails the charset.
      assert_raise ArgumentError, fn -> ShareToken.sign("team:review", @secret) end
      assert_raise ArgumentError, fn -> ShareToken.sign("../escape", @secret) end
    end

    test "verify still refuses a smuggled unsafe id (defense in depth)" do
      # Hand-craft a validly-MAC'd token whose id would fail sign, proving the
      # verifier rejects it too rather than trusting the signature alone.
      payload = "v1:../escape:9999999999"

      token =
        Base.url_encode64(
          payload <> ":" <> :crypto.mac(:hmac, :sha256, @secret, payload),
          padding: false
        )

      assert {:error, :invalid} = ShareToken.verify(token, @secret)
    end

    test "valid_session_id?/1 matches the accepted shape" do
      assert ShareToken.valid_session_id?("sess-1723-99")
      refute ShareToken.valid_session_id?("team:review")
      refute ShareToken.valid_session_id?("../escape")
      refute ShareToken.valid_session_id?("")
    end
  end
end
