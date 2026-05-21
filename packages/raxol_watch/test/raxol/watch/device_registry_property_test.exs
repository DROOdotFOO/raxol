defmodule Raxol.Watch.DeviceRegistryPropertyTest do
  use ExUnit.Case, async: false
  use ExUnitProperties

  alias Raxol.Watch.DeviceRegistry

  setup do
    start_supervised!(DeviceRegistry)
    :ok
  end

  defp clear_table, do: DeviceRegistry.clear_all()

  defp token_gen, do: string(:alphanumeric, min_length: 1, max_length: 32)
  defp platform_gen, do: member_of([:apns, :fcm])

  defp prefs_gen do
    keyword_of(
      one_of([
        constant(boolean()),
        boolean()
      ])
    )
    |> map(fn _ ->
      [
        muted: Enum.random([true, false]),
        high_priority_only: Enum.random([true, false])
      ]
    end)
  end

  describe "round-trip" do
    property "register then list_devices contains the device with its prefs" do
      check all token <- token_gen(),
                platform <- platform_gen(),
                opts <- prefs_gen() do
        clear_table()
        :ok = DeviceRegistry.register(token, platform, opts)

        assert [{^token, ^platform, prefs}] = DeviceRegistry.list_devices()
        assert prefs.muted == Keyword.get(opts, :muted, false)
        assert prefs.high_priority_only == Keyword.get(opts, :high_priority_only, false)
      end
    end

    property "register then unregister leaves the table empty" do
      check all token <- token_gen(),
                platform <- platform_gen() do
        clear_table()
        :ok = DeviceRegistry.register(token, platform)
        :ok = DeviceRegistry.unregister(token)
        assert DeviceRegistry.device_count() == 0
        assert DeviceRegistry.list_devices() == []
      end
    end

    property "re-register with new prefs overwrites the prior entry" do
      check all token <- token_gen(),
                platform <- platform_gen() do
        clear_table()
        :ok = DeviceRegistry.register(token, platform, muted: true)
        :ok = DeviceRegistry.register(token, platform, muted: false)

        assert [{^token, ^platform, %{muted: false}}] = DeviceRegistry.list_devices()
        assert DeviceRegistry.device_count() == 1
      end
    end
  end

  describe "invariants over batches" do
    property "device_count always equals length of list_devices" do
      check all tokens_and_platforms <-
                  list_of(tuple({token_gen(), platform_gen()}), max_length: 20) do
        clear_table()

        # de-duplicate tokens so each register adds a row, not overwrites
        unique = Enum.uniq_by(tokens_and_platforms, fn {tok, _} -> tok end)
        Enum.each(unique, fn {tok, plat} -> DeviceRegistry.register(tok, plat) end)

        assert DeviceRegistry.device_count() == length(unique)
        assert length(DeviceRegistry.list_devices()) == length(unique)
      end
    end

    property "list_devices(platform) is exactly the subset of list_devices() for that platform" do
      check all entries <-
                  list_of(tuple({token_gen(), platform_gen()}), max_length: 15) do
        clear_table()

        unique = Enum.uniq_by(entries, fn {tok, _} -> tok end)
        Enum.each(unique, fn {tok, plat} -> DeviceRegistry.register(tok, plat) end)

        all_devices = DeviceRegistry.list_devices()

        for platform <- [:apns, :fcm] do
          subset = DeviceRegistry.list_devices(platform)

          # Every device in the subset has the requested platform
          assert Enum.all?(subset, fn {_t, p, _prefs} -> p == platform end)

          # Subset size matches what's in the full list
          expected_count =
            all_devices
            |> Enum.count(fn {_t, p, _prefs} -> p == platform end)

          assert length(subset) == expected_count
        end
      end
    end

    property "unregistering an unknown token never affects existing entries" do
      check all known <- token_gen(),
                unknown <- token_gen(),
                known != unknown do
        clear_table()
        :ok = DeviceRegistry.register(known, :apns)
        before = DeviceRegistry.list_devices()
        :ok = DeviceRegistry.unregister(unknown)
        assert DeviceRegistry.list_devices() == before
      end
    end
  end
end
