defmodule Raxol.Agent.Code.ShareTokenTest do
  use ExUnit.Case, async: true

  alias Raxol.Agent.Code.ShareToken

  # >= 32 bytes: the minimum an HMAC key must be to sign/verify.
  @secret String.duplicate("share-secret-", 4)

  test "round-trips a session id within its ttl" do
    token = ShareToken.sign("sess-1-2", @secret, now_s: 1_000, ttl_s: 60)

    assert {:ok, %{session_id: "sess-1-2", scope: ""}} =
             ShareToken.verify(token, @secret, now_s: 1_050)
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
      forged = forge("v2::sess-1-2:9999999999", "")

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
      # A colon breaks the v2:<scope>:<id>:<exp> framing; a slash fails the
      # charset; a dot segment is a traversal shape, not a name.
      assert_raise ArgumentError, fn ->
        ShareToken.sign("team:review", @secret)
      end

      assert_raise ArgumentError, fn -> ShareToken.sign("../escape", @secret) end
      assert_raise ArgumentError, fn -> ShareToken.sign("..", @secret) end
      assert_raise ArgumentError, fn -> ShareToken.sign(".", @secret) end
    end

    test "verify still refuses a smuggled unsafe id (defense in depth)" do
      # Hand-craft validly-MAC'd tokens whose ids would fail sign, proving the
      # verifier rejects them too rather than trusting the signature alone.
      for id <- ["../escape", "..", "."] do
        token = forge("v2::#{id}:9999999999", @secret)
        assert {:error, :invalid} = ShareToken.verify(token, @secret)
      end
    end

    test "valid_session_id?/1 matches the accepted shape" do
      assert ShareToken.valid_session_id?("sess-1723-99")
      refute ShareToken.valid_session_id?("team:review")
      refute ShareToken.valid_session_id?("../escape")
      refute ShareToken.valid_session_id?("")
      # Dot segments pass the charset but name a directory, not a session.
      refute ShareToken.valid_session_id?(".")
      refute ShareToken.valid_session_id?("..")
    end
  end

  describe "scope binding (cross-tenant ambiguity)" do
    test "round-trips the scope it was minted under" do
      token = ShareToken.sign("sess-1-2", @secret, scope: "alice")

      assert {:ok, %{session_id: "sess-1-2", scope: "alice"}} =
               ShareToken.verify(token, @secret)
    end

    test "the scope is signed, so it cannot be swapped to another tenant" do
      alice = ShareToken.sign("sess-1-2", @secret, scope: "alice")
      bob = ShareToken.sign("sess-1-2", @secret, scope: "bob")

      # Same id, same secret, same expiry window: only the scope differs, and
      # it changes the token — a bob-scoped view cannot replay alice's tree by
      # presenting alice's token, and neither token verifies as the other.
      refute alice == bob
      assert {:ok, %{scope: "alice"}} = ShareToken.verify(alice, @secret)
      assert {:ok, %{scope: "bob"}} = ShareToken.verify(bob, @secret)
    end

    test "sign raises on a scope that could never verify" do
      for scope <- ["ssh:alice", "../escape", "Alice", "..", "."] do
        assert_raise ArgumentError, fn ->
          ShareToken.sign("sess-1-2", @secret, scope: scope)
        end
      end
    end

    test "verify refuses a smuggled unsafe scope (defense in depth)" do
      token = forge("v2:../escape:sess-1-2:9999999999", @secret)
      assert {:error, :invalid} = ShareToken.verify(token, @secret)
    end

    test "a v1 token no longer verifies" do
      # The old framing carried no scope, so its ids were ambiguous across
      # tenants. It must not be accepted alongside v2.
      token = forge("v1:sess-1-2:9999999999", @secret)
      assert {:error, :invalid} = ShareToken.verify(token, @secret)
    end

    test "valid_scope?/1 matches the accepted shape" do
      assert ShareToken.valid_scope?("")
      assert ShareToken.valid_scope?("alice")
      assert ShareToken.valid_scope?("a-tenant.1_x")
      refute ShareToken.valid_scope?("ssh:alice")
      refute ShareToken.valid_scope?("Alice")
      refute ShareToken.valid_scope?("../escape")
      refute ShareToken.valid_scope?(nil)
    end
  end

  # A validly-MAC'd token over an arbitrary payload, for proving the verifier
  # re-checks structure rather than trusting the signature alone.
  defp forge(payload, secret) do
    Base.url_encode64(
      payload <> ":" <> :crypto.mac(:hmac, :sha256, secret, payload),
      padding: false
    )
  end
end
