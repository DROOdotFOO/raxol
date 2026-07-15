defmodule Raxol.Test.CapabilityFixtures do
  @moduledoc """
  Loader for `test/fixtures/capability/capture/*.json` (schema
  `raxol.capability.capture/1`, shared contract with T0 -- 04 design §2).

  `reply_hex` is the WHOLE raw read exactly as the tty delivered it,
  lowercase hex; the loader decodes `*_hex` fields to binaries. One
  table-driven test iterates `all/0`; dropping a new T0 capture into the
  directory adds a regression test with zero code.
  """

  @dir Path.expand("../fixtures/capability/capture", __DIR__)

  @atom_fields ~w(tier unicode grapheme_width multiplexer)

  @doc "Fixture directory."
  def dir, do: @dir

  @doc "All fixture paths, sorted."
  def all do
    @dir |> Path.join("*.json") |> Path.wildcard() |> Enum.sort()
  end

  @doc """
  Loads one fixture by path or bare name. Decodes `query_hex`,
  `reply_hex`, and `expected_leak_hex` into `"query"`, `"reply"`, and
  `"expected_leak"` binaries.
  """
  def load!(path_or_name) do
    path =
      if String.contains?(path_or_name, "/") do
        path_or_name
      else
        Path.join(@dir, ensure_ext(path_or_name))
      end

    fixture = path |> File.read!() |> Jason.decode!()

    fixture
    |> decode_hex_field("query_hex", "query")
    |> decode_hex_field("reply_hex", "reply")
    |> decode_hex_field("expected_leak_hex", "expected_leak")
  end

  @doc """
  Environment seed for the probe: the fixture `env` map with unset (null)
  vars dropped, mirroring a real process environment.
  """
  def env(fixture) do
    fixture
    |> Map.fetch!("env")
    |> Enum.reject(fn {_k, v} -> is_nil(v) end)
    |> Map.new()
  end

  @doc """
  The fixture's `expected` golden as `{atom_field, expected_value}` pairs
  directly comparable against a `%Raxol.Terminal.Capabilities{}` record.
  """
  def expected_assertions(fixture) do
    fixture
    |> Map.fetch!("expected")
    |> Enum.map(fn {key, value} ->
      {String.to_atom(key), convert_expected(key, value)}
    end)
  end

  @doc "The fixture's expected ladder mode, as an atom."
  def expected_tier(fixture) do
    fixture |> Map.fetch!("expected_tier") |> String.to_atom()
  end

  defp convert_expected("identity", nil), do: nil
  defp convert_expected("identity", [name, version]), do: {name, version}

  defp convert_expected(field, value)
       when field in @atom_fields and is_binary(value),
       do: String.to_atom(value)

  defp convert_expected(_field, value), do: value

  defp decode_hex_field(fixture, hex_key, bin_key) do
    case Map.fetch(fixture, hex_key) do
      {:ok, hex} when is_binary(hex) ->
        Map.put(fixture, bin_key, Base.decode16!(hex, case: :lower))

      _ ->
        fixture
    end
  end

  defp ensure_ext(name) do
    if String.ends_with?(name, ".json"), do: name, else: name <> ".json"
  end
end
