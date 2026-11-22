defmodule Raxol.Core.ChildEnvTest do
  use ExUnit.Case, async: false

  @moduletag :unix_only

  alias Raxol.Core.ChildEnv

  setup do
    previous = System.get_env("RAXOL_SLEUTH_API_KEY")
    System.put_env("RAXOL_SLEUTH_API_KEY", "sk-probe-not-real")

    on_exit(fn ->
      if previous,
        do: System.put_env("RAXOL_SLEUTH_API_KEY", previous),
        else: System.delete_env("RAXOL_SLEUTH_API_KEY")
    end)
  end

  defp child(env) do
    port =
      Port.open({:spawn_executable, "/bin/sh"}, [
        :binary,
        :exit_status,
        :in,
        args: [
          "-c",
          ~s(printf '%s|%s|%s' "${RAXOL_SLEUTH_API_KEY-unset}" "$FOO" "${HOME:+home}")
        ],
        env: ChildEnv.port_env(env)
      ])

    collect(port, "")
  end

  defp collect(port, acc) do
    receive do
      {^port, {:data, data}} -> collect(port, acc <> data)
      {^port, {:exit_status, _}} -> acc
    after
      5_000 -> flunk("child did not exit")
    end
  end

  test "a child gets the node's environment and the caller's, minus raxol's secrets" do
    assert child([{"FOO", "bar"}]) == "unset|bar|home"
  end

  test "a secret the caller passes explicitly is kept" do
    assert child([{"RAXOL_SLEUTH_API_KEY", "given"}, {~c"FOO", ~c"bar"}]) ==
             "given|bar|home"
  end

  test "cmd_env/1 scrubs a System.cmd child the same way, nil unsetting" do
    script = ~s(printf '%s|%s|%s' "${RAXOL_SLEUTH_API_KEY-unset}" "$FOO" "${HOME:+home}")

    assert {"unset|bar|home", 0} =
             System.cmd("/bin/sh", ["-c", script], env: ChildEnv.cmd_env([{"FOO", "bar"}]))

    assert {"given||", 0} =
             System.cmd("/bin/sh", ["-c", script],
               env: ChildEnv.cmd_env([{"RAXOL_SLEUTH_API_KEY", "given"}, {"HOME", nil}])
             )
  end

  describe "credential patterns" do
    # Unique names, so the scan of the node's environment is the only thing
    # that can unset them.
    @probes %{
      "RAXOL_TEST_PROBE_API_KEY" => "sk-probe",
      "RAXOL_TEST_PROBE_TOKEN" => "tok-probe",
      "RAXOL_TEST_PROBE_PRIVATE_KEY" => "0xprobe",
      "RAXOL_TEST_PROBE_SECRET" => "sec-probe",
      "RAXOL_TEST_PROBE_RPC_URL" => "https://rpc.example/probe-key",
      "RAXOL_TEST_PROBE_KEY_ID" => "id-probe",
      "RAXOL_TEST_PROBE_PASSPHRASE" => "pp-probe",
      "RAXOL_TEST_PROBE_CREDENTIALS" => "/probe/creds.json",
      "raxol_test_probe_lower_token" => "lower-probe",
      "RAXOL_TEST_PROBE_APIKEY" => "apikey-probe",
      "RAXOL_TEST_PROBE_DATABASE_URL" => "ecto://u:probe@db/x",
      "RAXOL_TEST_PROBE_ETH_RPC" => "https://rpc.example/probe-key",
      "RAXOL_TEST_PROBE_MAINNETRPC" => "https://rpc.example/probe-key",
      "RAXOL_TEST_PROBE_SMTP_PASS" => "pass-probe",
      "RAXOL_TEST_PROBE_SEED_PHRASE" => "abandon probe",
      "RAXOL_TEST_PROBE_SENTRY_DSN" => "https://probe@sentry.example/1",
      "OP_SESSION_RAXOL_TEST_PROBE" => "op-probe",
      "RAXOL_TEST_PROBE_REDIS_TLS_URL" => "rediss://:probe@redis.example:6380",
      "RAXOL_TEST_PROBE_DATABASE_PUBLIC_URL" => "postgres://u:probe@db.example/x",
      "RAXOL_TEST_PROBE_GITHUB_PAT" => "github_pat_probe",
      "RAXOL_TEST_PROBE_MYSQL_PWD" => "pwd-probe",
      "RAXOL_TEST_PROBE_SLACK_WEBHOOK_URL" => "https://hooks.slack.example/services/probe",
      "RAXOL_TEST_PROBE_SSH_ASKPASS" => "kept",
      "RAXOL_TEST_PROBE_PATH_EXTRA" => "kept",
      "RAXOL_TEST_PROBE_PASSAGE" => "kept",
      "RAXOL_TEST_PROBE_MONKEY" => "kept",
      "RAXOL_TEST_PROBE_GRPC_HOST" => "kept",
      "RAXOL_TEST_PROBE_TOKENIZER" => "kept"
    }

    setup do
      Enum.each(@probes, fn {name, value} -> System.put_env(name, value) end)
      on_exit(fn -> Enum.each(Map.keys(@probes), &System.delete_env/1) end)
    end

    defp sees(env_fun, names) do
      script = Enum.map_join(names, "|", &~s(${#{&1}-unset}))
      {out, 0} = System.cmd("/bin/sh", ["-c", ~s(printf '%s' "#{script}")], env: env_fun.())
      String.split(out, "|")
    end

    @scrubbed ~w(RAXOL_TEST_PROBE_API_KEY RAXOL_TEST_PROBE_TOKEN RAXOL_TEST_PROBE_PRIVATE_KEY
                 RAXOL_TEST_PROBE_SECRET RAXOL_TEST_PROBE_RPC_URL RAXOL_TEST_PROBE_KEY_ID
                 RAXOL_TEST_PROBE_PASSPHRASE RAXOL_TEST_PROBE_CREDENTIALS
                 RAXOL_TEST_PROBE_APIKEY RAXOL_TEST_PROBE_DATABASE_URL
                 RAXOL_TEST_PROBE_ETH_RPC RAXOL_TEST_PROBE_MAINNETRPC
                 RAXOL_TEST_PROBE_SMTP_PASS RAXOL_TEST_PROBE_SEED_PHRASE
                 RAXOL_TEST_PROBE_SENTRY_DSN OP_SESSION_RAXOL_TEST_PROBE
                 RAXOL_TEST_PROBE_REDIS_TLS_URL RAXOL_TEST_PROBE_DATABASE_PUBLIC_URL
                 RAXOL_TEST_PROBE_GITHUB_PAT RAXOL_TEST_PROBE_MYSQL_PWD
                 RAXOL_TEST_PROBE_SLACK_WEBHOOK_URL
                 raxol_test_probe_lower_token)
    @kept ~w(RAXOL_TEST_PROBE_MONKEY RAXOL_TEST_PROBE_TOKENIZER RAXOL_TEST_PROBE_GRPC_HOST
             RAXOL_TEST_PROBE_SSH_ASKPASS RAXOL_TEST_PROBE_PASSAGE
             RAXOL_TEST_PROBE_PATH_EXTRA)

    test "a child inherits no variable whose name looks like a credential" do
      assert sees(fn -> ChildEnv.cmd_env() end, @scrubbed ++ @kept) ==
               List.duplicate("unset", length(@scrubbed)) ++ List.duplicate("kept", length(@kept))
    end

    test "port_env/1 unsets the same names as cmd_env/1" do
      unset = for {name, false} <- ChildEnv.port_env(), do: List.to_string(name)
      unset_cmd = for {name, nil} <- ChildEnv.cmd_env(), do: name

      assert Enum.sort(unset) == Enum.sort(unset_cmd)
      assert Enum.all?(@scrubbed, &(&1 in unset))
      refute Enum.any?(@kept, &(&1 in unset))
    end

    test "a credential the caller names explicitly reaches the child" do
      env = fn -> ChildEnv.cmd_env([{"RAXOL_TEST_PROBE_API_KEY", "given"}]) end

      assert sees(env, ["RAXOL_TEST_PROBE_API_KEY", "RAXOL_TEST_PROBE_TOKEN"]) == [
               "given",
               "unset"
             ]
    end

    test "secret?/1 is true for the named set and the pattern, unconfigured" do
      for name <- ~w(RAXOL_SLEUTH_API_KEY XOCHI_AUTH_TOKEN SECRET_KEY_BASE RELEASE_COOKIE
                     ANTHROPIC_API_KEY GH_TOKEN
                     AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY ETH_PRIVKEY BASE_RPC_URL ETH_RPC MAINNETRPC XRPC_URL
                     OPENAI_APIKEY DATABASE_URL REPO_DATABASE_URL PGPASSWORD PGADMIN_PASSWORD
                     SSH_AUTH_SOCK
                     RPC_BASE ORDER_RPC_8453 DB_PASSWORD WALLET_MNEMONIC gh_token
                     OPENAI_API_KEY_2 ANTHROPIC_API_KEY_PROD API_KEYS SIGNER_KEY_PEM TOKEN
                     DATABASE_URL_UNPOOLED POSTGRES_URL REDIS_URL MONGODB_URI MY_PGPASSWORD
                     SECRETS ssh_auth_sock release_cookie
                     SMTP_PASS DB_PASS RAXOL_DB_PASS PASS SMTP_PASS_2 smtp_pass
                     SEED_PHRASE WALLET_SEED_PHRASE seed_phrase SEED_PHRASE_BACKUP
                     SENTRY_DSN DSN DATABASE_DSN_RO sentry_dsn
                     OP_SESSION_my_team OP_SESSION_ABC123 op_session_me
                     BW_SESSION LPASS_SESSION bw_session
                     DB_PASS1 SMTP_PASS2 DB_PASSWORD2 API_KEY2 SEEDPHRASE WALLET_SEEDPHRASE
                     WALLET_SEED MASTER_SEED HD_SEED TOTP_SEED PASS_THROUGH ODBC_DSN
                     REDIS_TLS_URL DATABASE_PUBLIC_URL DATABASE_PRIVATE_URL POSTGRES_PRISMA_URL
                     POSTGRES_URL_NON_POOLING HEROKU_POSTGRESQL_ONYX_URL AMQPS_URL CLOUDAMQP_URL
                     REDISCLOUD_URL REDISTOGO_URL CELERY_BROKER_URL READ_DB_URL DB_URL PG_URL
                     MARIADB_URL MSSQL_URL VALKEY_URL MEMCACHED_URL ELASTICSEARCH_URL
                     OPENSEARCH_URL CLICKHOUSE_URL COUCHDB_URL redis_tls_url
                     GITHUB_PAT GH_PAT PAT AZURE_DEVOPS_PAT GITLAB_PAT_2 github_pat
                     MYSQL_PWD DB_PWD MYSQL_PWD2 mysql_pwd
                     SLACK_WEBHOOK_URL DISCORD_WEBHOOK WEBHOOK_URL TEAMS_WEBHOOKS
                     ALERTWEBHOOK slack_webhook_url
                     ETH_PRIVATEKEY WALLET_MNEMONICS BW_CLIENTSECRET
                     AZURE_STORAGE_CONNECTION_STRING DB_CONNECTION_STRING
                     MONGOHQ_URL MONGOLAB_URI SMTP_URL MAIL_URL EMAIL_URL
                     PK DEPLOYER_PK WALLET_PK ETH_PK2) do
        assert ChildEnv.secret?(name), name
      end

      for name <-
            ~w(HOME PATH PWD OLDPWD KEYBOARD MONKEY TOKENIZER TOKENIZERS_PARALLELISM
                     GRPC_HOST GRPC_VERBOSITY SSH_AUTH_SOCKET PGHOST PGUSER TERM LESSKEY
                     SSH_ASKPASS SUDO_ASKPASS GIT_ASKPASS PASSAGE BYPASS_CACHE COMPASS_HOME
                     SEED RANDOM_SEED SEED_URL PHRASE DSNAME OP_SESSION MY_OP_SESSION_X
                     BW_SESSIONS SESSION PASSAGE_2
                     PATCH_LEVEL PATTERN DISPATCH PWD_HOME XDG_RUNTIME_DIR
                     DATABASE_POOL_SIZE REDIS_HOST DBUS_SESSION_BUS_ADDRESS DB_HOST
                     KAFKA_BROKERS BROKER_HOST DB_HOST_URL PG_ADMIN_UI_URL
                     BROKER_DASHBOARD_URL PK_COLUMN USER_PK_FIELD CONNECTION) do
        refute ChildEnv.secret?(name), name
      end
    end

    test "DATABASE_URL, PGPASSWORD, PG...PASSWORD and SSH_AUTH_SOCK do not reach a child" do
      names = ~w(DATABASE_URL PGPASSWORD PGADMIN_PASSWORD SSH_AUTH_SOCK)
      previous = Map.new(names, &{&1, System.get_env(&1)})
      Enum.each(names, &System.put_env(&1, "probe"))

      on_exit(fn ->
        Enum.each(previous, fn
          {name, nil} -> System.delete_env(name)
          {name, value} -> System.put_env(name, value)
        end)
      end)

      assert sees(fn -> ChildEnv.cmd_env() end, names) == List.duplicate("unset", length(names))

      assert sees(fn -> ChildEnv.cmd_env([{"PGPASSWORD", "given"}]) end, ["PGPASSWORD"]) == [
               "given"
             ]
    end

    test "secret?/1 agrees with what cmd_env/1 unsets, for the probe names" do
      unset = for {name, nil} <- ChildEnv.cmd_env(), into: MapSet.new(), do: name

      # The probes and a few fixed names rather than the whole environment, so
      # the result does not depend on what the developer's shell exports.
      for name <- Map.keys(@probes) ++ ~w(RAXOL_SLEUTH_API_KEY HOME PATH) do
        assert ChildEnv.secret?(name) == MapSet.member?(unset, name), name
      end
    end

    # raxol-agent's `Raxol.Agent.ChildEnv` denies these shapes on top of
    # raxol_core 2.9.0's pattern (its `@gaps`, a snapshot of raxol-agent main
    # after its PR #32). Core's pattern alone must match every name they do,
    # so raxol-agent can drop the list once it requires raxol_core ~> 2.9.1.
    test "the pattern covers raxol-agent's gap list against raxol_core 2.9.0" do
      gaps = ~r/(_PASS|_SEED_PHRASE|_DSN)\z|\ASEED_PHRASE\z|\AOP_SESSION_/i

      bare = ~w(SEED_PHRASE OP_SESSION_ OP_SESSION_me OP_SESSION_A_B)

      suffixed =
        for prefix <- ["A", "X_A", "MY_APP_A", "_", "__", "A1"],
            suffix <- ~w(_PASS _SEED_PHRASE _DSN),
            do: prefix <> suffix

      corpus = Enum.flat_map(bare ++ suffixed, &[&1, String.downcase(&1)])

      for name <- corpus do
        assert Regex.match?(gaps, name), "not a gap-list name: " <> name
        assert Regex.match?(ChildEnv.credential_pattern(), name), name
      end
    end

    test "an over-long name is denied without matching" do
      long = String.duplicate("DB_", 200) <> "X"
      assert byte_size(long) > 256
      assert ChildEnv.secret?(long)
      refute ChildEnv.secret?(String.duplicate("A", 256))
    end

    test "credential_pattern/0 is the case-insensitive pattern" do
      pattern = ChildEnv.credential_pattern()
      assert :caseless in Regex.opts(pattern)
      assert Regex.match?(pattern, "base_rpc_url")
    end
  end

  describe "configuration" do
    setup do
      previous = Application.get_env(:raxol_core, ChildEnv)

      on_exit(fn ->
        if previous,
          do: Application.put_env(:raxol_core, ChildEnv, previous),
          else: Application.delete_env(:raxol_core, ChildEnv)
      end)
    end

    test "a passed name reaches the child, as a nested raxol node needs its key" do
      Application.put_env(:raxol_core, ChildEnv, pass: ["RAXOL_SLEUTH_API_KEY"])
      assert child([{"FOO", "bar"}]) == "sk-probe-not-real|bar|home"
    end

    test "a passed name matching the pattern reaches the child, and pass/0 lists it" do
      System.put_env("RAXOL_TEST_PASSED_TOKEN", "passed")
      System.put_env("RAXOL_TEST_UNPASSED_TOKEN", "unpassed")

      on_exit(fn ->
        System.delete_env("RAXOL_TEST_PASSED_TOKEN")
        System.delete_env("RAXOL_TEST_UNPASSED_TOKEN")
      end)

      Application.put_env(:raxol_core, ChildEnv, pass: ["RAXOL_TEST_PASSED_TOKEN"])

      assert ChildEnv.pass() == ["RAXOL_TEST_PASSED_TOKEN"]
      refute ChildEnv.secret?("RAXOL_TEST_PASSED_TOKEN")
      assert ChildEnv.secret?("RAXOL_TEST_UNPASSED_TOKEN")

      script =
        ~s(printf '%s|%s' "${RAXOL_TEST_PASSED_TOKEN-unset}" "${RAXOL_TEST_UNPASSED_TOKEN-unset}")

      assert {"passed|unset", 0} = System.cmd("/bin/sh", ["-c", script], env: ChildEnv.cmd_env())
    end

    test "a name both in extra_secrets and passed is not denied, as secrets/0 says" do
      Application.put_env(:raxol_core, ChildEnv,
        extra_secrets: ["RAXOL_TEST_WALLET"],
        pass: ["RAXOL_TEST_WALLET", "SECRET_KEY_BASE"]
      )

      refute "RAXOL_TEST_WALLET" in ChildEnv.secrets()
      refute ChildEnv.secret?("RAXOL_TEST_WALLET")
      refute ChildEnv.secret?("SECRET_KEY_BASE")
      assert ChildEnv.secret?("RELEASE_COOKIE")
    end

    test "a malformed name is reported by size, never by contents" do
      Application.put_env(:raxol_core, ChildEnv, pass: ["sk-ant-not-a-real-key"])

      error = assert_raise ArgumentError, fn -> ChildEnv.port_env() end
      assert error.message =~ ":pass"
      refute error.message =~ "sk-ant"
    end

    test "pass/0 is empty unconfigured" do
      Application.delete_env(:raxol_core, ChildEnv)
      assert ChildEnv.pass() == []
    end

    test "an extra secret is unset even when the node sets it after the env is built" do
      Application.put_env(:raxol_core, ChildEnv, extra_secrets: ["RAXOL_TEST_LATE"])
      env = ChildEnv.cmd_env()
      System.put_env("RAXOL_TEST_LATE", "late")
      on_exit(fn -> System.delete_env("RAXOL_TEST_LATE") end)

      assert {"unset", 0} =
               System.cmd("/bin/sh", ["-c", ~s(printf '%s' "${RAXOL_TEST_LATE-unset}")], env: env)
    end

    test "extra secrets are unset too, and a caller's false unsets rather than sets" do
      System.put_env("RAXOL_TEST_EXTRA_SECRET", "x")
      on_exit(fn -> System.delete_env("RAXOL_TEST_EXTRA_SECRET") end)

      Application.put_env(:raxol_core, ChildEnv, extra_secrets: ["RAXOL_TEST_EXTRA_SECRET"])

      assert {~c"RAXOL_TEST_EXTRA_SECRET", false} in ChildEnv.port_env()
      assert {~c"FOO", false} in ChildEnv.port_env([{"FOO", false}])
    end

    test "a malformed config raises naming the config and the key instead of scrubbing less" do
      for {config, key} <- [
            {[pass: [nil]], ":pass"},
            {[extra_secrets: [:MY_WALLET_KEY]], ":extra_secrets"},
            {[pass: "RAXOL_SLEUTH_API_KEY"], ":pass"},
            {[extra_secrets: ["MY KEY"]], ":extra_secrets"},
            {%{pass: ["RAXOL_SLEUTH_API_KEY"]}, nil},
            {[{"pass", ["RAXOL_SLEUTH_API_KEY"]}], nil},
            {[extra_secret: ["RAXOL_SLEUTH_API_KEY"]], ":extra_secret"},
            {[pass: [], pass: ["RAXOL_SLEUTH_API_KEY"]], ":pass"},
            {"RAXOL_SLEUTH_API_KEY", nil}
          ] do
        Application.put_env(:raxol_core, ChildEnv, config)

        for call <- [&ChildEnv.port_env/0, &ChildEnv.cmd_env/0, &ChildEnv.pass/0] do
          error = assert_raise ArgumentError, call
          assert error.message =~ "config :raxol_core, Raxol.Core.ChildEnv"
          if key, do: assert(error.message =~ key)
          # Whatever the operator put there may be a key itself.
          refute error.message =~ "SLEUTH"
          refute error.message =~ "MY KEY"
        end
      end
    end
  end
end
