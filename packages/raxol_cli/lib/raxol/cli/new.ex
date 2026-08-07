defmodule Raxol.CLI.New do
  @moduledoc """
  Scaffold a new Raxol application.

  A self-contained generator (plain `File` writes, no Mix at runtime) that emits
  a minimal runnable TEA app: `mix.exs`, a counter module, and a README.
  """

  @name_re ~r/^[a-z][a-z0-9_]*$/

  @doc "Generate a new app under `./<name>`, returning an exit code."
  @spec run([String.t()]) :: non_neg_integer()
  def run([name | _]) when is_binary(name) do
    cond do
      not Regex.match?(@name_re, name) ->
        err("invalid app name #{inspect(name)} (use snake_case: my_app)")

      File.exists?(name) ->
        err("#{name}/ already exists")

      true ->
        generate(name)
    end
  end

  def run(_), do: err("usage: raxol new <app_name>")

  defp generate(name) do
    mod = Macro.camelize(name)

    write(Path.join(name, "mix.exs"), mix_exs(name, mod))
    write(Path.join([name, "lib", "#{name}.ex"]), app_ex(mod))
    write(Path.join(name, ".formatter.exs"), formatter_exs())
    write(Path.join(name, "README.md"), readme(name, mod))

    IO.puts("""
    Created #{name}/

    Next:
      cd #{name}
      mix deps.get
      mix run -e "#{mod}.start()"
    """)

    0
  end

  defp write(path, contents) do
    path |> Path.dirname() |> File.mkdir_p!()
    File.write!(path, contents)
    IO.puts("  create #{path}")
  end

  defp err(msg) do
    IO.puts(:stderr, "raxol new: #{msg}")
    1
  end

  # -- templates --------------------------------------------------------------

  defp mix_exs(name, mod) do
    """
    defmodule #{mod}.MixProject do
      use Mix.Project

      def project do
        [app: :#{name}, version: "0.1.0", elixir: "~> 1.17", deps: deps()]
      end

      def application, do: [extra_applications: [:logger]]

      defp deps do
        [{:raxol, "~> 2.6"}]
      end
    end
    """
  end

  defp app_ex(mod) do
    """
    defmodule #{mod} do
      @moduledoc "A minimal Raxol counter app (The Elm Architecture)."
      use Raxol.UI, framework: :react

      import Raxol.Core.Runtime.Application, only: [key_match: 1]

      def start, do: Raxol.start_link(__MODULE__)

      def init(_), do: %{count: 0}

      def update(msg, model) do
        case msg do
          key_match("+") -> {%{model | count: model.count + 1}, []}
          key_match("-") -> {%{model | count: model.count - 1}, []}
          key_match("q") -> {model, [:quit]}
          _ -> {model, []}
        end
      end

      def view(model) do
        box padding: 1 do
          column do
            text("Count: \#{model.count}", fg: :cyan)
            text("+/- to change, q to quit")
          end
        end
      end
    end
    """
  end

  defp formatter_exs do
    """
    [
      inputs: ["{mix,.formatter}.exs", "{config,lib,test}/**/*.{ex,exs}"]
    ]
    """
  end

  defp readme(_name, mod) do
    """
    # #{mod}

    A Raxol terminal app.

    ## Run

        mix deps.get
        mix run -e "#{mod}.start()"
    """
  end
end
