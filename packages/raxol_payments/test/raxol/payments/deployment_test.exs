defmodule Raxol.Payments.DeploymentTest do
  # async: false -- mutates process-global env (Application env + OS env).
  use ExUnit.Case, async: false

  alias Raxol.Payments.Deployment

  setup do
    on_exit(fn ->
      Application.delete_env(:raxol_payments, :deployment)
      Application.delete_env(:raxol_payments, :repl_exposed)
      Application.delete_env(:raxol_payments, :allow_insecure_distribution)
      System.delete_env("RAXOL_PAYMENTS_DEPLOYMENT")
      System.delete_env("RELEASE_NAME")
      System.delete_env("RAXOL_REPL_EXPOSED")
      System.delete_env("RAXOL_ALLOW_INSECURE_DISTRIBUTION")
    end)

    :ok
  end

  test "defaults to non-production in dev/test (no RELEASE_NAME)" do
    System.delete_env("RELEASE_NAME")
    refute Deployment.production?()
  end

  test "detects a deployed release via RELEASE_NAME" do
    System.put_env("RELEASE_NAME", "raxol")
    assert Deployment.production?()
  end

  test "config override wins over release detection" do
    System.put_env("RELEASE_NAME", "raxol")
    Application.put_env(:raxol_payments, :deployment, :development)
    refute Deployment.production?()

    Application.delete_env(:raxol_payments, :deployment)
    Application.put_env(:raxol_payments, :deployment, :production)
    assert Deployment.production?()
  end

  test "env var override forces production without a release" do
    System.put_env("RAXOL_PAYMENTS_DEPLOYMENT", "production")
    assert Deployment.production?()
  end

  describe "assert_distribution_secure!/0" do
    test "insecure_distribution?/3 truth table" do
      # Only production + non-TLS + not-allowed is insecure.
      assert Deployment.insecure_distribution?(true, false, false)
      refute Deployment.insecure_distribution?(false, false, false)
      refute Deployment.insecure_distribution?(true, true, false)
      refute Deployment.insecure_distribution?(true, false, true)
    end

    test "passes when distribution is disabled (test node is not alive)" do
      Application.put_env(:raxol_payments, :deployment, :production)
      refute Node.alive?()
      assert :ok = Deployment.assert_distribution_secure!()
    end

    test "distribution_tls? is true for a non-distributed node" do
      assert Deployment.distribution_tls?()
    end
  end

  describe "assert_signing_isolated!/0" do
    test "raises in production when the REPL is exposed on a signing node" do
      Application.put_env(:raxol_payments, :deployment, :production)
      System.put_env("RAXOL_REPL_EXPOSED", "true")

      assert_raise ArgumentError, ~r/exposes the interactive REPL/, fn ->
        Deployment.assert_signing_isolated!()
      end
    end

    test "passes in production when the REPL is not exposed" do
      Application.put_env(:raxol_payments, :deployment, :production)
      assert :ok = Deployment.assert_signing_isolated!()
    end

    test "passes in development even when the REPL is exposed" do
      Application.put_env(:raxol_payments, :deployment, :development)
      System.put_env("RAXOL_REPL_EXPOSED", "true")
      assert :ok = Deployment.assert_signing_isolated!()
    end
  end
end
