defmodule PhoenixKitDashboards.MixProject do
  use Mix.Project

  @version "0.2.0"
  @source_url "https://github.com/BeamLabEU/phoenix_kit_dashboards"

  def project do
    [
      app: :phoenix_kit_dashboards,
      version: @version,
      elixir: "~> 1.18",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      aliases: aliases(),

      # Hex
      description:
        "Customizable dashboards for PhoenixKit — compose admin dashboard pages from widgets exposed by any module",
      package: package(),

      # Dialyzer
      dialyzer: [plt_add_apps: [:phoenix_kit]],

      # Docs
      name: "PhoenixKitDashboards",
      source_url: @source_url,
      docs: docs()
    ]
  end

  def application do
    [
      extra_applications: [:logger, :phoenix_kit]
    ]
  end

  # test/support/ is compiled only in :test so DataCase and TestRepo
  # don't leak into the published package.
  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp aliases do
    [
      quality: ["format", "credo --strict", "dialyzer"],
      "quality.ci": ["format --check-formatted", "credo --strict", "dialyzer"],
      precommit: [
        "compile --force --warnings-as-errors",
        "deps.unlock --check-unused",
        "cmd mix hex.audit",
        "quality.ci"
      ],
      "test.setup": [
        "ecto.create --quiet -r PhoenixKitDashboards.Test.Repo"
      ],
      "test.reset": [
        "ecto.drop --quiet -r PhoenixKitDashboards.Test.Repo",
        "test.setup"
      ]
    ]
  end

  # phoenix_kit deps resolve from Hex by default. For cross-repo work against a
  # local checkout, export <APP>_PATH — e.g. PHOENIX_KIT_PATH=../phoenix_kit.
  # Unset => the published pin, so mix hex.publish is unaffected.
  defp pk_dep(app, requirement, opts \\ []) do
    env_var = String.upcase(Atom.to_string(app)) <> "_PATH"

    case System.get_env(env_var) do
      nil when opts == [] -> {app, requirement}
      nil -> {app, requirement, opts}
      path -> {app, [path: path, override: true] ++ opts}
    end
  end

  defp deps do
    [
      # PhoenixKit provides the Module behaviour, Settings API, Repo helper, and
      # the ModuleRegistry we query to discover widget providers. Floor is 1.7.179
      # — the release that ships core migration V139 (the per-dashboard `config`
      # column: type, home tier, customized breakpoints). V133 (1.7.145) created
      # the phoenix_kit_dashboards table; an older 1.7.x would resolve the pin yet
      # lack the `config` column the layout engine reads.
      pk_dep(:phoenix_kit, "~> 1.7.189"),

      # LiveView powers the dashboard builder and the widget LiveComponents.
      {:phoenix_live_view, "~> 1.1"},

      # Docs
      {:ex_doc, "~> 0.34", only: :dev, runtime: false},

      # Code quality
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},

      # HTML parser for Phoenix.LiveViewTest in LiveView smoke tests
      {:lazy_html, ">= 0.1.0", only: :test}
    ]
  end

  defp package do
    [
      licenses: ["MIT"],
      links: %{"GitHub" => @source_url},
      files: ~w(lib priv .formatter.exs mix.exs README.md CHANGELOG.md LICENSE)
    ]
  end

  defp docs do
    [
      main: "PhoenixKitDashboards",
      source_ref: "v#{@version}"
    ]
  end
end
