defmodule Raxol.Agent.Skill do
  @moduledoc """
  A procedural-memory skill: an agentskills.io `SKILL.md` parsed into a struct.

  A skill is YAML frontmatter (the leading `--- ... ---` block) plus a markdown
  body. This module is pure: parse a `SKILL.md` string into a `%Skill{}`, render
  a `%Skill{}` back to `SKILL.md` text, and load one from disk. It owns no
  process and touches no global state.

  Modeled frontmatter keys are `name` (required), `description`, `version`,
  `category`, and `created_by`. Every other frontmatter key is preserved under
  `:metadata`, so a skill authored by another tool keeps its extra fields across
  a round trip. `parse(render(skill))` returns an equal struct for the shapes
  real skills use (scalars, lists of scalars, and a one-level metadata map).

  `created_by` is decoded to `:agent`, `:user`, or `nil`; this is what the
  Curator uses to decide which skills it may age and rewrite. Unknown values
  decode to `nil` rather than calling `String.to_atom/1` on file content.
  """

  @enforce_keys [:name]
  defstruct name: nil,
            description: nil,
            version: nil,
            category: nil,
            created_by: nil,
            metadata: %{},
            body: ""

  @type created_by :: :agent | :user | nil

  @type t :: %__MODULE__{
          name: String.t(),
          description: String.t() | nil,
          version: String.t() | nil,
          category: String.t() | nil,
          created_by: created_by(),
          metadata: %{optional(String.t()) => term()},
          body: String.t()
        }

  @modeled_keys ~w(name description version category created_by)

  # Closing `---` may carry trailing spaces/tabs and an optional single newline;
  # `[ \t]` (not `\s`) so the delimiter never swallows body newlines.
  @frontmatter ~r/\A---[ \t]*\n(?<front>.*?)\n---[ \t]*\n?(?<body>.*)\z/s

  @doc "Parse a `SKILL.md` string into a `%Skill{}`."
  @spec parse(String.t()) :: {:ok, t()} | {:error, term()}
  def parse(content) when is_binary(content) do
    with {:ok, front, body} <- split(content),
         {:ok, map} <- decode_frontmatter(front),
         {:ok, name} <- fetch_name(map) do
      {:ok,
       %__MODULE__{
         name: name,
         description: map["description"],
         version: stringify(map["version"]),
         category: map["category"],
         created_by: decode_created_by(map["created_by"]),
         metadata: Map.drop(map, @modeled_keys),
         body: body
       }}
    end
  end

  @doc "Render a `%Skill{}` back to `SKILL.md` text."
  @spec render(t()) :: String.t()
  def render(%__MODULE__{} = skill) do
    "---\n" <> render_frontmatter(skill) <> "---\n" <> skill.body
  end

  @doc "Load and parse a `SKILL.md` from disk."
  @spec from_file(Path.t()) :: {:ok, t()} | {:error, term()}
  def from_file(path) do
    case File.read(path) do
      {:ok, content} -> parse(content)
      {:error, reason} -> {:error, {:read_failed, reason}}
    end
  end

  # -- parse helpers ----------------------------------------------------------

  defp split(content) do
    case Regex.named_captures(@frontmatter, content) do
      %{"front" => front, "body" => body} -> {:ok, front, body}
      nil -> {:error, :missing_frontmatter}
    end
  end

  defp decode_frontmatter(front) do
    case YamlElixir.read_from_string(front) do
      {:ok, map} when is_map(map) -> {:ok, map}
      {:ok, _other} -> {:error, :frontmatter_not_a_map}
      {:error, reason} -> {:error, {:invalid_yaml, reason}}
    end
  end

  defp fetch_name(%{"name" => name}) when is_binary(name) and name != "",
    do: {:ok, name}

  defp fetch_name(_), do: {:error, :missing_name}

  defp decode_created_by("agent"), do: :agent
  defp decode_created_by("user"), do: :user
  defp decode_created_by(_), do: nil

  defp stringify(nil), do: nil
  defp stringify(v) when is_binary(v), do: v
  defp stringify(v), do: to_string(v)

  # -- render helpers ---------------------------------------------------------

  defp render_frontmatter(skill) do
    modeled =
      [
        {"name", skill.name},
        {"description", skill.description},
        {"version", skill.version},
        {"category", skill.category},
        {"created_by", encode_created_by(skill.created_by)}
      ]
      |> Enum.reject(fn {_k, v} -> is_nil(v) end)

    metadata = Enum.map(skill.metadata, fn {k, v} -> {to_string(k), v} end)

    encode_entries(modeled ++ metadata, 0)
  end

  defp encode_created_by(:agent), do: "agent"
  defp encode_created_by(:user), do: "user"
  defp encode_created_by(nil), do: nil

  # Block-style YAML for the shapes real frontmatter uses: scalars, nested
  # maps, and lists of scalars, recursively indented two spaces per level.
  defp encode_entries(entries, indent) do
    Enum.map_join(entries, "", fn {key, value} ->
      encode_kv(to_string(key), value, indent)
    end)
  end

  defp encode_kv(key, value, indent) when is_map(value) do
    pad(indent) <> key <> ":\n" <> encode_entries(Map.to_list(value), indent + 1)
  end

  defp encode_kv(key, value, indent) when is_list(value) do
    items =
      Enum.map_join(value, "", fn item ->
        pad(indent + 1) <> "- " <> encode_scalar(item) <> "\n"
      end)

    pad(indent) <> key <> ":\n" <> items
  end

  defp encode_kv(key, value, indent) do
    pad(indent) <> key <> ": " <> encode_scalar(value) <> "\n"
  end

  defp pad(indent), do: String.duplicate("  ", indent)

  defp encode_scalar(nil), do: "null"
  defp encode_scalar(true), do: "true"
  defp encode_scalar(false), do: "false"
  defp encode_scalar(v) when is_integer(v), do: Integer.to_string(v)
  defp encode_scalar(v) when is_float(v), do: Float.to_string(v)
  defp encode_scalar(v) when is_binary(v), do: encode_quoted(v)

  defp encode_quoted(string) do
    escaped =
      string
      |> String.replace("\\", "\\\\")
      |> String.replace("\"", "\\\"")
      |> String.replace("\n", "\\n")

    "\"" <> escaped <> "\""
  end
end
