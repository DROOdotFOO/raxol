defmodule Raxol.Agent.SystemPromptTest do
  # async: false -- exercises the RAXOL_BONDED_PROMPT env var, app env, and
  # the shared persistent_term cache.
  use ExUnit.Case, async: false

  alias Raxol.Agent.SystemPrompt

  @fixture """
  <!--
  ENTITY: core system prompt (Layer 0), byte-stable. Fill the {{slots}}.
  -->

  You are {{NAME}}, bonded to a single operator, whom you address as
  "{{OPERATOR_ROLE}}". Move the current {{DOMAIN}} toward verified
  completion. Reassure operationally: "{{SIGNATURE}}".
  """

  setup do
    SystemPrompt.clear_cache()

    on_exit(fn ->
      System.delete_env("RAXOL_BONDED_PROMPT")
      Application.delete_env(:raxol_agent, :bonded_prompt_path)
      SystemPrompt.clear_cache()
    end)

    :ok
  end

  defp write_fixture!(dir, content \\ @fixture) do
    path = Path.join(dir, "core.prompt.md")
    File.write!(path, content)
    path
  end

  describe "resolve/2 :none and {:text, _}" do
    test ":none resolves to :none, identity says so" do
      assert {:ok, :none} = SystemPrompt.resolve(:none)
      assert SystemPrompt.identity_line(:none) == "none"
    end

    test "{:text, _} passes through verbatim with a verifiable identity" do
      assert {:ok, resolved} = SystemPrompt.resolve({:text, "abc"})

      assert resolved.text == "abc"
      assert resolved.name == "inline"
      assert resolved.bytes == 3

      assert resolved.sha256 ==
               :sha256 |> :crypto.hash("abc") |> Base.encode16(case: :lower)

      assert SystemPrompt.identity_line(resolved) ==
               "inline · 3 bytes · sha256:" <> String.slice(resolved.sha256, 0, 12)
    end
  end

  describe "resolve/2 {:file, path}" do
    @tag :tmp_dir
    test "reads the file verbatim -- no assembly on plain files", %{tmp_dir: dir} do
      path = Path.join(dir, "my_prompt.md")
      File.write!(path, "Plain prompt with {{NAME}} untouched.")

      assert {:ok, resolved} = SystemPrompt.resolve({:file, path})
      assert resolved.text == "Plain prompt with {{NAME}} untouched."
      assert resolved.name == "file:my_prompt.md"
    end

    test "a missing file is a loud error, not an empty prompt" do
      assert {:error, {:enoent, _}} =
               SystemPrompt.resolve({:file, "/nonexistent/prompt.md"})
    end
  end

  describe "resolve/2 :bonded" do
    @tag :tmp_dir
    test "strips the comment header and fills the reference slots", %{tmp_dir: dir} do
      System.put_env("RAXOL_BONDED_PROMPT", write_fixture!(dir))

      assert {:ok, resolved} = SystemPrompt.resolve(:bonded)

      refute resolved.text =~ "ENTITY:"
      refute resolved.text =~ "{{"
      assert resolved.text =~ "You are AX-7"
      assert resolved.text =~ ~s("Operator")
      assert resolved.text =~ "current build"
      assert resolved.text =~ "I have accounted for that"
      assert resolved.name == "bonded:core.prompt.md@AX-7"
      assert resolved.source == :bonded
    end

    @tag :tmp_dir
    test ":slots overrides merge over the reference fill", %{tmp_dir: dir} do
      System.put_env("RAXOL_BONDED_PROMPT", write_fixture!(dir))

      assert {:ok, resolved} =
               SystemPrompt.resolve(:bonded, slots: %{name: "RX-1"})

      assert resolved.text =~ "You are RX-1"
      assert resolved.text =~ ~s("Operator")
      assert resolved.name == "bonded:core.prompt.md@RX-1"
    end

    @tag :tmp_dir
    test "an unfilled slot is an error, never silently shipped", %{tmp_dir: dir} do
      System.put_env(
        "RAXOL_BONDED_PROMPT",
        write_fixture!(dir, "You are {{NAME}} with {{UNKNOWN_SLOT}}.")
      )

      assert {:error, {:unfilled_slots, ["UNKNOWN_SLOT"]}} =
               SystemPrompt.resolve(:bonded)
    end

    test "an explicitly configured location that is missing is an error (no fallback)" do
      System.put_env("RAXOL_BONDED_PROMPT", "/nonexistent/core.prompt.md")

      assert {:error, {:configured_missing, "/nonexistent/core.prompt.md"}} =
               SystemPrompt.resolve(:bonded)

      assert SystemPrompt.bonded_available?() == false
    end

    @tag :tmp_dir
    test "app env :bonded_prompt_path arm works", %{tmp_dir: dir} do
      Application.put_env(:raxol_agent, :bonded_prompt_path, write_fixture!(dir))

      assert {:ok, resolved} = SystemPrompt.resolve(:bonded)
      assert resolved.text =~ "You are AX-7"
      assert SystemPrompt.bonded_available?()
    end

    @tag :tmp_dir
    test "caches at first resolve -- no file read per turn", %{tmp_dir: dir} do
      path = write_fixture!(dir)
      System.put_env("RAXOL_BONDED_PROMPT", path)

      assert {:ok, first} = SystemPrompt.resolve(:bonded)

      # The file is gone; only the cache can answer now.
      File.rm!(path)
      assert {:ok, ^first} = SystemPrompt.resolve(:bonded)

      # With the cache cleared the truth (missing file) surfaces again.
      SystemPrompt.clear_cache()
      assert {:error, _} = SystemPrompt.resolve(:bonded)
    end
  end

  describe "resolve/2 invalid sources" do
    test "an unknown source spec is a loud error" do
      assert {:error, {:unknown_source, :nonsense}} = SystemPrompt.resolve(:nonsense)
    end
  end
end
