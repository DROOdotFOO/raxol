defmodule Raxol.Agent.SnapshotTest do
  @moduledoc """
  Contract tests for the model-snapshot codec.

  The load-bearing properties: a model holding a PID + a secret dumps to a
  JSON-safe term that restores to an EQUAL persistent slice; non-persistable
  fields are excluded via a loud manifest, never silently mangled; secrets never
  reach the snapshot data.
  """

  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Raxol.Agent.Snapshot

  # --- Fixtures --------------------------------------------------------------

  defmodule PidSecretModel do
    @moduledoc false
    # `api_key` is in BOTH persist and redact to prove redaction wins.
    # `socket` is a declared field that holds a PID — declared-but-non-
    # serializable must still be dropped loudly, not persisted.
    @derive {Raxol.Agent.Snapshot.Persist,
             persist: [:count, :label, :api_key, :socket], redact: [:api_key]}
    defstruct [:count, :label, :api_key, :socket]
  end

  defmodule InnerDeclared do
    @moduledoc false
    @derive {Raxol.Agent.Snapshot.Persist, persist: [:x]}
    defstruct [:x, :y]
  end

  defmodule InnerUndeclared do
    @moduledoc false
    defstruct [:z]
  end

  defmodule OuterModel do
    @moduledoc false
    @derive {Raxol.Agent.Snapshot.Persist, persist: [:inner, :bad]}
    defstruct [:inner, :bad]
  end

  defmodule ForcePersistModel do
    @moduledoc false
    # `client_secret_version` trips the name-heuristic segment `secret` despite
    # being explicitly persist:-listed. The heuristic wins unconditionally
    # (Finding 4, resolved by quorum): a field this shape is redacted, not
    # persisted, and the mismatch is surfaced via Logger.warning + telemetry
    # rather than silently dropping to nil.
    @derive {Raxol.Agent.Snapshot.Persist, persist: [:client_secret_version]}
    defstruct [:client_secret_version]
  end

  # --- PID + secret + plain data ---------------------------------------------

  describe "dump/1 with PID + secret + plain data" do
    setup do
      model = %PidSecretModel{
        count: 7,
        label: "hello",
        api_key: "sk-super-secret-value",
        socket: self()
      }

      {:ok, envelope} = Snapshot.dump(model)
      %{model: model, envelope: envelope}
    end

    test "envelope is JSON round-trippable", %{envelope: envelope} do
      json = Jason.encode!(envelope)
      decoded = Jason.decode!(json)

      # Round-trips to an equivalent string-keyed envelope.
      assert decoded["v"] == 1
      assert decoded["module"] == "Elixir.Raxol.Agent.SnapshotTest.PidSecretModel"
    end

    test "the secret never reaches the snapshot (data or JSON)", %{
      envelope: envelope
    } do
      refute encoded_contains?(envelope.data, "sk-super-secret-value")
      json = Jason.encode!(envelope)
      refute String.contains?(json, "sk-super-secret-value")
    end

    test "the PID field is listed in dropped, not persisted", %{
      envelope: envelope
    } do
      assert %{"path" => ["socket"], "reason" => "pid"} in envelope.dropped
    end

    test "the secret field is listed in redacted", %{envelope: envelope} do
      assert %{"path" => ["api_key"]} in envelope.redacted
    end

    test "plain data survives into the encoding", %{envelope: envelope} do
      assert %{"$s" => _mod, "f" => %{"count" => 7, "label" => "hello"}} =
               envelope.data
    end

    test "load restores the persistent slice with dropped fields at defaults", %{
      envelope: envelope
    } do
      assert {:ok, restored} = Snapshot.load(envelope)

      assert restored == %PidSecretModel{
               count: 7,
               label: "hello",
               api_key: nil,
               socket: nil
             }
    end

    test "load survives a JSON round-trip (string-keyed envelope)", %{
      envelope: envelope
    } do
      round = envelope |> Jason.encode!() |> Jason.decode!()
      assert {:ok, restored} = Snapshot.load(round)
      assert restored.count == 7
      assert restored.label == "hello"
      assert restored.api_key == nil
      assert restored.socket == nil
    end
  end

  # --- Struct-in-struct ------------------------------------------------------

  describe "nested structs" do
    setup do
      model = %OuterModel{
        inner: %InnerDeclared{x: 1, y: 2},
        bad: %InnerUndeclared{z: 3}
      }

      {:ok, envelope} = Snapshot.dump(model)
      %{model: model, envelope: envelope}
    end

    test "a declared inner struct recurses", %{envelope: envelope} do
      assert {:ok, restored} = Snapshot.load(envelope)
      assert %InnerDeclared{x: 1} = restored.inner
    end

    test "the declared inner struct's undeclared field is dropped loudly", %{
      envelope: envelope
    } do
      assert %{"path" => ["inner", "y"], "reason" => "undeclared_field"} in envelope.dropped
      assert {:ok, restored} = Snapshot.load(envelope)
      assert restored.inner.y == nil
    end

    test "an undeclared inner struct is dropped-with-manifest, loudly", %{
      envelope: envelope
    } do
      assert Enum.any?(envelope.dropped, fn
               %{"path" => ["bad"], "reason" => reason} ->
                 String.contains?(reason, "undeclared_struct")

               _ ->
                 false
             end)

      assert {:ok, restored} = Snapshot.load(envelope)
      assert restored.bad == nil
    end
  end

  # --- Bare-map model (the protocol's Any fallback) --------------------------

  describe "bare-map model (no declaration)" do
    test "auto-scans: plain data persists, pid dropped, secret redacted" do
      model = %{count: 5, note: "hi", conn: self(), api_key: "leak"}

      {:ok, envelope} = Snapshot.dump(model)

      assert envelope.module == nil
      assert %{"path" => ["conn"], "reason" => "pid"} in envelope.dropped
      assert %{"path" => ["api_key"]} in envelope.redacted
      refute encoded_contains?(envelope.data, "leak")

      assert {:ok, restored} = Snapshot.load(envelope)
      assert restored == %{count: 5, note: "hi"}
    end
  end

  # --- Versioned envelope ----------------------------------------------------

  describe "versioned envelope" do
    test "carries the schema version" do
      {:ok, envelope} = Snapshot.dump(%{a: 1})
      assert envelope.v == Snapshot.version()
      assert envelope.v == 1
    end

    test "loading an unknown future version is a typed error, not a crash" do
      {:ok, envelope} = Snapshot.dump(%{a: 1})
      future = %{envelope | v: 999}

      assert {:error, {:unsupported_version, 999}} = Snapshot.load(future)
    end

    test "the future-version error also holds after a JSON round-trip" do
      {:ok, envelope} = Snapshot.dump(%{a: 1})
      future = %{envelope | v: 42} |> Jason.encode!() |> Jason.decode!()

      assert {:error, {:unsupported_version, 42}} = Snapshot.load(future)
    end
  end

  # --- Idempotence -----------------------------------------------------------

  describe "round-trip idempotence" do
    test "double dump->load is stable (struct model)" do
      model = %PidSecretModel{count: 3, label: "x", api_key: "s", socket: self()}

      {:ok, env0} = Snapshot.dump(model)
      {:ok, m1} = Snapshot.load(env0)
      {:ok, env1} = Snapshot.dump(m1)
      {:ok, m2} = Snapshot.load(env1)

      # Model-level idempotence: once the non-persistable fields have collapsed
      # to their defaults, further round-trips are fixed points — including the
      # envelope data (the first dump dropped a live PID; the second sees nil).
      assert m1 == m2
      assert env1.data == Snapshot.dump(m2) |> elem(1) |> Map.fetch!(:data)
    end

    test "double dump->load is stable (bare-map model)" do
      model = %{count: 5, note: "hi", conn: self()}

      {:ok, env0} = Snapshot.dump(model)
      {:ok, m1} = Snapshot.load(env0)
      {:ok, env1} = Snapshot.dump(m1)
      {:ok, m2} = Snapshot.load(env1)

      assert m1 == m2
    end
  end

  # --- Non-persistable top-level ---------------------------------------------

  describe "top-level errors" do
    test "a non-persistable top-level term is a typed error" do
      assert {:error, {:not_persistable, :pid}} = Snapshot.dump(self())
    end
  end

  # --- Redaction name heuristic (whole-segment boundaries) -------------------

  describe "redaction name heuristic" do
    test "secret-shaped field names ARE redacted, values never reach data" do
      model = %{
        api_key: "AAA",
        access_token: "BBB",
        auth_token: "CCC",
        password: "DDD",
        private_key: "EEE",
        access_key: "FFF",
        client_secret: "GGG"
      }

      {:ok, envelope} = Snapshot.dump(model)
      redacted_paths = Enum.map(envelope.redacted, & &1["path"])

      for key <-
            ~w(api_key access_token auth_token password private_key access_key client_secret) do
        assert [key] in redacted_paths, "expected #{key} to be redacted"
      end

      json = Jason.encode!(envelope)

      for value <- ~w(AAA BBB CCC DDD EEE FFF GGG) do
        refute String.contains?(json, value)
      end
    end

    test "token/metric field names are NOT redacted — normal agent state survives" do
      # For an agent runtime these are ordinary model fields, not secrets.
      model = %{
        tokens: 10,
        token_count: 20,
        input_tokens: 30,
        total_tokens: 40,
        tokenizer: "gpt",
        secretary: "alice",
        api_key_id: "kid-123",
        passwords_count: 2
      }

      {:ok, envelope} = Snapshot.dump(model)

      assert envelope.redacted == [], "nothing here should be redacted"
      assert envelope.dropped == []

      assert {:ok, restored} = Snapshot.load(envelope)
      assert restored == model
    end
  end

  # --- Non-UTF-8 binaries (JSON-safety) ---------------------------------------

  describe "non-UTF-8 binary (JSON-safety)" do
    test "a non-UTF-8 binary is base64-tagged ($b64), survives JSON + restore" do
      model = %{buf: <<0xFF, 0xFE, 0x00>>, ok: "utf8"}
      {:ok, envelope} = Snapshot.dump(model)
      assert envelope.dropped == []
      assert envelope.redacted == []
      json = Jason.encode!(envelope)
      assert {:ok, restored} = Snapshot.load(Jason.decode!(json))
      assert restored == %{buf: <<0xFF, 0xFE, 0x00>>, ok: "utf8"}
    end

    test "a valid-UTF-8 binary stays bare (no base64 overhead)" do
      {:ok, envelope} = Snapshot.dump(%{s: "hello"})
      assert %{"$m" => [[_k, "hello"]]} = envelope.data
    end

    test "a non-UTF-8 binary inside a list and a struct field also survive" do
      model = %{list: [<<0xC3, 0x28>>], nested: %{x: <<0xFF>>}}
      {:ok, env} = Snapshot.dump(model)
      assert {:ok, ^model} = Snapshot.load(Jason.decode!(Jason.encode!(env)))
    end

    test "a malformed $b64 tag body is a typed error, not a crash" do
      assert {:error, {:load_failed, {:malformed_tag, "$b64"}}} =
               Snapshot.load(tampered(%{"$b64" => 123}))

      assert {:error, {:load_failed, {:malformed_tag, "$b64"}}} =
               Snapshot.load(tampered(%{"$b64" => "!!!!"}))
    end
  end

  # --- Finding 4 HELD: heuristic still wins over persist:, but loudly --------
  #
  # A second review flagged that letting persist: silently override the name
  # heuristic could write a real secret to cleartext disk (e.g. an accidental
  # `persist: [:api_key]`). Pending a human decision, the heuristic keeps
  # winning unconditionally; the only change is that the mismatch is now loud
  # (Logger.warning + telemetry) instead of a silent restore-to-nil.

  describe "persist: vs. the name heuristic (precedence held, made loud)" do
    test "a field explicitly persist:-listed is STILL redacted by the heuristic" do
      {:ok, env} = Snapshot.dump(%ForcePersistModel{client_secret_version: 3})
      assert %{"path" => ["client_secret_version"]} in env.redacted
      refute match?(%{"$s" => _, "f" => %{"client_secret_version" => 3}}, env.data)

      assert {:ok, r} = Snapshot.load(env)
      assert r.client_secret_version == nil
    end

    test "redacting a persist:-listed field emits a Logger.warning and telemetry" do
      test_pid = self()

      :telemetry.attach(
        "persist-redacted-heuristic-test",
        [:raxol, :agent, :snapshot, :persist_redacted_by_heuristic],
        fn event, measurements, metadata, _config ->
          send(test_pid, {:telemetry_event, event, measurements, metadata})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach("persist-redacted-heuristic-test") end)

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          Snapshot.dump(%ForcePersistModel{client_secret_version: 3})
        end)

      assert log =~ "client_secret_version"
      assert log =~ "persist:"

      assert_received {:telemetry_event,
                       [:raxol, :agent, :snapshot, :persist_redacted_by_heuristic], %{count: 1},
                       %{path: ["client_secret_version"]}}
    end

    # explicit redact still beats explicit persist — already proven by the
    # PidSecretModel `api_key` case above (redacted, restores to nil).
  end

  # --- Finding 3 HELD: redaction word-list unchanged --------------------------
  #
  # Widening the heuristic (creds/privkey/pwd/apisecret/ssn) is deferred
  # pending the Finding 4 precedence decision — without a persist: escape
  # hatch, a wider net has no rescue for a false positive. Confirms current
  # behavior is unchanged (still declines these abbreviated spellings, still
  # declines bare `seed`).

  describe "redaction patterns unchanged (Finding 3 held)" do
    test "abbreviated/alternate secret spellings are NOT yet redacted under :auto" do
      model = %{
        creds: "A",
        privkey: "B",
        pwd: "C",
        apisecret: "D",
        ssn: "E"
      }

      {:ok, env} = Snapshot.dump(model)
      assert env.redacted == []
      assert {:ok, ^model} = Snapshot.load(env)
    end

    test "benign names near the deferred patterns still survive (no over-match)" do
      model = %{
        credit_card: 1,
        random_seed: 2,
        db_seed: 3,
        cwd: "/tmp",
        tokens: 4,
        token_count: 5,
        input_tokens: 6,
        api_key_id: "x",
        passwords_count: 2,
        secretary: "s"
      }

      {:ok, env} = Snapshot.dump(model)
      assert env.redacted == []
      assert {:ok, ^model} = Snapshot.load(env)
    end
  end

  # --- MISS-1: $m inner-pair arity validation ---------------------------------

  describe "load/2 hardening: malformed $m inner pair (MISS-1)" do
    test "a $m inner pair with the wrong arity is a typed error, not a raw MatchError" do
      assert {:error, {:load_failed, {:malformed_tag, "$m"}}} =
               Snapshot.load(tampered(%{"$m" => [["a"]]}))

      assert {:error, {:load_failed, {:malformed_tag, "$m"}}} =
               Snapshot.load(tampered(%{"$m" => [["a", 1, 2]]}))
    end

    test "a well-formed $m still decodes normally" do
      env = tampered(%{"$m" => [["a", 1], ["b", 2]]})
      assert {:ok, %{"a" => 1, "b" => 2}} = Snapshot.load(env)
    end
  end

  # --- Load-path hardening (tampered on-disk envelopes are untrusted) --------

  describe "load/2 hardening against tampered envelopes" do
    test "a $s tag naming a loaded-but-non-Persist module is a typed error" do
      # URI is a loaded struct, but declares no Persist slice — must not be built.
      envelope = tampered(%{"$s" => "Elixir.URI", "f" => %{"scheme" => "http"}})

      assert {:error, {:load_failed, {:unknown_struct_module, "Elixir.URI"}}} =
               Snapshot.load(envelope)
    end

    test "a $s tag naming an unknown module is a typed error, no struct built" do
      envelope = tampered(%{"$s" => "Elixir.Nope.NotReal", "f" => %{}})

      assert {:error, {:load_failed, {:unknown_struct_module, "Elixir.Nope.NotReal"}}} =
               Snapshot.load(envelope)
    end

    test "decode nested past the max depth is a typed error, not a crash" do
      deep =
        Enum.reduce(1..70, %{"$m" => []}, fn _, acc ->
          %{"$m" => [["leaf", acc]]}
        end)

      assert {:error, {:load_failed, :max_depth_exceeded}} =
               Snapshot.load(tampered(deep))
    end

    test "a malformed $a tag body is a typed error, not a passed-through map" do
      assert {:error, {:load_failed, {:malformed_tag, "$a"}}} =
               Snapshot.load(tampered(%{"$a" => 127}))
    end

    test "a malformed $s tag body is a typed error" do
      assert {:error, {:load_failed, {:malformed_tag, "$s"}}} =
               Snapshot.load(tampered(%{"$s" => 123, "f" => %{}}))
    end

    test "a malformed $m tag body is a typed error" do
      assert {:error, {:load_failed, {:malformed_tag, "$m"}}} =
               Snapshot.load(tampered(%{"$m" => "not-a-list"}))
    end

    test "an unknown tag still passes through (forward-compat)" do
      assert {:ok, %{"$x" => 1}} = Snapshot.load(tampered(%{"$x" => 1}))
    end

    test "load/2 with an explicit non-Persist module is a typed error (aligned with $s)" do
      env = tampered(%{"$m" => [[%{"$a" => "scheme"}, "http"]]})

      assert {:error, {:load_failed, {:unknown_struct_module, "Elixir.URI"}}} =
               Snapshot.load(env, URI)
    end
  end

  # --- Property: generated plain-data models round-trip through JSON ----------

  describe "property: plain-data slice equality" do
    property "nested plain-data models survive dump -> JSON -> load" do
      check all(model <- map_gen(plain_data(3))) do
        {:ok, envelope} = Snapshot.dump(model)

        # Pure plain data: nothing dropped, nothing redacted.
        assert envelope.dropped == []
        assert envelope.redacted == []

        # Full JSON round-trip, then restore, then slice-equality (== model,
        # because for pure plain data the slice IS the whole model).
        round = envelope |> Jason.encode!() |> Jason.decode!()
        assert {:ok, restored} = Snapshot.load(round)
        assert restored == model
      end
    end
  end

  # --- Generators ------------------------------------------------------------

  # Keys drawn from a fixed pool: atom keys must already exist (so restore's
  # to_existing_atom succeeds) and no key may match the secret heuristic.
  defp key_gen do
    StreamData.one_of([
      StreamData.member_of([:a, :b, :c, :d]),
      StreamData.member_of(["k1", "k2", "k3"])
    ])
  end

  defp scalar do
    StreamData.one_of([
      StreamData.integer(),
      StreamData.boolean(),
      StreamData.constant(nil),
      StreamData.string(:alphanumeric),
      StreamData.member_of([:alpha, :beta, :gamma, :ok, :error])
    ])
  end

  defp plain_data(0), do: scalar()

  defp plain_data(depth) do
    StreamData.one_of([
      scalar(),
      StreamData.list_of(plain_data(depth - 1), max_length: 4),
      map_gen(plain_data(depth - 1))
    ])
  end

  # Build maps from a key/value list + Map.new: keys dedup naturally, so a small
  # key pool never starves `map_of`'s uniqueness constraint (TooManyDuplicates).
  defp map_gen(value_gen) do
    {key_gen(), value_gen}
    |> StreamData.tuple()
    |> StreamData.list_of(max_length: 5)
    |> StreamData.map(&Map.new/1)
  end

  # --- Helpers ---------------------------------------------------------------

  # A hand-built envelope with an attacker-controlled `data` payload.
  defp tampered(data),
    do: %{v: 1, module: nil, data: data, dropped: [], redacted: []}

  # Deep-scan an encoded term for a raw substring (proves a secret is absent).
  defp encoded_contains?(term, needle) when is_binary(term),
    do: String.contains?(term, needle)

  defp encoded_contains?(term, needle) when is_map(term) do
    Enum.any?(term, fn {k, v} ->
      encoded_contains?(k, needle) or encoded_contains?(v, needle)
    end)
  end

  defp encoded_contains?(term, needle) when is_list(term),
    do: Enum.any?(term, &encoded_contains?(&1, needle))

  defp encoded_contains?(_term, _needle), do: false
end
