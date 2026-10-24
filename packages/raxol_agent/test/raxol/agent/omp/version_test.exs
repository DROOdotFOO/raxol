defmodule Raxol.Agent.OMP.VersionTest do
  use ExUnit.Case, async: true

  alias Raxol.Agent.OMP.Version

  # Every case is built relative to the pin, so bumping it keeps the tests honest.
  setup do
    %{major: major, minor: minor, patch: patch} = Elixir.Version.parse!(Version.tested())
    %{major: major, minor: minor, patch: patch}
  end

  describe "parse/1" do
    test "accepts `omp --version` output, trailing newline included", %{
      major: major,
      minor: minor,
      patch: patch
    } do
      assert {:ok, %Elixir.Version{major: ^major, minor: ^minor, patch: ^patch}} =
               Version.parse("omp/#{Version.tested()}\n")
    end

    test "accepts the bare gateway ready `version`" do
      assert {:ok, parsed} = Version.parse(Version.tested())
      assert to_string(parsed) == Version.tested()
    end

    test "unknown or garbage input is an error tuple" do
      for input <- [
            "",
            "omp/",
            "omp/18",
            "omp/18.12",
            "omp 18.12.6",
            "v18.12.6",
            "omp/x.y.z",
            "garbage"
          ] do
        assert Version.parse(input) == {:error, :unparseable_version}, inspect(input)
      end

      for input <- [nil, 18, %{"version" => "18.12.6"}, ["omp/18.12.6"]] do
        assert Version.parse(input) == {:error, :unparseable_version}, inspect(input)
      end
    end
  end

  describe "check/1" do
    test "the tested pin is ok with no warning" do
      assert {:ok, _, []} = Version.check("omp/#{Version.tested()}")
      assert {:ok, _, []} = Version.check(Version.tested())
    end

    test "any patch, prerelease or build of the pinned minor is ok", %{
      major: major,
      minor: minor
    } do
      assert {:ok, _, []} = Version.check("omp/#{major}.#{minor}.0")
      assert {:ok, _, []} = Version.check("omp/#{major}.#{minor}.999")
      assert {:ok, _, []} = Version.check("#{Version.tested()}-rc.1")
      assert {:ok, _, []} = Version.check("omp/#{Version.tested()}+build.7")
    end

    @tag skip: Elixir.Version.parse!(Version.tested()).minor == 0 && "the pin has no lower minor"
    test "a lower minor is ok with an older_minor warning", %{major: major, minor: minor} do
      tested = Version.tested()
      lower = "#{major}.#{minor - 1}.99"
      lowest = "#{major}.0.0"

      assert {:ok, %Elixir.Version{minor: found_minor}, [{:older_minor, ^lower, ^tested}]} =
               Version.check("omp/#{lower}")

      assert found_minor == minor - 1
      assert {:ok, _, [{:older_minor, ^lowest, ^tested}]} = Version.check(lowest)
    end

    test "a higher minor is ok with a newer_minor warning", %{major: major, minor: minor} do
      found = "#{major}.#{minor + 1}.0"

      assert {:ok, %Elixir.Version{minor: higher}, [{:newer_minor, ^found, tested}]} =
               Version.check("omp/#{found}")

      assert higher == minor + 1
      assert tested == Version.tested()
    end

    test "a different major is refused, above or below", %{major: major} do
      tested = Version.tested()
      above = "#{major + 1}.0.0"
      below = "#{major - 1}.99.0"

      assert Version.check("omp/#{above}") == {:error, {:unsupported_major, above, tested}}
      assert Version.check(below) == {:error, {:unsupported_major, below, tested}}
    end

    test "unparseable input is refused before any comparison" do
      assert Version.check("omp/latest") == {:error, :unparseable_version}
      assert Version.check(nil) == {:error, :unparseable_version}
    end
  end
end
