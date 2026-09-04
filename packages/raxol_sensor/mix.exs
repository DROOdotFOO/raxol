defmodule RaxolSensor.MixProject do
  use Mix.Project

  @version "2.6.0"
  @source_url "https://github.com/DROOdotFOO/raxol"

  def project do
    [
      app: :raxol_sensor,
      version: @version,
      elixir: "~> 1.16 or ~> 1.17 or ~> 1.18 or ~> 1.19 or ~> 1.20",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      description: description(),
      package: package(),
      docs: docs(),
      name: "Raxol Sensor",
      source_url: @source_url,
      homepage_url: "https://raxol.io"
    ]
  end

  def application do
    [
      extra_applications: [:logger]
    ]
  end

  defp deps do
    [
      {:circular_buffer, "~> 1.0"},
      {:nx, "~> 0.9", optional: true},

      # Dev/test only
      {:ex_doc, "~> 0.31", only: :dev, runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false}
    ]
  end

  defp description do
    """
    Sensor fusion framework for Elixir built on OTP. Poll sensors, buffer
    readings, fuse with weighted averaging and thresholds, and render HUD
    widgets (gauges, sparklines, threat indicators). Optional Nx backend.
    """
  end

  defp package do
    [
      name: "raxol_sensor",
      files: ~w(lib .formatter.exs mix.exs README.md LICENSE.md),
      licenses: ["MIT"],
      links: %{
        "GitHub" => @source_url,
        "Docs" => "https://hexdocs.pm/raxol_sensor",
        "Changelog" => "https://github.com/DROOdotFOO/raxol/blob/master/CHANGELOG.md",
        "Website" => "https://raxol.io"
      },
      maintainers: ["Raxol Team"]
    ]
  end

  defp docs do
    [
      main: "readme",
      source_url: @source_url,
      source_ref: "v#{@version}",
      extras: [
        "README.md"
      ]
    ]
  end
end
