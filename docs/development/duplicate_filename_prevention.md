# Duplicate Filename Prevention

Tooling to detect and prevent duplicate filenames across `lib/` and `test/`.

Multiple files named `manager.ex` or `handler.ex` break IDE navigation, produce ambiguous search results, and make code review confusing.

### Example Problematic Pattern

```bash
# Before - Confusing duplicate names
lib/raxol/terminal/buffer/manager.ex      # Which manager?
lib/raxol/terminal/cursor/manager.ex      # Which manager? 
lib/raxol/core/config/manager.ex          # Which manager?
lib/raxol/core/events/manager.ex          # Which manager?

# After - Clear, contextual names  
lib/raxol/terminal/buffer/buffer_manager.ex    # Clear: buffer management
lib/raxol/terminal/cursor/cursor_manager.ex    # Clear: cursor management
lib/raxol/core/config/config_manager.ex        # Clear: config management
lib/raxol/core/events/event_manager.ex         # Clear: event management
```

## Tools Provided

### 1. Standalone Script
**Location:** `scripts/quality/check_duplicate_filenames.exs`

```bash
# Basic check
mix run scripts/quality/check_duplicate_filenames.exs

# With rename suggestions  
mix run scripts/quality/check_duplicate_filenames.exs --fix-suggestions
```

**Features:**
- Scans `lib/` and `test/` directories
- Categorizes duplicates by severity (🔴 CRITICAL, 🟡 WARNING, 🔵 INFO)
- Provides contextual rename suggestions
- Exit codes for CI/CD integration

### 2. Mix Task (planned)

A `mix raxol.check.duplicates` task is planned but not yet built. The intended interface is:

```bash
mix raxol.check.duplicates                  # basic
mix raxol.check.duplicates --suggest-fixes  # show suggested renames
mix raxol.check.duplicates --strict         # fail build on duplicates
mix raxol.check.duplicates --exclude "mix.exs,README.md"
```

**Features:**
- Integrated with Mix task system
- Configurable exclusions
- Multiple output modes
- Better error handling

### 3. Credo Integration
**Location:** `lib/raxol/credo/duplicate_filename_check.ex`

```bash
# Run as part of Credo checks
mix credo

# Run only duplicate filename check
mix credo --only Raxol.Credo.DuplicateFilenameCheck
```

**Features:**
- Integrated into existing linting workflow
- Configurable severity levels
- Part of standard code quality checks
- IDE integration through Credo

## Configuration

### Credo Configuration
In `.credo.exs`:

```elixir
{Raxol.Credo.DuplicateFilenameCheck, [
  exclude_files: ["mix.exs", "README.md", ".gitignore"],
  max_duplicates: 1,
  include_tests: true
]}
```

### Options
- **`exclude_files`** - Files to ignore (default: `["mix.exs", "README.md", ".gitignore"]`)
- **`max_duplicates`** - Maximum allowed duplicates before flagging (default: `1`)
- **`include_tests`** - Whether to check test files (default: `true`)

## Problematic Patterns

The system flags these commonly duplicated filenames:

### Critical Patterns (🔴)
Files that almost always cause navigation issues:
- `manager.ex`
- `handler.ex` 
- `server.ex`
- `supervisor.ex`
- `renderer.ex`
- `processor.ex`
- `validator.ex`
- `buffer.ex`
- `parser.ex`
- `state.ex`
- `types.ex`
- `config.ex`
- `client.ex`
- `worker.ex`

### Warning Patterns (🟡)
Files with 4+ duplicates regardless of name.

### Info Patterns (🔵)  
Files with 2-3 duplicates (may be acceptable depending on context).

## Naming Conventions

### Recommended Pattern: `{context}_{function}.ex`

Instead of generic names, use domain-specific prefixes:

```elixir
# Generic (problematic)
manager.ex
handler.ex
server.ex

# Contextual (better)
buffer_manager.ex
event_handler.ex
focus_server.ex
```

### Naming Examples

| Generic Name | Context | Suggested Name |
|--------------|---------|----------------|
| `manager.ex` | `terminal/buffer/` | `buffer_manager.ex` |
| `handler.ex` | `core/events/` | `event_handler.ex` |
| `server.ex` | `ui/focus/` | `focus_server.ex` |
| `processor.ex` | `terminal/ansi/` | `ansi_processor.ex` |
| `validator.ex` | `terminal/config/` | `config_validator.ex` |

## Integration with Development Workflow

### Editor Integration
The Credo check runs inline in editors that integrate with Credo. Once `mix raxol.check.duplicates` ships, it can be wired into a pre-commit hook or CI pipeline.

## Example Output

```bash
[CHECK] Checking for duplicate filenames...
Scanning directories: lib, test

🔴 CRITICAL - 'validator.ex' (2 files):
  • lib/raxol/terminal/extension/validator.ex
  • lib/raxol/terminal/config/validator.ex
  [NOTE] Suggested renames:
    lib/raxol/terminal/extension/validator.ex → extension_validator.ex
    lib/raxol/terminal/config/validator.ex → config_validator.ex

🟡 WARNING - 'manager_test.exs' (21 files):
  • test/raxol/core/runtime/plugins/manager_test.exs
  • test/raxol/core/events/manager_test.exs
  • test/raxol/terminal/split/manager_test.exs
  [... more files ...]

🔵 INFO - 'schema.ex' (2 files):
  • lib/raxol/config/schema.ex
  • lib/raxol/terminal/config/schema.ex
```

## Status

Credo integration is implemented. The standalone script and mix task described above are planned but not yet built.

False positives: add files to `exclude_files`. Legacy code: use `--exclude` while refactoring.

When adding new files: use descriptive, contextual names and let `mix credo` flag duplicates before committing.