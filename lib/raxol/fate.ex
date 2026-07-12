defmodule Raxol.FATE do
  @moduledoc """
  FATE-style golden render harness (after FFmpeg's Fast Audio Video Evaluation).

  Renders a corpus of deterministic fixtures through the pure
  `Raxol.UI.Renderer.render_to_cells/1` path, canonically serializes the
  resulting cell grid, and hashes it (SHA-256). Reference hashes are committed
  under `priv/fate/golden.refs`; `verify/0` compares the current render against
  them.

  The render path uses no NIF, wall clock, or randomness, so a fixture hashes
  identically across architectures; an x86_64/aarch64 divergence is a determinism bug.

  Run via `mix raxol.fate` (compare) or `mix raxol.fate --gen` (regenerate
  references). The golden test in `test/fate/golden_test.exs` runs the same
  corpus inside the normal suite, so CI exercises it on every arch it builds on.
  """

  alias Raxol.UI.Renderer

  @refs_rel "fate/golden.refs"

  @doc "Render every fixture, returning `[{name, hash}]` sorted by name."
  @spec run() :: [{String.t(), String.t()}]
  def run do
    ensure_preferences()

    fixtures()
    |> Enum.map(fn {name, element} -> {name, hash(element)} end)
    |> Enum.sort()
  end

  @doc """
  Compare the current render against the committed references.

  Returns `{:ok, results}` when everything matches, or
  `{:error, %{mismatches: [...], missing: [...]}}`.
  """
  @spec verify() :: {:ok, [{String.t(), String.t()}]} | {:error, map()}
  def verify do
    refs = load_refs()
    results = run()

    mismatches =
      for {name, hash} <- results,
          Map.has_key?(refs, name),
          Map.fetch!(refs, name) != hash do
        %{name: name, expected: Map.fetch!(refs, name), actual: hash}
      end

    missing = for {name, _} <- results, not Map.has_key?(refs, name), do: name

    if mismatches == [] and missing == [] do
      {:ok, results}
    else
      {:error, %{mismatches: mismatches, missing: missing}}
    end
  end

  @doc "Regenerate `priv/fate/golden.refs` from the current render (dev only)."
  @spec generate() :: :ok
  def generate do
    body = Enum.map_join(run(), "\n", fn {name, hash} -> "#{name}  #{hash}" end)
    path = Path.join(["priv", @refs_rel])
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, body <> "\n")
    :ok
  end

  @doc "The parsed reference map (`name => hash`)."
  @spec load_refs() :: %{optional(String.t()) => String.t()}
  def load_refs do
    case read_refs_file() do
      {:ok, contents} ->
        contents
        |> String.split(~r/\r?\n/, trim: true)
        |> Map.new(fn line ->
          [name, hash] =
            line |> String.trim() |> String.split(~r/\s+/, parts: 2)

          {name, hash}
        end)

      :error ->
        %{}
    end
  end

  # --- rendering + hashing -------------------------------------------------

  defp hash(element) do
    element
    |> Renderer.render_to_cells()
    |> serialize()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  # Row-major serialization; sort makes the hash independent of emission order.
  defp serialize(cells) do
    cells
    |> Enum.sort_by(fn {x, y, _c, _fg, _bg, _a} -> {y, x} end)
    |> Enum.map_join("\n", fn {x, y, char, fg, bg, attrs} ->
      "#{y},#{x} #{inspect(char)} #{token(fg)} #{token(bg)} #{inspect(Enum.sort(List.wrap(attrs)))}"
    end)
  end

  defp token(:default), do: "default"
  defp token(atom) when is_atom(atom), do: Atom.to_string(atom)
  defp token(other), do: inspect(other)

  # --- fixtures ------------------------------------------------------------
  # Positioned element maps for render_to_cells/1; each covers a render
  # property: text, style, CJK/wide width, borders, z-order.

  defp fixtures do
    [
      {"text_ascii", text(0, 0, "Hello, Raxol")},
      {"text_styled", text(0, 0, "styled", %{foreground: :cyan, bold: true})},
      {"text_cjk", text(0, 0, "日本語abc")},
      {"text_wide_symbols", text(0, 0, "★✓⚡ end")},
      {"box_1x1", box(0, 0, 1, 1)},
      {"box_border", box(0, 0, 6, 3, %{border: :single})},
      {"overlap_zorder", [box(0, 0, 5, 5), box(2, 2, 5, 5)]}
    ]
  end

  defp text(x, y, str, style \\ %{}) do
    base(:text, x, y) |> Map.merge(%{text: str, style: style})
  end

  defp box(x, y, w, h, style \\ %{}) do
    base(:box, x, y) |> Map.merge(%{width: w, height: h, style: style})
  end

  defp base(type, x, y) do
    %{
      type: type,
      x: x,
      y: y,
      position: {x, y},
      style: %{},
      attrs: [],
      focused: false,
      disabled: false,
      id: "#{type}_#{x}_#{y}"
    }
  end

  # --- refs I/O ------------------------------------------------------------

  defp read_refs_file do
    with path when is_binary(path) <- runtime_refs_path(),
         {:ok, contents} <- File.read(path) do
      {:ok, contents}
    else
      _ ->
        case File.read(Path.join(["priv", @refs_rel])) do
          {:ok, contents} -> {:ok, contents}
          _ -> :error
        end
    end
  end

  defp runtime_refs_path do
    case :code.priv_dir(:raxol) do
      dir when is_list(dir) -> Path.join(to_string(dir), @refs_rel)
      _ -> nil
    end
  end

  defp ensure_preferences do
    case Raxol.Core.UserPreferences.start_link(test_mode?: true) do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
      _ -> :ok
    end
  end
end
