defmodule Raxol.System.Updater.ProvenanceTest do
  @moduledoc """
  The Sigstore verifier against real, published bundles
  (`test/fixtures/sigstore/`):

    * `0.2.10/`: `raxol-cli-attestation.sigstore.json` and `SHA256SUMS` from
      the `raxol-cli-v0.2.10` release (`gh release download`). No earlier
      `raxol-cli-v*` release carries an attestation asset.
    * `0.2.8/`: that release's `SHA256SUMS`, plus the SLSA provenance bundle
      npm holds for `@raxol/cli@0.2.8`, which the same release workflow
      signed for `refs/tags/raxol-cli-v0.2.8`
      (`https://registry.npmjs.org/-/npm/v1/attestations/@raxol%2fcli@0.2.8`),
      and the package's `dist.integrity` from `npm view`.

  Each refusal mutates one field of a real bundle (or of its certificate
  identity, or of the pinned trusted root), so every other check still
  passes and the refusal is the one being tested.
  """
  use ExUnit.Case, async: true

  import Bitwise

  alias Raxol.System.Updater.Network
  alias Raxol.System.Updater.Provenance
  alias Raxol.System.Updater.Provenance.{Certificate, Policy, TrustedRoot}

  @fixtures Path.expand("../../../fixtures/sigstore", __DIR__)
  @repo "DROOdotFOO/raxol"
  @workflow ".github/workflows/release-raxol-cli.yml"
  @release_tag "raxol-cli-v0.2.10"
  @asset "raxol_cli_macos"

  defp fixture(path), do: File.read!(Path.join(@fixtures, path))
  defp bundle, do: fixture("0.2.10/raxol-cli-attestation.sigstore.json")

  defp sums(version) do
    {:ok, sums} = Network.parse_checksums(fixture("#{version}/SHA256SUMS"))
    sums
  end

  defp subject(name \\ @asset), do: {name, {"sha256", sums("0.2.10")[name]}}

  defp policy(tag \\ @release_tag),
    do: Policy.for_release(@repo, @workflow, tag)

  defp verify(bundle_json, opts \\ []),
    do: Provenance.verify(bundle_json, subject(), policy(), opts)

  defp mutate(fun), do: bundle() |> Jason.decode!() |> fun.() |> Jason.encode!()

  defp mutate_tlog_entry(fun) do
    mutate(fn bundle ->
      update_in(bundle, ["verificationMaterial", "tlogEntries"], fn [entry] ->
        [fun.(entry)]
      end)
    end)
  end

  # Flips one bit of the byte at `at` in a base64 field.
  defp flip(base64, at) do
    bytes = Base.decode64!(base64)
    <<head::binary-size(^at), byte, tail::binary>> = bytes
    Base.encode64(<<head::binary, bxor(byte, 1), tail::binary>>)
  end

  defp leaf do
    bundle()
    |> Jason.decode!()
    |> get_in(["verificationMaterial", "certificate", "rawBytes"])
    |> Base.decode64!()
    |> Certificate.decode()
    |> then(fn {:ok, leaf} -> leaf end)
  end

  describe "real release bundles" do
    test "every binary in raxol-cli-v0.2.10's SHA256SUMS is covered by the release attestation" do
      for {name, sha} <- sums("0.2.10") do
        assert {:ok, verified} =
                 Provenance.verify(bundle(), {name, {"sha256", sha}}, policy())

        assert verified.identity.san == [
                 "https://github.com/#{@repo}/#{@workflow}@refs/tags/#{@release_tag}"
               ]
      end
    end

    test "the npm provenance for @raxol/cli 0.2.8 verifies for raxol-cli-v0.2.8" do
      "sha512-" <> integrity = String.trim(fixture("0.2.8/npm-cli-integrity"))
      digest = integrity |> Base.decode64!() |> Base.encode16(case: :lower)

      assert {:ok,
              %{
                identity: %{source_repository_ref: "refs/tags/raxol-cli-v0.2.8"}
              }} =
               Provenance.verify(
                 fixture("0.2.8/npm-cli-provenance.sigstore.json"),
                 {"pkg:npm/%40raxol/cli@0.2.8", {"sha512", digest}},
                 policy("raxol-cli-v0.2.8")
               )
    end
  end

  describe "the statement" do
    test "a binary the attestation does not cover is refused" do
      other_release = sums("0.2.8")[@asset]

      assert {:error, {:subject_digest_mismatch, @asset}} =
               Provenance.verify(
                 bundle(),
                 {@asset, {"sha256", other_release}},
                 policy()
               )
    end

    test "an asset the attestation does not name is refused" do
      {_name, digest} = subject()

      assert {:error, {:subject_not_found, "raxol_cli_freebsd"}} =
               Provenance.verify(
                 bundle(),
                 {"raxol_cli_freebsd", digest},
                 policy()
               )
    end
  end

  describe "the DSSE envelope" do
    test "a payload rewritten to cover another binary is refused" do
      forged_digest = sums("0.2.8")[@asset]

      tampered =
        mutate(fn bundle ->
          update_in(bundle, ["dsseEnvelope", "payload"], fn payload ->
            payload
            |> Base.decode64!()
            |> String.replace(sums("0.2.10")[@asset], forged_digest)
            |> Base.encode64()
          end)
        end)

      assert {:error, :dsse_signature_invalid} =
               Provenance.verify(
                 tampered,
                 {@asset, {"sha256", forged_digest}},
                 policy()
               )
    end

    test "a tampered signature is refused" do
      tampered =
        mutate(fn bundle ->
          update_in(bundle, ["dsseEnvelope", "signatures"], fn [signature] ->
            [Map.update!(signature, "sig", &flip(&1, 40))]
          end)
        end)

      assert {:error, :dsse_signature_invalid} = verify(tampered)
    end
  end

  describe "the signer identity" do
    test "another signer workflow is refused" do
      policy =
        Policy.for_release(@repo, ".github/workflows/other.yml", @release_tag)

      assert {:error, {:identity_mismatch, :san, [san]}} =
               Provenance.verify(bundle(), subject(), policy)

      assert san =~ "/release-raxol-cli.yml@"
    end

    test "another tag is refused" do
      assert {:error,
              {:identity_mismatch, :source_repository_ref,
               "refs/tags/raxol-cli-v0.2.10"}} =
               Provenance.verify(
                 bundle(),
                 subject(),
                 policy("raxol-cli-v0.2.11")
               )
    end

    test "another repository is refused" do
      policy = Policy.for_release("someone/raxol", @workflow, @release_tag)

      assert {:error,
              {:identity_mismatch, :source_repository_uri,
               "https://github.com/DROOdotFOO/raxol"}} =
               Provenance.verify(bundle(), subject(), policy)
    end

    test "a certificate from another OIDC issuer is refused" do
      identity = %{
        Certificate.identity(leaf())
        | issuer: "https://accounts.google.com"
      }

      assert {:error,
              {:identity_mismatch, :issuer, "https://accounts.google.com"}} =
               Policy.check(identity, policy())
    end

    test "a build on a self-hosted runner is refused" do
      identity = Certificate.identity(leaf())
      assert :ok = Policy.check(identity, policy())

      assert {:error, {:identity_mismatch, :runner_environment, "self-hosted"}} =
               Policy.check(
                 %{identity | runner_environment: "self-hosted"},
                 policy()
               )
    end
  end

  describe "the transparency log entry" do
    test "a broken inclusion proof is refused" do
      tampered =
        mutate_tlog_entry(fn entry ->
          update_in(entry, ["inclusionProof", "hashes"], fn [first | rest] ->
            [flip(first, 0) | rest]
          end)
        end)

      assert {:error, :inclusion_proof_invalid} = verify(tampered)
    end

    test "a checkpoint the log did not sign is refused" do
      tampered =
        mutate_tlog_entry(fn entry ->
          update_in(
            entry,
            ["inclusionProof", "checkpoint", "envelope"],
            fn note ->
              [signature | rest] = note |> String.split(" ") |> Enum.reverse()
              flipped = signature |> String.trim_trailing("\n") |> flip(20)
              [flipped <> "\n" | rest] |> Enum.reverse() |> Enum.join(" ")
            end
          )
        end)

      assert {:error, :checkpoint_signature_invalid} = verify(tampered)
    end

    test "a tampered signed entry timestamp is refused" do
      tampered =
        mutate_tlog_entry(fn entry ->
          update_in(
            entry,
            ["inclusionPromise", "signedEntryTimestamp"],
            &flip(&1, 40)
          )
        end)

      assert {:error, :signed_entry_timestamp_invalid} = verify(tampered)
    end

    test "an integrated time the log did not sign is refused, even inside the certificate's validity" do
      moved =
        mutate_tlog_entry(
          &Map.put(&1, "integratedTime", to_string(leaf().not_before + 60))
        )

      assert {:error, :signed_entry_timestamp_invalid} = verify(moved)
    end

    test "an integrated time outside the certificate's validity is refused" do
      leaf = leaf()

      for time <- [leaf.not_before - 1, leaf.not_after + 1] do
        moved =
          mutate_tlog_entry(&Map.put(&1, "integratedTime", to_string(time)))

        assert {:error, :integrated_time_outside_certificate_validity} =
                 verify(moved)
      end
    end

    test "an entry for another envelope is refused" do
      other_body =
        fixture("0.2.8/npm-cli-provenance.sigstore.json")
        |> Jason.decode!()
        |> get_in([
          "verificationMaterial",
          "tlogEntries",
          Access.at(0),
          "canonicalizedBody"
        ])

      tampered =
        mutate_tlog_entry(&Map.put(&1, "canonicalizedBody", other_body))

      assert {:error, {:tlog_entry_mismatch, :payload_hash}} = verify(tampered)
    end

    test "a bundle without a tlog entry is refused" do
      stripped =
        mutate(&put_in(&1, ["verificationMaterial", "tlogEntries"], []))

      assert {:error, :missing_tlog_entry} = verify(stripped)
    end
  end

  describe "the pinned trusted root" do
    setup do
      {:ok, root} = TrustedRoot.default()
      %{root: root}
    end

    test "a leaf that does not chain to a pinned Fulcio root is refused", %{
      root: root
    } do
      # The 2021 Fulcio root, trusted for all time: the leaf does not chain to it.
      [retired | _current] = root.certificate_authorities

      root = %{
        root
        | certificate_authorities: [%{retired | valid_for: {0, nil}}]
      }

      assert {:error, {:certificate_chain_invalid, _reason}} =
               verify(bundle(), trusted_root: root)

      assert {:error, {:certificate_chain_invalid, :no_trusted_authority}} =
               verify(bundle(),
                 trusted_root: %{root | certificate_authorities: []}
               )
    end

    test "a leaf without an SCT from a trusted CT log is refused", %{root: root} do
      assert {:error, :sct_not_verified} =
               verify(bundle(), trusted_root: %{root | ctlogs: []})
    end

    test "an entry in a log the root does not trust is refused", %{root: root} do
      assert {:error,
              {:untrusted_transparency_log,
               "wNI9atQGlz+VWfO6LRygH4QUfY/8W4RFwiT5i5WRgB0="}} =
               verify(bundle(), trusted_root: %{root | tlogs: []})
    end
  end

  describe "the bundle" do
    test "an unknown media type is refused" do
      v02 =
        mutate(
          &Map.put(
            &1,
            "mediaType",
            "application/vnd.dev.sigstore.bundle+json;version=0.2"
          )
        )

      assert {:error,
              {:unsupported_bundle_media_type,
               "application/vnd.dev.sigstore.bundle+json;version=0.2"}} =
               verify(v02)
    end

    test "malformed input is an error, never an exception" do
      garbage_cert =
        mutate(
          &put_in(
            &1,
            ["verificationMaterial", "certificate", "rawBytes"],
            Base.encode64("garbage")
          )
        )

      assert {:error, {:malformed_bundle, :certificate}} = verify(garbage_cert)
      assert {:error, {:malformed_bundle, :json}} = verify("not json")

      assert {:error, {:malformed_tlog_entry, "inclusionProof.hashes"}} =
               verify(
                 mutate_tlog_entry(
                   &put_in(&1, ["inclusionProof", "hashes"], "nope")
                 )
               )
    end
  end
end
