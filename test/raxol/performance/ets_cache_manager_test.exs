defmodule Raxol.Performance.ETSCacheManagerTest do
  # The cache manager is a VM-wide singleton registered under a global name.
  use ExUnit.Case, async: false

  alias Raxol.Performance.{Cache, ETSCacheManager}
  alias Raxol.UI.{StyleProcessor, ThemeResolver}

  # `Raxol.Application` starts it as `{ETSCacheManager, []}` in test mode and
  # with only `hibernate_after:` in full mode: neither passes a name. Use the
  # application's instance, or start one the same way if an earlier test took
  # the application's supervisor down.
  setup do
    if Process.whereis(ETSCacheManager) == nil do
      start_supervised!({ETSCacheManager, []})
    end

    :ok
  end

  describe "the cache manager" do
    test "answers the cache admin API" do
      assert %{style: %{size: size}} = Cache.stats()
      assert is_integer(size)
      assert :ok = Cache.clear_all()
    end

    test "rejects an unknown cache name and keeps running" do
      pid = Process.whereis(ETSCacheManager)

      assert {:error, :unknown_cache} = Cache.clear(:theme_cache)
      assert Process.whereis(ETSCacheManager) == pid
      assert %{style: _} = Cache.stats()
    end
  end

  describe "opt-in style caching" do
    setup do
      previous = Application.fetch_env(:raxol, :style_processor)

      on_exit(fn ->
        case previous do
          {:ok, value} -> Application.put_env(:raxol, :style_processor, value)
          :error -> Application.delete_env(:raxol, :style_processor)
        end
      end)
    end

    test "ThemeResolver.resolve_styles/4 with cache: true stores the result" do
      theme = %{
        name: :ets_cache_manager_test,
        colors: %{},
        component_styles: %{}
      }

      attrs = %{fg: :red, bg: :blue}

      result = ThemeResolver.resolve_styles(attrs, :button, theme, cache: true)

      assert {:ok, ^result} =
               ETSCacheManager.get_style(
                 :ets_cache_manager_test,
                 :button,
                 :erlang.phash2(attrs)
               )
    end

    test "StyleProcessor caches when enabled in config" do
      Application.put_env(:raxol, :style_processor, cache_enabled: true)
      :ok = Cache.clear(:style)

      StyleProcessor.flatten_merged_style(
        %{fg: :green},
        %{type: :text, style: %{bold: true}},
        %{name: :ets_cache_manager_config_test}
      )

      assert Cache.stats().style.size > 0
    end
  end
end
