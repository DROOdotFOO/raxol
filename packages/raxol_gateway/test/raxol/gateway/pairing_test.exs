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

  describe "pairing codes" do
    test "issues an 8-char code from the unambiguous alphabet" do
      p = start_pairing()
      assert {:ok, code} = Pairing.request_code(p, "u1")
      assert String.length(code) == 8
      assert code =~ ~r/^[A-HJ-NP-Z2-9]+$/
    end

    test "confirming a valid code pairs the user" do
      p = start_pairing()
      {:ok, code} = Pairing.request_code(p, "u1")
      assert {:ok, "u1"} = Pairing.confirm(p, code)
      assert Pairing.paired?(p, "u1")
    end

    test "a code is single-use" do
      p = start_pairing()
      {:ok, code} = Pairing.request_code(p, "u1")
      assert {:ok, "u1"} = Pairing.confirm(p, code)
      assert {:error, :invalid} = Pairing.confirm(p, code)
    end

    test "an expired code is rejected" do
      p = start_pairing(code_ttl_ms: 0)
      {:ok, code} = Pairing.request_code(p, "u1")
      assert {:error, :expired} = Pairing.confirm(p, code)
    end

    test "rate-limits repeated requests from one user" do
      p = start_pairing()
      assert {:ok, _} = Pairing.request_code(p, "u1")
      assert {:error, :rate_limited} = Pairing.request_code(p, "u1")
    end

    test "locks out confirmation after repeated failures" do
      p = start_pairing(max_failures: 2)
      assert {:error, :invalid} = Pairing.confirm(p, "BADCODE1")
      assert {:error, :invalid} = Pairing.confirm(p, "BADCODE2")
      assert {:error, :locked_out} = Pairing.confirm(p, "BADCODE3")
    end
  end

  describe "authorize/2 check order" do
    test "paired users are allowed" do
      p = start_pairing()
      Pairing.approve(p, "u1")
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
      Pairing.allow(p, "u2", {:platform, :telegram})
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

      :ok = Pairing.approve(name, "u-runtime")
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
end
