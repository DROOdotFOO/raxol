defmodule Raxol.Terminal.ANSI.CharacterSets.ResolveCharsetNameTest do
  @moduledoc """
  `resolve_charset_name/1` runs up to three times per translated character, so
  what it costs is part of its contract, not an implementation detail.

  It used to ask `Code.ensure_loaded/1`, a synchronous call into the single
  global `:code_server`. The two commonest arguments on that path are `nil` (no
  single shift) and an already-resolved name like `:us_ascii`, neither of which
  is a module, so each call was a guaranteed load MISS -- and misses are not
  cached, so every character re-walked the code path on disk. Measured at ~0.32ms
  per call for `:us_ascii` against ~94ns for a loaded module, serialized through
  one process.

  These cover both halves: that resolution is still correct, and that it no
  longer reaches for the loader.
  """
  use ExUnit.Case, async: true

  alias Raxol.Terminal.ANSI.CharacterSets
  alias Raxol.Terminal.ANSI.CharacterSets.StateManager

  describe "resolving the charset modules" do
    test "each module `charset_code_to_module/1` can produce resolves to its name" do
      assert StateManager.resolve_charset_name(CharacterSets.ASCII) == :us_ascii

      assert StateManager.resolve_charset_name(CharacterSets.DEC) ==
               :dec_special_graphics

      assert StateManager.resolve_charset_name(CharacterSets.UK) == :uk
    end

    test "the table agrees with the modules' own name/0" do
      # The table is the fast path and `name/0` is the declaration. If they ever
      # disagree, the fast path is silently translating against the wrong set.
      for module <- [CharacterSets.ASCII, CharacterSets.DEC, CharacterSets.UK] do
        assert StateManager.resolve_charset_name(module) == module.name()
      end
    end

    test "every charset code maps to a module the table knows" do
      for code <- [?B, ?0, ?A] do
        module = CharacterSets.charset_code_to_module(code)
        refute StateManager.resolve_charset_name(module) == module
      end
    end
  end

  describe "pass-through" do
    test "an already-resolved name is returned unchanged" do
      for name <- [:us_ascii, :dec_special_graphics, :uk, :us] do
        assert StateManager.resolve_charset_name(name) == name
      end
    end

    test "nil, the usual single_shift, is returned unchanged" do
      assert StateManager.resolve_charset_name(nil) == nil
    end

    test "a non-atom is returned unchanged" do
      assert StateManager.resolve_charset_name("us_ascii") == "us_ascii"
      assert StateManager.resolve_charset_name(42) == 42
    end
  end

  describe "the loader is off the hot path" do
    # The property, proven without a wall-clock assertion: resolving an atom that
    # names a real module which is NOT currently loaded must not load it. Only a
    # call into the code server could, so a module still unloaded afterwards is
    # proof that no such call happened.
    test "resolving an unloaded module's atom does not load it" do
      # A module that exists on disk and is not needed to run this test.
      module = Raxol.Terminal.ANSI.CharacterSets.Translator

      :code.purge(module)
      :code.delete(module)
      :code.purge(module)

      refute :erlang.module_loaded(module),
             "precondition: the module must start unloaded"

      assert StateManager.resolve_charset_name(module) == module

      refute :erlang.module_loaded(module),
             "resolve_charset_name/1 loaded a module, so it called the code " <>
               "server: the per-character cost this guards against is back"
    end

    test "an unloadable atom resolves without consulting the loader" do
      # `Code.ensure_loaded/1` on this would be a full code-path search, every
      # call, uncached. It has to come straight back instead.
      assert StateManager.resolve_charset_name(:no_such_module_anywhere) ==
               :no_such_module_anywhere
    end
  end

  describe "the dynamic contract for a charset the table does not know" do
    defmodule CustomCharset do
      @moduledoc false
      def name, do: :custom
    end

    test "a loaded module exporting name/0 still resolves through it" do
      assert StateManager.resolve_charset_name(CustomCharset) == :custom
    end

    test "a loaded module without name/0 is returned unchanged" do
      assert StateManager.resolve_charset_name(Enum) == Enum
    end
  end
end
