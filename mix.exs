defmodule Scry.Engine.InfluxDB.MixProject do
  use Mix.Project

  @version "0.1.0"

  # `mix precommit` includes `test` as a step; without this, Mix runs
  # the whole alias chain (including `mix test`) in :dev, and `mix test`
  # itself refuses to run outside :test when invoked as a sub-task
  # rather than the top-level command.
  def cli do
    [preferred_envs: [precommit: :test]]
  end

  def project do
    [
      app: :scry_engine_influxdb,
      version: @version,
      elixir: "~> 1.19",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      description: description(),
      package: package(),
      name: "Scry.Engine.InfluxDB",
      docs: docs(),
      aliases: aliases(),
      test_coverage: [tool: ExCoveralls]
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger]
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      # === SCRY CORE ===
      # A local path dependency, not a Hex version constraint, since
      # scry_core isn't published to Hex yet -- this package implements
      # `Scry.Core.EngineBehaviour` and returns `Scry.Core.Query.t()`-
      # shaped data, so it's the real dependency, not test-only. Switch
      # to a `~> x.y` Hex requirement once scry_core is actually
      # published.
      {:scry_core, path: "../scry_core"},

      # === HTTP CLIENT, NOT A DEDICATED DRIVER ===
      # `instream` is confirmed stale (last Hex release April 2023, no
      # InfluxDB 3.x support) AND has the identical disqualifying shape
      # `snap` had for `scry_engine_elasticsearch`: a compile-time `use
      # Instream.Connection` macro-based module defined in the
      # *consuming* application, not a value opened at runtime the way
      # this ecosystem's own `Conn.open/1` convention needs. `req`
      # talks to InfluxDB 1.8's own classic HTTP API (`/query`,
      # `/write`) directly instead, the same "no client-specific
      # protocol to speak" reasoning already used for
      # `scry_engine_elasticsearch`/`scry_engine_couchdb`/
      # `scry_engine_loki`.
      {:req, "~> 0.5"},

      # `req` already pulls `jason` in transitively (its own default
      # JSON codec), but InfluxDB 1.x's own bound-parameter feature
      # needs it encoded explicitly into the `params` *query-string*
      # argument (not a JSON request body `req` would encode for free)
      # -- an explicit direct dependency rather than relying on an
      # implementation detail of `req`'s own dependency tree.
      {:jason, "~> 1.4"},

      # === CODE QUALITY & STATIC ANALYSIS ===
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:sobelow, "~> 0.14", only: [:dev, :test], runtime: false},
      {:excoveralls, "~> 0.18", only: [:dev, :test], runtime: false},
      # Credo is invoked via `MIX_ENV=test mix credo`
      # Dialyzer is invoked via `MIX_ENV=test mix dialyzer`
      # Sobelow is invoked via `MIX_ENV=test mix sobelow`
      # Coveralls is invoked via `MIX_ENV=test mix coveralls

      # === TESTING ===
      {:stream_data, "~> 1.1", only: [:dev, :test]},

      # === DEVELOPMENT TOOLING ===
      # Mix, and Hex are built-in (no deps needed)
      {:ex_doc, "~> 0.40", only: [:dev], runtime: false}
      # ExDoc is invoked via `MIX_ENV=dev mix docs`
    ]
  end

  # Fast/cheap checks first so a broken commit fails quickly; dialyzer
  # (slowest, especially its first PLT build) runs last.
  defp aliases do
    [
      precommit: [
        "format",
        "compile --warnings-as-errors",
        "credo --strict",
        "sobelow",
        "test",
        "dialyzer"
      ]
    ]
  end

  defp description do
    "A real Scry.Core.EngineBehaviour implementation over InfluxDB 1.x, translating ordinary " <>
      "WHERE predicates into real, bind-parameterized InfluxQL -- the time-series kind's fourth " <>
      "real backend, and the first with a genuinely SQL-like native query language to translate into."
  end

  defp package do
    [
      licenses: ["MIT"],
      links: %{"GitHub" => "https://github.com/joetjen/scry_engine_influxdb"},
      files: ~w(lib .formatter.exs mix.exs README.md CHANGELOG.md LICENSE)
    ]
  end

  defp docs do
    [
      main: "readme",
      source_url: "https://github.com/joetjen/scry_engine_influxdb",
      source_ref: "v#{@version}",
      extras: extras()
    ]
  end

  defp extras do
    [
      "README.md",
      "CHANGELOG.md",
      "LICENSE"
    ]
  end
end
