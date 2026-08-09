defmodule Raxol.Agent.Auth.PkceTest do
  @moduledoc """
  PKCE is the only thing standing between our loopback port and a code any
  local process could inject, so the challenge derivation is checked against
  RFC 7636's own test vector rather than against itself.
  """
  use ExUnit.Case, async: true

  alias Raxol.Agent.Auth.Pkce

  # RFC 7636 Appendix B.
  @rfc_verifier "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"
  @rfc_challenge "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM"

  test "derives the challenge RFC 7636 Appendix B specifies" do
    assert Pkce.challenge(@rfc_verifier) == @rfc_challenge
  end

  test "a pair built from a verifier carries that vector's challenge" do
    pkce = Pkce.new(@rfc_verifier)

    assert pkce.verifier == @rfc_verifier
    assert pkce.challenge == @rfc_challenge
    assert pkce.method == "S256"
  end

  test "the challenge is unpadded base64url, not base64" do
    challenge = Pkce.challenge("any verifier at all")

    refute String.contains?(challenge, "=")
    refute String.contains?(challenge, "+")
    refute String.contains?(challenge, "/")
  end

  describe "a generated verifier" do
    test "falls inside RFC 7636's 43..128 character range" do
      length = String.length(Pkce.new().verifier)

      assert length >= 43
      assert length <= 128
    end

    test "uses only the unreserved characters the RFC allows" do
      assert Pkce.new().verifier =~ ~r/\A[A-Za-z0-9\-._~]+\z/
    end

    test "differs every time, or the binding proves nothing" do
      verifiers = for _ <- 1..50, do: Pkce.new().verifier

      assert length(Enum.uniq(verifiers)) == 50
    end
  end

  # The verifier is the half that turns a code into a credential. A crash
  # report or a logged struct must not carry it.
  test "inspect redacts the verifier and keeps the public challenge" do
    inspected = inspect(Pkce.new(@rfc_verifier))

    refute inspected =~ @rfc_verifier
    assert inspected =~ "[REDACTED]"
    assert inspected =~ @rfc_challenge
  end
end
