defmodule Raxol.FormatterDelegationTest do
  @moduledoc """
  The root formatter must resolve format-gated package files through the
  package's own `.formatter.exs`.

  Without that, a root-cwd `mix format packages/...` -- an editor save in a
  monorepo workspace -- rewraps those files at the root's 80 columns, reverting
  the 98-column shape the per-package CI cell enforces, and the two gates become
  mutually unsatisfiable.
  """

  use ExUnit.Case, async: true

  # 94 columns: legal at the package default of 98, split by the root's 80.
  @wide_line "{:ok, ExKeccak.hash_256(<<0x19, 0x01, domain_separator::binary, message_hash::binary>>)}\n"

  @gated_file "packages/raxol_payments/lib/raxol/payments/eip712.ex"
  @workflow ".github/workflows/ci-unified.yml"

  test "a gated package file keeps its own line length under the root formatter" do
    {format, _opts} = Mix.Tasks.Format.formatter_for_file(@gated_file)

    assert format.(@wide_line) == @wide_line
  end

  test "the root formatter still holds root files to 80 columns" do
    {format, _opts} = Mix.Tasks.Format.formatter_for_file("lib/raxol.ex")

    refute format.(@wide_line) == @wide_line
  end

  test "every format-gated package is delegated by the root formatter" do
    delegated = Keyword.fetch!(root_formatter_opts(), :subdirectories)

    for package <- gated_packages() do
      assert "packages/#{package}" in delegated,
             "#{package} is format-gated in #{@workflow} but the root " <>
               ".formatter.exs does not delegate to it"
    end
  end

  defp root_formatter_opts do
    {opts, _bindings} = Code.eval_file(".formatter.exs")
    opts
  end

  defp gated_packages do
    matrix =
      @workflow
      |> File.read!()
      |> String.split("\n")
      |> Enum.find(&Regex.match?(~r/^\s*package: \[/, &1))

    assert is_binary(matrix), "no package matrix found in #{@workflow}"

    ~r/^\s*package: \[(?<packages>[^\]]+)\]/
    |> Regex.named_captures(matrix)
    |> Map.fetch!("packages")
    |> String.split(",")
    |> Enum.map(&String.trim/1)
  end
end
