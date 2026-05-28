# Virtual File System

An in-memory filesystem that's purely functional: immutable struct, O(1) path lookups, zero side effects. Good for sandboxed environments, agent workspaces, and poking around in the REPL.

## Core API

```elixir
alias Raxol.Commands.FileSystem

fs = FileSystem.new()

{:ok, fs} = FileSystem.mkdir(fs, "/docs")
{:ok, fs} = FileSystem.create_file(fs, "/docs/readme.txt", "Hello!")
{:ok, entries} = FileSystem.ls(fs, "/docs")        # => ["readme.txt"]
{:ok, content} = FileSystem.cat(fs, "/docs/readme.txt")  # => "Hello!"

{:ok, fs} = FileSystem.cd(fs, "/docs")
FileSystem.pwd(fs)                                  # => "/docs"
FileSystem.exists?(fs, "readme.txt")                # => true

{:ok, info} = FileSystem.stat(fs, "readme.txt")
# => %{type: :file, size: 6, path: "/docs/readme.txt", ...}

{:ok, fs} = FileSystem.rm(fs, "readme.txt")
{:ok, tree} = FileSystem.tree(fs, "/", 3)
# => {"/", :directory, [{"docs", :directory, []}]}
```

Anything that changes the filesystem returns `{:ok, new_fs}` or `{:error, reason}`. Error reasons are atoms: `:not_found`, `:already_exists`, `:parent_not_found`, `:not_a_directory`, `:is_a_directory`, `:directory_not_empty`, `:cannot_remove_root`.

## REPL Integration

Call `Evaluator.with_vfs/1` to get a `vfs` binding and shell-like helpers auto-imported from `Raxol.REPL.VfsHelpers`:

```elixir
alias Raxol.REPL.Evaluator

eval = Evaluator.new() |> Evaluator.with_vfs()

{:ok, _, eval} = Evaluator.eval(eval, "vfs = mkdir(vfs, \"/src\")")
{:ok, _, eval} = Evaluator.eval(eval, "vfs = touch(vfs, \"/src/app.ex\", \"defmodule App do\\nend\")")
{:ok, _, eval} = Evaluator.eval(eval, "vfs = ls(vfs)")
{:ok, _, eval} = Evaluator.eval(eval, "vfs = cat(vfs, \"/src/app.ex\")")
{:ok, _, eval} = Evaluator.eval(eval, "tree(vfs)")
```

Helpers print their output via IO (captured by the evaluator) and return the VFS struct so you can chain them.

| Helper | What it does | Mutates VFS? |
|--------|--------|:---:|
| `ls(vfs)` / `ls(vfs, path)` | Print directory listing | No |
| `cd(vfs, path)` | Change working directory | Yes |
| `pwd(vfs)` | Print current directory | No |
| `cat(vfs, path)` | Print file contents | No |
| `mkdir(vfs, path)` | Create directory | Yes |
| `touch(vfs, path)` / `touch(vfs, path, content)` | Create file | Yes |
| `rm(vfs, path)` | Remove file or empty dir | Yes |
| `tree(vfs)` / `tree(vfs, path, depth)` | Print directory tree | No |
| `stat(vfs, path)` | Print node metadata | No |

Under the hood, the `Evaluator.prelude` field runs an import of VfsHelpers before every eval. That's why bare function names like `ls` and `mkdir` just work without any aliasing.

## Agent Actions

The VFS is also wired up as `Raxol.Agent.Action` modules, so LLMs can call them as tools:

```elixir
alias Raxol.Agent.Actions.Vfs
alias Raxol.Agent.Action.ToolConverter

# Generate LLM tool definitions
tools = ToolConverter.to_tool_definitions(Vfs.actions())

# Dispatch an LLM tool call
context = %{vfs: model.vfs}
tool_call = %{"name" => "vfs_write_file", "arguments" => %{"path" => "/app.ex", "content" => "..."}}
{:ok, result} = ToolConverter.dispatch_tool_call(tool_call, Vfs.actions(), context)
new_vfs = result.vfs  # mutating actions return the updated VFS
```

| Action | Tool Name | Returns VFS? |
|--------|-----------|:---:|
| `Vfs.ListDir` | `vfs_list_dir` | No |
| `Vfs.ReadFile` | `vfs_read_file` | No |
| `Vfs.WriteFile` | `vfs_write_file` | Yes |
| `Vfs.MakeDir` | `vfs_make_dir` | Yes |
| `Vfs.Remove` | `vfs_remove` | Yes |
| `Vfs.ChangeDir` | `vfs_change_dir` | Yes |
| `Vfs.GetTree` | `vfs_get_tree` | No |

VFS resolution checks `params[:vfs]` first (so Pipeline composition works), then `context[:vfs]`, and falls back to a fresh filesystem if neither exists.

### Pipeline Composition

```elixir
alias Raxol.Agent.Action.Pipeline

{:ok, state, commands} = Pipeline.run(
  [
    {Vfs.MakeDir, %{path: "/src"}},
    {Vfs.WriteFile, %{path: "/src/app.ex", content: "defmodule App do\nend"}}
  ],
  %{},
  %{vfs: FileSystem.new()}
)
```

The updated VFS flows through the pipeline on its own: each action's result gets merged into the next action's params.

## Internals

Internally it's a flat map keyed by absolute path (`%{"/" => node, "/docs" => node, ...}`). Parent-child relationships are tracked both ways (parents keep a `children` list). Path resolution handles `.`, `..`, absolute paths, relative paths, and `-` for the previous directory. Timestamps come from `System.monotonic_time(:millisecond)`.

There are also formatting helpers: `format_ls/3` for styled directory listings and `format_cat/3` for line-numbered file output.

## Playground Demo

`mix raxol.playground` has a VFS demo with a shell-like interface: `ls`, `cd`, `cat`, `pwd`, `mkdir`, `rm`, `tree`, and `help` all work.
