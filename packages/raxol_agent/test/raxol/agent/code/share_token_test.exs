defmodule Raxol.Agent.Code.ShareTokenTest do
  use ExUnit.Case, async: true

  alias Raxol.Agent.Code.ShareToken

  @secret "test-share-secret"

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

    assert {:error, :invalid} = ShareToken.verify(token, "other-secret")
    assert {:error, :invalid} = ShareToken.verify(token <> "x", @secret)
    assert {:error, :invalid} = ShareToken.verify("", @secret)
    assert {:error, :invalid} = ShareToken.verify("not-base64!!", @secret)

    # Re-signing a different session under another secret never verifies.
    forged = ShareToken.sign("sess-other", "attacker")
    assert {:error, :invalid} = ShareToken.verify(forged, @secret)
  end

  test "a token cannot smuggle an unsafe session id" do
    # Even a correctly signed token is refused if the id could not name a
    # journal dir (signing-side bug containment). Colons cannot survive
    # the payload split, and slashes fail the charset.
    token = ShareToken.sign("../escape", @secret)
    assert {:error, :invalid} = ShareToken.verify(token, @secret)
  end
end
