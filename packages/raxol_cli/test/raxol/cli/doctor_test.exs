defmodule Raxol.CLI.DoctorTest do
  # Not async: the providers block reads `$RAXOL_PROVIDERS`, `$PATH` and the
  # provider environment variables, which are process-global.
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO
  import ExUnit.CaptureLog

  alias Raxol.Agent.Backend.Catalog
  alias Raxol.CLI
  alias Raxol.CLI.Doctor

  describe "the acp surface row" do
    test "says available where an agent can be started" do
      assert Doctor.acp_surface({:unix, :linux}) == "available (raxol acp --agent <app>)"
    end

    test "does not say available on Windows, where every session/new is refused" do
      row = Doctor.acp_surface({:win32, :nt})

      refute row =~ "available ("
      assert row =~ "NOT available"
      assert row =~ "not available on Windows"
    end
  end

  describe "the providers block" do
    test "lists a provider that resolves, with where its credential came from" do
      block =
        Doctor.providers(%{
          op: :ok,
          providers: [
            provider(:anthropic, "Anthropic (Claude)", true, :env),
            provider(:openrouter, "OpenRouter", true, :op),
            provider(:ollama, "Ollama (local)", true, :configured),
            provider(:openai, "OpenAI", false, nil)
          ]
        })

      assert block ==
               """
               providers (op CLI: ok)
                 anthropic   Anthropic (Claude), via environment variable
                 openrouter  OpenRouter, via 1Password reference
                 ollama      Ollama (local), via stored entry
               """
               |> String.trim_trailing()
    end

    test "lists a stored reference that cannot be read, with the reason" do
      note = "op reference stored, run `op signin`"

      block =
        Doctor.providers(%{
          op: :not_signed_in,
          providers: [provider(:openrouter, "OpenRouter", false, nil, note)]
        })

      assert block ==
               "providers (op CLI: not signed in)\n" <>
                 "  openrouter  OpenRouter, not usable: #{note}"
    end

    test "says so when nothing is connected" do
      block =
        Doctor.providers(%{
          op: :absent,
          providers: [provider(:openai, "OpenAI", false, nil)]
        })

      assert block == "providers (op CLI: absent)\n  none connected"
    end
  end

  describe "raxol doctor against a temporary provider store" do
    setup :isolate_provider_environment

    test "exits 0 with no store, and keeps the header and next block" do
      out = capture_io(fn -> assert CLI.main(["doctor"]) == 0 end)

      assert out =~ "packaging"
      assert out =~ "acp surface available"
      assert out =~ "providers (op CLI: absent)\n  none connected"
      assert out =~ "next:"
      assert out =~ "raxol acp --agent"
      assert out =~ "raxol new counter"
    end

    test "says packaged binary under Burrito" do
      System.put_env("__BURRITO", "1")

      out = capture_io(fn -> assert Doctor.run([]) == 0 end)

      assert out =~ "packaged binary"
    end

    test "shows a stored keyless provider", %{store: store} do
      write_store!(store, %{"ollama" => %{"base_url" => "http://localhost:11434"}})

      out = capture_io(fn -> assert Doctor.run([]) == 0 end)

      assert out =~ "  ollama      Ollama (local), via stored entry"
      refute out =~ "none connected"
    end

    test "shows a stored reference it cannot read, and never the reference", %{
      store: store
    } do
      write_store!(store, %{
        "openrouter" => %{"op_ref" => "op://Private/abc123/credential"}
      })

      out = capture_io(fn -> assert Doctor.run([]) == 0 end)

      assert out =~ "  openrouter  OpenRouter, not usable: op reference stored"
      refute out =~ "op://"
      refute out =~ "abc123"
    end

    test "a store that is not JSON is no providers, not a crash", %{store: store} do
      File.write!(store, "{not json")

      out = capture_io(fn -> assert Doctor.run([]) == 0 end)

      assert out =~ "none connected"
    end

    test "a store others may write is refused, logged, and not a crash", %{
      store: store
    } do
      write_store!(store, %{"ollama" => %{"base_url" => "http://localhost:11434"}})
      File.chmod!(store, 0o666)

      {out, log} =
        with_log(fn ->
          capture_io(fn -> assert Doctor.run([]) == 0 end)
        end)

      assert out =~ "none connected"
      assert log =~ "provider credential store: refusing #{store}"
    end
  end

  defp provider(harness, label, available?, source, note \\ nil) do
    %{
      harness: harness,
      label: label,
      keyless?: false,
      available?: available?,
      source: source,
      note: note
    }
  end

  defp write_store!(store, entries) do
    File.write!(store, Jason.encode!(entries))
    File.chmod!(store, 0o600)
  end

  # Point the resolver at an empty store in a private directory, hide any `op`
  # CLI, and clear every variable a provider could resolve from, so the block
  # reflects only what a test writes.
  defp isolate_provider_environment(_context) do
    dir = private_tmp_dir!()
    store = Path.join(dir, "providers.json")
    saved = Map.new(managed_variables(), &{&1, System.get_env(&1)})

    Enum.each(Map.keys(saved), &System.delete_env/1)
    System.put_env("RAXOL_PROVIDERS", store)
    System.put_env("PATH", path_without_op(saved["PATH"] || ""))

    on_exit(fn ->
      restore_environment(saved)
      File.rm_rf!(dir)
    end)

    %{store: store}
  end

  defp private_tmp_dir! do
    dir =
      Path.join(
        System.tmp_dir!(),
        "raxol-doctor-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(dir)
    File.chmod!(dir, 0o700)
    dir
  end

  defp managed_variables do
    provider_variables =
      Enum.flat_map(Catalog.entries(), fn entry ->
        ["RAXOL_#{entry.id |> to_string() |> String.upcase()}_OP" | entry.env_keys]
      end)

    ["RAXOL_PROVIDERS", "PATH", "__BURRITO", "AI_API_KEY" | provider_variables]
  end

  defp restore_environment(saved) do
    Enum.each(saved, fn
      {name, nil} -> System.delete_env(name)
      {name, value} -> System.put_env(name, value)
    end)
  end

  defp path_without_op(path) do
    path
    |> String.split(":")
    |> Enum.reject(&File.exists?(Path.join(&1, "op")))
    |> Enum.join(":")
  end
end
