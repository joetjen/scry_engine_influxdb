defmodule Scry.Engine.InfluxDB do
  @moduledoc """
  A real `Scry.Core.EngineBehaviour` implementation over InfluxDB 1.x,
  via [`req`](https://hex.pm/packages/req) -- not `instream` (confirmed
  stale, and architecturally the wrong shape; this module's own `mix.exs`
  has the full reasoning). The `time-series` kind's *fourth* real
  backend, after `scry_engine_ch`/`scry_engine_redistimeseries`/
  `scry_engine_loki` -- and the first with a genuinely SQL-like native
  query language (InfluxQL) to translate `WHERE` into for real, rather
  than a bare numeric-range primitive or an extraction-only posture.
  `scry_time_series`'s own `LAST`-lowering pass already rewrites `LAST
  <duration> OF <field>`/`LAST <from> TO <to> OF <field>` into an
  ordinary `WHERE` predicate before any engine ever sees the query --
  the identical "zero time-series-specific code needed" finding
  established three times over already -- so this package's own real
  work is `Scry.Engine.InfluxDB.WhereTranslator`.

  ## `source` maps onto one InfluxDB measurement, inside one fixed database

  `Scry.Engine.InfluxDB.Conn`'s own moduledoc has the full reasoning:
  `database` is fixed at `open/1` time, and `SELECT cpu_usage { ... }`
  becomes `SELECT * FROM "cpu_usage"` inside that one database -- the
  same relationship a SQL table has to its own schema. Every row
  exposes InfluxDB's own real column set: `"time"` (a real `DateTime.t()`,
  decoded from the server's own `epoch=ns` Unix-nanosecond form) plus
  every tag and field InfluxDB itself returns, both flattened together
  with no distinction at query time (confirmed directly: a plain
  `SELECT *`, no `GROUP BY`, returns exactly one series per measurement
  with tags and fields as ordinary sibling columns).

  ## `ORDER BY`/`LIMIT`/`OFFSET` push down only when InfluxQL itself can express them

  A real, confirmed InfluxQL restriction, not a stylistic scope choice:
  `ORDER BY` accepts *only* `time` (`ASC`/`DESC`) -- confirmed directly,
  `ORDER BY value DESC` is a real, clean InfluxQL parse error
  (`"only ORDER BY time supported at this time"`). So this package
  pushes `ORDER BY`/`LIMIT`/`OFFSET` down together only when `query.
  order_bys` is empty or exactly one key on `"time"` -- the identical
  "narrower but always correct" choice `scry_engine_redistimeseries`'s
  own moduledoc already makes, for the identical reason (pushing
  `LIMIT` without a safely-expressible sort risks the wrong *set* of
  rows, not just the wrong order). When pushed, `order_bys`/`limit`/
  `offset` are cleared from the query handed to `Scry.Core.QueryOps.
  run_flat/3` afterward -- the same real, confirmed `scry_engine_
  elasticsearch` finding applies here too (that module's own moduledoc
  has the "`run_flat/3` re-applies pagination generically, so a
  rewritten query must clear what's already been pushed down, not
  merely leave it, or a `LIMIT`/`OFFSET` gets silently applied twice"
  story) -- an empty `order_bys` with no `LIMIT`/`OFFSET` set at all
  needs no clearing either way, so this is a real, active step only
  when something was genuinely pushed. `WHERE` is deliberately never
  cleared, even when fully pushed down -- re-checking an already-
  satisfied predicate against a fetched row is a safe no-op, the same
  posture `scry_engine_neo4j`/`scry_engine_mongodb_driver`/`scry_engine_
  couchdb`/`scry_engine_loki` already take for their own pushed-down
  constructs.

  `GROUP BY`/aggregates are never pushed to InfluxQL's own `GROUP BY`/
  aggregate functions at all -- deliberately, the identical "no time-
  bucketing construct in the language yet" gap already documented for
  `scry_engine_redistimeseries`/the corrected `scry_engine_timescaledb`
  entry -- `Scry.Core.QueryOps.run_flat/3` handles every `GROUP BY`/
  aggregate generically instead, which also sidesteps InfluxQL's own
  confirmed multi-series-per-tag-group result shape (a real, different
  response envelope from the flat single-series shape this package's
  own decoder only ever needs to handle).
  """

  @behaviour Scry.Core.EngineBehaviour

  alias Scry.Core.{CombinedQuery, Query, QueryOps}
  alias Scry.Engine.InfluxDB.{Conn, WhereTranslator}

  @impl true
  def execute(conn, %CombinedQuery{} = combined, params),
    do: QueryOps.run_document(conn, combined, params, __MODULE__)

  def execute(%Conn{} = conn, %Query{source: source} = query, params) do
    if with_bound_source?(query) do
      QueryOps.run_document(conn, query, params, __MODULE__)
    else
      execute_flat(conn, source, query, params)
    end
  end

  defp with_bound_source?(%Query{source: [name], with_bindings: with_bindings}),
    do: Map.has_key?(with_bindings, name)

  defp with_bound_source?(_query), do: false

  defp execute_flat(conn, source, query, params) do
    with {:ok, measurement} <- measurement_name(source),
         {:ok, where_clause, bind_params} <- WhereTranslator.compile(query.wheres, params) do
      {order_clause, limit_clause, remaining_query} = plan_pushdown(query)
      influxql = build_select(measurement, where_clause, order_clause, limit_clause)

      with {:ok, result} <- Conn.query(conn, influxql, bind_params) do
        rows = decode_rows(result)
        QueryOps.run_flat(rows, remaining_query, params)
      end
    end
  end

  defp measurement_name([name]) when is_binary(name) and byte_size(name) > 0, do: {:ok, name}
  defp measurement_name(source), do: {:error, {:unsupported, {:source, source}}}

  defp plan_pushdown(%Query{order_bys: []} = query) do
    {nil, limit_offset_clause(query.limit, query.offset), %{query | limit: nil, offset: nil}}
  end

  defp plan_pushdown(%Query{order_bys: [{{:field, ["time"]}, direction}]} = query) do
    order_clause = "ORDER BY time #{influxql_direction(direction)}"
    limit_clause = limit_offset_clause(query.limit, query.offset)
    remaining = %{query | order_bys: [], limit: nil, offset: nil}
    {order_clause, limit_clause, remaining}
  end

  defp plan_pushdown(query), do: {nil, nil, query}

  defp influxql_direction(:asc), do: "ASC"
  defp influxql_direction(:desc), do: "DESC"

  defp limit_offset_clause(nil, nil), do: nil
  defp limit_offset_clause(limit, nil), do: "LIMIT #{limit}"
  defp limit_offset_clause(nil, offset), do: "OFFSET #{offset}"
  defp limit_offset_clause(limit, offset), do: "LIMIT #{limit} OFFSET #{offset}"

  defp build_select(measurement, where_clause, order_clause, limit_clause) do
    [
      "SELECT * FROM",
      WhereTranslator.quote_ident(measurement),
      where_part(where_clause),
      order_clause,
      limit_clause
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" ")
  end

  defp where_part(nil), do: nil
  defp where_part(clause), do: "WHERE #{clause}"

  defp decode_rows(%{"series" => [%{"columns" => columns, "values" => values}]}) do
    Enum.map(values, &decode_row(columns, &1))
  end

  defp decode_rows(_no_series), do: []

  defp decode_row(columns, row) do
    columns
    |> Enum.zip(row)
    |> Map.new(fn
      {"time", ns} -> {"time", DateTime.from_unix!(ns, :nanosecond)}
      {column, value} -> {column, value}
    end)
  end

  @doc """
  `Scry.Core.EngineBehaviour`'s optional `describe_source/2` callback --
  combines `SHOW FIELD KEYS FROM "<source>"` (each field's own real,
  server-reported `fieldType` -- `float`/`integer`/`string`/`boolean`,
  confirmed directly) and `SHOW TAG KEYS FROM "<source>"` (every tag,
  always string-valued -- InfluxDB's own tags are never anything else).
  `nullable: true` for every field/tag -- InfluxDB's own Line Protocol
  has no required-field concept at write time (any point may omit any
  tag/field), the identical schemaless-store reasoning `scry_engine_
  elasticsearch`/`scry_engine_redisearch`/`scry_engine_mongodb_driver`
  each already give.
  """
  @impl true
  @spec describe_source(Conn.t(), String.t()) ::
          {:ok, [Scry.Core.EngineBehaviour.introspected_field()]}
          | {:error, :not_found}
          | {:error, {:introspection_error, term()}}
  def describe_source(%Conn{} = conn, source) do
    with {:ok, field_result} <-
           Conn.query(conn, "SHOW FIELD KEYS FROM #{WhereTranslator.quote_ident(source)}"),
         {:ok, tag_result} <-
           Conn.query(conn, "SHOW TAG KEYS FROM #{WhereTranslator.quote_ident(source)}") do
      fields = field_keys(field_result) ++ tag_keys(tag_result)

      if fields == [] do
        {:error, :not_found}
      else
        {:ok, fields}
      end
    else
      {:error, {:query_error, reason}} -> {:error, {:introspection_error, reason}}
    end
  end

  defp field_keys(%{"series" => [%{"values" => values}]}) do
    Enum.map(values, fn [name, type] ->
      %{name: name, nullable: true, scalar: influxdb_scalar(type)}
    end)
  end

  defp field_keys(_no_series), do: []

  defp tag_keys(%{"series" => [%{"values" => values}]}) do
    Enum.map(values, fn [name] -> %{name: name, nullable: true, scalar: :string} end)
  end

  defp tag_keys(_no_series), do: []

  defp influxdb_scalar("float"), do: :float
  defp influxdb_scalar("integer"), do: :integer
  defp influxdb_scalar("string"), do: :string
  defp influxdb_scalar("boolean"), do: :boolean
  defp influxdb_scalar(_other), do: :unknown
end
