# Contributing to Raxol

Contributions welcome.

## Getting Started

1. Fork the repo
2. Clone locally: `git clone https://github.com/YOUR_USERNAME/raxol.git`
3. Add upstream: `git remote add upstream https://github.com/DROOdotFOO/raxol.git`

## Development setup

### Prerequisites
- Elixir 1.17.3
- Erlang/OTP 27.0
- Node.js 20+ (for VSCode extension dev)
- PostgreSQL 15+

### Initial setup
```bash
mix deps.get
mix compile
mix test
```

### Tools
- Format: `mix format`
- Analysis: `mix dialyzer`
- Docs: `mix docs`
- Coverage: `mix test --cover`

## Making Contributions

**Bug fixes** - Check for duplicates, create an issue if needed, reference it in your PR.

**Features** - Discuss in an issue first. Break into smaller PRs. Update docs and tests.

**Documentation** - Fix typos, clarify content, add examples.

**Tests** - Cover new code, improve reliability, add property-based tests.

### Workflow

1. Create branch: `git checkout -b feature/name`
2. Make changes, add tests
3. `mix test` and `mix format`
4. Push and open a PR

## Code Style

Follow the [Elixir Style Guide](https://github.com/christopheradams/elixir_style_guide). Use descriptive names, small focused functions, `@doc` and `@spec` annotations.

```elixir
defmodule Raxol.Example do
  @moduledoc """
  Example module demonstrating code style.
  """

  @type option :: {:timeout, timeout()} | {:retries, non_neg_integer()}

  @doc """
  Performs an example operation.

  ## Options

    * `:timeout` - Maximum time in milliseconds (default: 5000)
    * `:retries` - Number of retry attempts (default: 3)

  ## Examples

      iex> Example.perform(:test, timeout: 1000)
      {:ok, :result}
  """
  @spec perform(atom(), [option()]) :: {:ok, term()} | {:error, term()}
  def perform(operation, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, 5000)
    retries = Keyword.get(opts, :retries, 3)
    do_perform(operation, timeout, retries)
  end

  defp do_perform(operation, timeout, retries) do
    {:ok, :result}
  end
end
```

## Testing

```bash
mix test                        # all tests
mix test --seed 12345           # reproducible
mix test --only integration     # tagged tests
mix test --exclude slow         # skip slow tests
mix test --cover                # with coverage
```

Maintain >95% coverage. Use descriptive test names. Test edge cases.

```elixir
defmodule Raxol.ExampleTest do
  use ExUnit.Case

  describe "perform/2" do
    test "returns success with valid input" do
      assert {:ok, _} = Example.perform(:test)
    end

    test "returns error on invalid operation" do
      assert {:error, :invalid_operation} = Example.perform(:invalid)
    end
  end
end
```

## Submitting changes

1. Rebase on upstream: `git fetch upstream && git rebase upstream/master`
2. Push: `git push origin feature/name`
3. Open PR with a clear title, issue references, and description of changes

### PR Title Format
```
type: Brief description
```

Types: `feat`, `fix`, `docs`, `style`, `refactor`, `test`, `chore`

Requires one review. Keep PRs focused. Address feedback promptly.

## Community

- Issues for bugs and features
- Discussions for questions and ideas
- PRs for code contributions

Be respectful, welcome newcomers, give constructive feedback, assume good intentions.

Contributors are recognized in the README, release notes, and docs.
