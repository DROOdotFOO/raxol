defmodule Raxol.Gateway.PairingTest do
  use ExUnit.Case, async: false

  alias Raxol.Gateway.Pairing
  alias Raxol.Gateway.Route

  defp start_pairing(opts \\ []) do
    name = :"pairing_#{System.unique_integer([:positive])}"
    start_supervised!(%{id: name, start: {Pairing, :start_link, [[{:name, name} | opts]]}})
    name
  end

  defp route(platform, user_id) do
    Route.new(%{platform: platform, chat_type: :dm, chat_id: 1, user_id: user_id})
  end

  @telegram {:platform, :telegram}

  describe "pairing codes" do
    test "issues an 8-char code from the unambiguous alphabet" do
      p = start_pairing()
      assert {:ok, code} = Pairing.request_code(p, "u1", @telegram)
      assert String.length(code) == 8
      assert code =~ ~r/^[A-HJ-NP-Z2-9]+$/
    end

    test "confirming a valid code pairs the user" do
      p = start_pairing()
      {:ok, code} = Pairing.request_code(p, "u1", @telegram)
      assert {:ok, "u1"} = Pairing.confirm(p, code)
      assert Pairing.paired?(p, "u1", :telegram)
    end

    test "a code is single-use" do
      p = start_pairing()
      {:ok, code} = Pairing.request_code(p, "u1", @telegram)
      assert {:ok, "u1"} = Pairing.confirm(p, code)
      assert {:error, :invalid} = Pairing.confirm(p, code)
    end

    test "an expired code is rejected" do
      p = start_pairing(code_ttl_ms: 0)
      {:ok, code} = Pairing.request_code(p, "u1", @telegram)
      assert {:error, :expired} = Pairing.confirm(p, code)
    end

    test "rate-limits repeated requests from one user" do
      p = start_pairing()
      assert {:ok, _} = Pairing.request_code(p, "u1", @telegram)
      assert {:error, :rate_limited} = Pairing.request_code(p, "u1", @telegram)
    end

    test "locks out confirmation after repeated failures" do
      p = start_pairing(max_failures: 2)
      assert {:error, :invalid} = Pairing.confirm(p, "BADCODE1")
      assert {:error, :invalid} = Pairing.confirm(p, "BADCODE2")
      assert {:error, :locked_out} = Pairing.confirm(p, "BADCODE3")
    end
  end

  describe "authorize/2 check order" do
    test "paired users are allowed on the platform they paired on" do
      p = start_pairing()
      Pairing.approve(p, "u1", @telegram)
      assert :allow = Pairing.authorize(p, route(:telegram, "u1"))
    end

    test "a platform set to allow-all admits anyone" do
      p = start_pairing()
      Pairing.allow_platform_all(p, :telegram)
      assert :allow = Pairing.authorize(p, route(:telegram, "stranger"))
      assert :deny = Pairing.authorize(p, route(:discord, "stranger"))
    end

    test "platform allowlist is scoped to that platform" do
      p = start_pairing()
      Pairing.allow(p, "u2", @telegram)
      assert :allow = Pairing.authorize(p, route(:telegram, "u2"))
      assert :deny = Pairing.authorize(p, route(:discord, "u2"))
    end

    test "global allowlist admits across platforms" do
      p = start_pairing()
      Pairing.allow(p, "u3", :global)
      assert :allow = Pairing.authorize(p, route(:telegram, "u3"))
      assert :allow = Pairing.authorize(p, route(:discord, "u3"))
    end

    test "unknown users are denied" do
      p = start_pairing()
      assert :deny = Pairing.authorize(p, route(:telegram, "nobody"))
      assert :deny = Pairing.authorize(p, route(:telegram, nil))
    end
  end

  # A user id is only a subject once it is paired with a platform. Telegram ids
  # are integers, Discord ids are snowflakes, email ids are addresses -- "12345"
  # is a different person on each, and no authority reconciles them. A grant that
  # named only an id used to admit all three.
  describe "grant scoping" do
    test "a pairing on one platform does not admit the same id on another" do
      p = start_pairing()
      Pairing.approve(p, "12345", @telegram)

      assert :allow = Pairing.authorize(p, route(:telegram, "12345"))
      assert :deny = Pairing.authorize(p, route(:discord, "12345"))
      assert :deny = Pairing.authorize(p, route(:email, "12345"))
      refute Pairing.paired?(p, "12345", :discord)
    end

    test "a code carries the scope it was ISSUED for, not the one it is redeemed in" do
      # The code is a bearer token. If confirm/2 chose the scope, a code minted
      # to admit someone on Telegram would be worth a grant anywhere.
      p = start_pairing()
      {:ok, code} = Pairing.request_code(p, "u1", @telegram)

      assert {:ok, "u1"} = Pairing.confirm(p, code)
      assert :allow = Pairing.authorize(p, route(:telegram, "u1"))
      assert :deny = Pairing.authorize(p, route(:discord, "u1"))
    end

    test "a :global pairing admits everywhere, which is why it has to be typed" do
      p = start_pairing()
      Pairing.approve(p, "u1", :global)

      assert :allow = Pairing.authorize(p, route(:telegram, "u1"))
      assert :allow = Pairing.authorize(p, route(:discord, "u1"))
    end

    test "revoking one platform leaves the others standing" do
      p = start_pairing()
      Pairing.approve(p, "u1", @telegram)
      Pairing.approve(p, "u1", {:platform, :discord})

      Pairing.revoke(p, "u1", @telegram)

      assert :deny = Pairing.authorize(p, route(:telegram, "u1"))
      assert :allow = Pairing.authorize(p, route(:discord, "u1"))
    end

    test "revoking :global does not reach the per-platform grants" do
      p = start_pairing()
      Pairing.approve(p, "u1", :global)
      Pairing.approve(p, "u1", @telegram)

      Pairing.revoke(p, "u1", :global)

      assert :allow = Pairing.authorize(p, route(:telegram, "u1"))
      assert :deny = Pairing.authorize(p, route(:discord, "u1"))
    end

    # `:global` is the cross-platform bucket's own key, so a scope naming it
    # would file a per-platform grant where every platform reads.
    test "refuses a scope that is not one" do
      p = start_pairing()

      for bad <- [{:platform, :global}, {:platform, nil}, {:platform, "telegram"}, :everyone, nil] do
        assert_raise ArgumentError, fn -> Pairing.approve(p, "u1", bad) end
      end

      assert :deny = Pairing.authorize(p, route(:telegram, "u1"))
    end
  end

  # A crash must not silently reverse the deployment's posture. Seeded from
  # opts, `init_manager/1` rebuilds it; seeded by calls against a running
  # server, a restart leaves an empty server no caller can distinguish from a
  # configured one -- open Consoles start denying everything, enforcing ones
  # forget their allowlist, and the boot that announced the posture is long past.
  describe "seeds" do
    test "an allowlist given as start opts is applied at init" do
      p =
        start_pairing(
          allow_platforms: [:telegram],
          allowed_users: ["u-global"],
          platform_users: [discord: ["u-discord"]]
        )

      assert :allow = Pairing.authorize(p, route(:telegram, "anyone"))
      assert :allow = Pairing.authorize(p, route(:slack, "u-global"))
      assert :allow = Pairing.authorize(p, route(:discord, "u-discord"))
      assert :deny = Pairing.authorize(p, route(:slack, "u-discord"))
      assert :deny = Pairing.authorize(p, route(:discord, "nobody"))
    end

    test "integer user ids seed the same as the strings a route carries" do
      p = start_pairing(allowed_users: [12_345], platform_users: [telegram: [678]])

      assert :allow = Pairing.authorize(p, route(:slack, "12345"))
      assert :allow = Pairing.authorize(p, route(:telegram, "678"))
    end

    # A keyword list admits duplicate keys, and collecting them `into: %{}` would
    # keep only the last -- silently dropping every id named earlier. That is a
    # lockout indistinguishable from never having configured them, which is the
    # ambiguity `known_keys/1` refuses one level up for a typo'd key.
    test "a platform named twice unions its ids rather than keeping the last" do
      p = start_pairing(platform_users: [telegram: ["first"], telegram: ["second"]])

      assert :allow = Pairing.authorize(p, route(:telegram, "first"))
      assert :allow = Pairing.authorize(p, route(:telegram, "second"))
    end

    # Filing ids written under "per platform" into the bucket that admits every
    # platform is a silent widening of the grant this scoping exists to narrow.
    # Refusing to start beats starting over-permissive.
    test "refuses :platform_users keyed on :global rather than merging it" do
      Process.flag(:trap_exit, true)

      assert {:error, {%ArgumentError{message: message}, _}} =
               Pairing.start_link(
                 name: :"pairing_bad_seed_#{System.unique_integer([:positive])}",
                 platform_users: [global: ["everyone"]]
               )

      assert message =~ "cannot be keyed on :global"
    end

    test "the seeded scopes admit exactly where they were written" do
      p = start_pairing(allowed_users: ["anywhere"], platform_users: [telegram: ["only-here"]])

      assert :allow = Pairing.authorize(p, route(:telegram, "anywhere"))
      assert :allow = Pairing.authorize(p, route(:discord, "anywhere"))
      assert :allow = Pairing.authorize(p, route(:telegram, "only-here"))
      assert :deny = Pairing.authorize(p, route(:discord, "only-here"))
    end

    test "the seeded posture survives a restart; a runtime pairing does not" do
      name = :"pairing_restart_#{System.unique_integer([:positive])}"

      sup =
        start_supervised!(%{
          id: :sup_for_pairing_restart,
          start:
            {Supervisor, :start_link,
             [
               [{Pairing, [name: name, allow_platforms: [:telegram]]}],
               [strategy: :one_for_one]
             ]}
        })

      :ok = Pairing.approve(name, "u-runtime", {:platform, :discord})
      assert :allow = Pairing.authorize(name, route(:discord, "u-runtime"))
      assert :allow = Pairing.authorize(name, route(:telegram, "anyone"))

      ref = Process.monitor(Process.whereis(name))
      Process.exit(Process.whereis(name), :kill)
      assert_receive {:DOWN, ^ref, :process, _pid, :killed}
      wait_for_restart(name)

      # The configured posture is back.
      assert :allow = Pairing.authorize(name, route(:telegram, "anyone"))
      # The in-memory pairing is not, which is what in-memory means.
      assert :deny = Pairing.authorize(name, route(:discord, "u-runtime"))

      Supervisor.stop(sup)
    end

    defp wait_for_restart(name, attempts \\ 100)

    defp wait_for_restart(name, 0), do: flunk("#{name} never restarted")

    defp wait_for_restart(name, attempts) do
      case Process.whereis(name) do
        nil ->
          Process.sleep(10)
          wait_for_restart(name, attempts - 1)

        pid ->
          pid
      end
    end
  end

  # `authorize/2` runs INSIDE this server, on a route an adapter built from wire
  # input that `Route.new/1` does not validate. A `user_id` that is not a scalar
  # used to raise `Protocol.UndefinedError` in `decide/2` -- and since Pairing is
  # the first `:rest_for_one` child, that crash took the session supervisor and
  # the router with it, on every retry, for every chat.
  describe "a malformed route" do
    test "denies rather than crashing the server" do
      p = start_pairing(allowed_users: ["alice"])
      pid = Process.whereis(p)

      for bad <- [%{"a" => 1}, {:tuple, 1}, ["list"], self()] do
        assert :deny = Pairing.authorize(p, route(:telegram, bad))
      end

      assert Process.alive?(pid)
      assert :allow = Pairing.authorize(p, route(:telegram, "alice"))
    end

    # Normalizing with a bare `to_string/1` would turn a nil id into "", which an
    # allowlist holding "" would then match.
    test "a nil user id denies, and does not become the empty string" do
      p = start_pairing(allowed_users: [""])

      assert :deny = Pairing.authorize(p, route(:telegram, nil))
    end
  end
end
