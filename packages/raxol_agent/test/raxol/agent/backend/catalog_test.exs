defmodule Raxol.Agent.Backend.CatalogTest do
  use ExUnit.Case, async: false

  alias Raxol.Agent.Backend.Catalog
  alias Raxol.Agent.Backend.Resolver
  alias Raxol.Agent.Backend.Selector
  alias Raxol.Agent.ExecutorConfig

  # Every env var these assertions must not inherit from the developer's shell.
  @managed_env ~w(
    ANTHROPIC_API_KEY ANTHROPIC_MODEL OPENAI_API_KEY OPENAI_MODEL
    KIMI_API_KEY MOONSHOT_API_KEY KIMI_MODEL OPENROUTER_API_KEY OPENROUTER_MODEL
    LONGCAT_API_KEY LONGCAT_MODEL PROTON_ACCESS_TOKEN OLLAMA_MODEL GROK_MODEL
    AI_API_KEY AI_BASE_URL AI_MODEL RAXOL_ALLOW_PAID_API
    RAXOL_ANTHROPIC_OP RAXOL_OPENAI_OP RAXOL_KIMI_OP RAXOL_OPENROUTER_OP
    RAXOL_LONGCAT_OP RAXOL_LUMO_OP RAXOL_OLLAMA_OP RAXOL_LM_STUDIO_OP
    RAXOL_LLM7_OP RAXOL_MOCK_OP RAXOL_CURSOR_OP
  )

  setup do
    saved = Map.new(@managed_env, fn key -> {key, System.get_env(key)} end)
    Enum.each(@managed_env, &System.delete_env/1)

    # Whether a vendor CLI is installed is a property of this host, not of the
    # registry under test, so the probe seam answers instead of PATH.
    prev_probe = Application.fetch_env(:raxol_agent, :native_probe)
    Application.put_env(:raxol_agent, :native_probe, fn _mod -> false end)

    store =
      Path.join(
        System.tmp_dir!(),
        "raxol-catalog-#{System.unique_integer([:positive])}.json"
      )

    prev_store = System.get_env("RAXOL_PROVIDERS")
    System.put_env("RAXOL_PROVIDERS", store)

    on_exit(fn ->
      File.rm(store)

      case prev_probe do
        {:ok, value} -> Application.put_env(:raxol_agent, :native_probe, value)
        :error -> Application.delete_env(:raxol_agent, :native_probe)
      end

      if prev_store,
        do: System.put_env("RAXOL_PROVIDERS", prev_store),
        else: System.delete_env("RAXOL_PROVIDERS")

      Enum.each(saved, fn
        {key, nil} -> System.delete_env(key)
        {key, val} -> System.put_env(key, val)
      end)
    end)

    :ok
  end

  # ADR-0034 Validation, "Gap 4: five registries disagree about which backends
  # exist".
  #
  # The first and third assertions here FAIL on pre-change code: `:grok_native`
  # was selectable and resolvable while missing from `ExecutorConfig.backend()`,
  # so Dialyzer could not see it. The other two hold before and after -- they
  # pin the derivations that make the first two impossible to break again, which
  # is the point of the catalog. The "cursor" block below also fails on
  # pre-change code.
  describe "registry convention" do
    test "every selectable backend is a legal ExecutorConfig.backend() value" do
      legal = MapSet.new(backend_type_atoms())

      for backend <- Selector.supported_backends() do
        assert MapSet.member?(legal, backend),
               "#{backend} resolves to a backend module but is not in " <>
                 "ExecutorConfig.backend(), so Dialyzer cannot see it"
      end
    end

    test "every resolver provider id is declared in the catalog" do
      ids = MapSet.new(Catalog.ids())

      for %{harness: harness} <- Resolver.providers() do
        assert MapSet.member?(ids, harness),
               "#{harness} is a resolvable provider that no catalog entry declares"
      end
    end

    test "the backend type is exactly the catalog's ids" do
      assert MapSet.equal?(
               MapSet.new(Catalog.ids()),
               MapSet.new(backend_type_atoms())
             )
    end

    test "the selector table is the catalog's runnable kinds" do
      runnable =
        Catalog.by_kind([:http, :native, :mock]) |> Enum.map(& &1.id) |> MapSet.new()

      assert MapSet.equal?(runnable, MapSet.new(Selector.supported_backends()))
      refute :codex in Selector.supported_backends()

      assert {:error, {:backend_not_implemented, :codex}} =
               Selector.select(ExecutorConfig.new(backend: :codex))
    end
  end

  describe "cursor" do
    # The user-visible defect Gap 4 closes: `cursor` was selectable in code and
    # unreachable from `/login`, `--backend` string resolution and
    # `.raxol/config.json`, because `@by_string` derives from the resolver
    # registry the hand-written list had never gained it in.
    test "resolves from its string name" do
      assert {:ok, :cursor} = Resolver.harness_from_string("cursor")
    end

    test "named as a string, it resolves to its native backend module" do
      assert {:ok, config, :explicit} = Resolver.resolve(harness: "cursor")
      assert config.backend == :cursor

      assert {:ok, Raxol.Agent.Backend.Cursor, _opts} = Selector.select(config)
    end

    test "is still never auto-selected, even with its CLI installed" do
      Application.put_env(:raxol_agent, :native_probe, fn
        Raxol.Agent.Backend.Cursor -> true
        _other -> false
      end)

      assert :no_provider = Resolver.resolve()
    end
  end

  describe "auto-detection never spends" do
    test "a fully configured :api_credits backend is refused by default" do
      System.put_env("ANTHROPIC_API_KEY", "sk-ant-catalog-test")

      assert :no_provider = Resolver.resolve()
    end

    test "the same backend is selected once RAXOL_ALLOW_PAID_API is set" do
      System.put_env("ANTHROPIC_API_KEY", "sk-ant-catalog-test")
      System.put_env("RAXOL_ALLOW_PAID_API", "1")

      assert {:ok, %{backend: :anthropic}, :env} = Resolver.resolve()
    end
  end

  # The union is built by unquoting an AST fold over `Catalog.ids/0`, so read it
  # back out of the compiled type rather than trusting the fold.
  defp backend_type_atoms do
    {:ok, types} = Code.Typespec.fetch_types(ExecutorConfig)

    {:type, {:backend, _form, []} = spec} =
      Enum.find(types, fn {kind, {name, _form, _args}} ->
        kind == :type and name == :backend
      end)

    {:"::", _meta, [_lhs, union]} = Code.Typespec.type_to_quoted(spec)
    flatten_union(union)
  end

  defp flatten_union({:|, _meta, [left, right]}),
    do: flatten_union(left) ++ flatten_union(right)

  defp flatten_union(atom) when is_atom(atom), do: [atom]
end
