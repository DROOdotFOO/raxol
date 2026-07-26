defmodule Raxol.Symphony.Runners.Codex.AuthTest do
  # async: false -- resolve/1 reads process-global env vars, which these tests set.
  use ExUnit.Case, async: false

  alias Raxol.Symphony.Runners.Codex.Auth

  @env_vars ["OPENAI_API_KEY", "CODEX_HOME", "CUSTOM_KEY"]

  setup do
    saved = Map.new(@env_vars, fn var -> {var, System.get_env(var)} end)
    Enum.each(@env_vars, &System.delete_env/1)

    on_exit(fn ->
      Enum.each(saved, fn
        {var, nil} -> System.delete_env(var)
        {var, value} -> System.put_env(var, value)
      end)
    end)

    tmp = Path.join(System.tmp_dir!(), "codex_auth_#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)
    on_exit(fn -> File.rm_rf(tmp) end)

    %{tmp: tmp}
  end

  defp codex(auth), do: %{auth: auth}
  defp write_auth_json(dir), do: File.write!(Path.join(dir, "auth.json"), "{}")

  describe "resolve/1 :inherit" do
    test "no ambient credential -> not authenticated, empty env", %{tmp: tmp} do
      System.put_env("CODEX_HOME", tmp)

      resolved = Auth.resolve(codex(%{mode: :inherit}))

      assert resolved.mode == :inherit
      assert resolved.source == :inherit
      assert resolved.env == []
      refute resolved.authenticated?
    end

    test "auth.json under CODEX_HOME -> authenticated", %{tmp: tmp} do
      write_auth_json(tmp)
      System.put_env("CODEX_HOME", tmp)

      assert Auth.resolve(codex(%{mode: :inherit})).authenticated?
    end

    test "OPENAI_API_KEY set -> authenticated without auth.json", %{tmp: tmp} do
      System.put_env("CODEX_HOME", tmp)
      System.put_env("OPENAI_API_KEY", "sk-ambient")

      assert Auth.resolve(codex(%{mode: :inherit})).authenticated?
    end
  end

  describe "resolve/1 :api_key" do
    test "injects OPENAI_API_KEY from the named var" do
      System.put_env("CUSTOM_KEY", "sk-secret")

      resolved = Auth.resolve(codex(%{mode: :api_key, api_key_env: "CUSTOM_KEY"}))

      assert resolved.source == :api_key
      assert resolved.authenticated?
      assert resolved.env == [{~c"OPENAI_API_KEY", ~c"sk-secret"}]
    end

    test "defaults the source var to OPENAI_API_KEY" do
      System.put_env("OPENAI_API_KEY", "sk-default")

      resolved = Auth.resolve(codex(%{mode: :api_key}))

      assert resolved.env == [{~c"OPENAI_API_KEY", ~c"sk-default"}]
    end

    test "unset var -> not authenticated, empty env" do
      resolved = Auth.resolve(codex(%{mode: :api_key, api_key_env: "CUSTOM_KEY"}))

      refute resolved.authenticated?
      assert resolved.env == []
    end
  end

  describe "resolve/1 :codex_home" do
    test "injects CODEX_HOME; authenticated iff auth.json present", %{tmp: tmp} do
      resolved = Auth.resolve(codex(%{mode: :codex_home, codex_home: tmp}))

      assert resolved.source == :codex_home
      assert resolved.env == [{~c"CODEX_HOME", String.to_charlist(tmp)}]
      refute resolved.authenticated?

      write_auth_json(tmp)
      assert Auth.resolve(codex(%{mode: :codex_home, codex_home: tmp})).authenticated?
    end
  end

  describe "gate/2" do
    test "require_login + unauthenticated -> :codex_unauthenticated" do
      resolved = %{mode: :api_key, source: :api_key, authenticated?: false, env: []}

      assert {:error, :codex_unauthenticated} =
               Auth.gate(codex(%{mode: :api_key, require_login: true}), resolved)
    end

    test "require_login + authenticated -> :ok" do
      resolved = %{mode: :api_key, source: :api_key, authenticated?: true, env: []}
      assert :ok = Auth.gate(codex(%{mode: :api_key, require_login: true}), resolved)
    end

    test "require_login false -> :ok even when unauthenticated" do
      resolved = %{mode: :inherit, source: :inherit, authenticated?: false, env: []}
      assert :ok = Auth.gate(codex(%{mode: :inherit, require_login: false}), resolved)
    end
  end

  describe "emit/1" do
    test "publishes mode/authenticated?/source, no secret" do
      handler = {__MODULE__, :auth_telemetry}
      test = self()

      :telemetry.attach(
        handler,
        [:raxol, :symphony, :codex, :auth],
        fn _event, meas, meta, _config -> send(test, {:auth_tel, meas, meta}) end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler) end)

      resolved = %{
        mode: :api_key,
        source: :api_key,
        authenticated?: true,
        env: [{~c"OPENAI_API_KEY", ~c"sk-secret"}]
      }

      assert :ok = Auth.emit(resolved)
      assert_receive {:auth_tel, %{count: 1}, meta}
      assert meta == %{mode: :api_key, authenticated?: true, source: :api_key}
      refute inspect(meta) =~ "sk-secret"
    end
  end
end
