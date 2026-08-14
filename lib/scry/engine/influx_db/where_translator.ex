defmodule Scry.Engine.InfluxDB.WhereTranslator do
  @moduledoc """
  Translates a `Scry.Core.Query.t()`'s own `wheres` into a real,
  bind-parameterized InfluxQL `WHERE` clause -- a genuinely different
  posture from every other time-series adapter in this family
  (`scry_engine_redistimeseries`'s own narrow range-only `RangeQuery`,
  `scry_engine_loki`'s own extraction-only `RangeQuery`), justified by
  a real, confirmed capability difference: InfluxQL is a genuinely
  SQL-like query language with its own real `WHERE` clause and real
  bound-parameter support (`$name` placeholders plus a `params` JSON
  argument, confirmed directly against a real server -- not manual
  string interpolation), unlike a bare `TS.RANGE` numeric-range
  primitive or a LogQL stream selector with no boolean predicate
  language of its own. So this module mirrors the same full-`WHERE`-
  translation posture `scry_engine_duckdbex`/`scry_engine_ch`/
  `scry_engine_myxql` already have for real SQL, not the narrower
  "extract only what's safe, leave the rest generic" posture the other
  time-series adapters in this family use.

  ## What compiles

  Every predicate leaf is `{:cmp, op, [field], value}` (`op` one of
  `:eq`/`:not_eq`/`:gt`/`:ge`/`:lt`/`:le`), combined via `{:and, ...}`/
  `{:or, ...}`, or `{:not, {:cmp, :eq/:not_eq, ...}}` (negation of a
  plain equality/inequality only, rewritten to the opposite operator --
  InfluxQL has no general boolean `NOT` over an arbitrary compound
  expression the way SQL does). An `{:in, ...}` leaf, `:not` wrapping
  anything but a plain equality/inequality, or any other shape declines
  outright (`{:unsupported, {:construct, _}}`) rather than silently
  narrowing.

  `field` is always double-quote-identifier-quoted (`"field"`) --
  InfluxQL's own quoting syntax, needed the moment a field name
  collides with a reserved word or contains a special character, and
  harmless (confirmed directly) when it doesn't, so always applied for
  consistency rather than only when strictly required. `field == "time"`
  is InfluxDB's own real, native timestamp column (confirmed directly
  from a real query response's own `columns` list) -- its own bound
  value converts from a `DateTime.t()`/`NaiveDateTime.t()` to a Unix
  *nanosecond* integer (confirmed directly: binding a nanosecond
  integer against `"time"` compares correctly), matching the
  `epoch=ns` mode `Scry.Engine.InfluxDB.Conn.query/3` always requests.
  Every other field's own value binds as-is.
  """

  alias Scry.Core.Query

  @time_field "time"

  @doc """
  Translates `wheres` (with `params` resolving any `{:param, name}`
  placeholder) into a real, bind-parameterized InfluxQL `WHERE` clause
  -- `{:ok, nil, %{}}` for an empty `wheres`, `{:ok, clause, bind_params}`
  otherwise, `{:error, {:unsupported, {:construct, _}}}` the moment any
  predicate falls outside what this module translates. This module's
  own moduledoc has the complete "what compiles" reasoning.
  """
  @spec compile([Query.predicate()], map()) ::
          {:ok, String.t() | nil, map()} | {:error, term()}
  def compile([], _params), do: {:ok, nil, %{}}

  def compile(wheres, params) do
    combined = Enum.reduce(wheres, fn predicate, acc -> {:and, acc, predicate} end)

    case translate(combined, params, 0, %{}) do
      {:ok, clause, _next, bind_params} -> {:ok, clause, bind_params}
      {:error, _} = err -> err
    end
  end

  defp translate({:and, l, r}, params, next, bind_params),
    do: translate_boolean(l, r, "AND", params, next, bind_params)

  defp translate({:or, l, r}, params, next, bind_params),
    do: translate_boolean(l, r, "OR", params, next, bind_params)

  defp translate({:not, {:cmp, :eq, field, value}}, params, next, bind_params),
    do: translate({:cmp, :not_eq, field, value}, params, next, bind_params)

  defp translate({:not, {:cmp, :not_eq, field, value}}, params, next, bind_params),
    do: translate({:cmp, :eq, field, value}, params, next, bind_params)

  defp translate({:not, _other}, _params, _next, _bind_params),
    do: {:error, {:unsupported, {:construct, :complex_not}}}

  defp translate({:cmp, op, [field], value}, params, next, bind_params) do
    with {:ok, influxql_op} <- operator(op),
         {:ok, resolved} <- resolve_value(value, params),
         {:ok, bound_value} <- bind_value(field, resolved) do
      param_name = "p#{next}"
      clause = ~s(#{quote_ident(field)} #{influxql_op} $#{param_name})
      {:ok, clause, next + 1, Map.put(bind_params, param_name, bound_value)}
    end
  end

  defp translate(_other, _params, _next, _bind_params),
    do: {:error, {:unsupported, {:construct, :where_shape}}}

  defp translate_boolean(l, r, joiner, params, next, bind_params) do
    with {:ok, lc, next2, bp2} <- translate(l, params, next, bind_params),
         {:ok, rc, next3, bp3} <- translate(r, params, next2, bp2) do
      {:ok, "(#{lc} #{joiner} #{rc})", next3, bp3}
    end
  end

  defp operator(:eq), do: {:ok, "="}
  defp operator(:not_eq), do: {:ok, "!="}
  defp operator(:gt), do: {:ok, ">"}
  defp operator(:ge), do: {:ok, ">="}
  defp operator(:lt), do: {:ok, "<"}
  defp operator(:le), do: {:ok, "<="}
  defp operator(other), do: {:error, {:unsupported, {:operator, other}}}

  defp resolve_value({:param, name}, params) do
    case Map.fetch(params, name) do
      {:ok, value} -> {:ok, value}
      :error -> {:error, {:query_error, {:missing_param, name}}}
    end
  end

  defp resolve_value(value, _params), do: {:ok, value}

  defp bind_value(@time_field, %DateTime{} = dt), do: {:ok, DateTime.to_unix(dt, :nanosecond)}

  defp bind_value(@time_field, %NaiveDateTime{} = dt),
    do: {:ok, dt |> DateTime.from_naive!("Etc/UTC") |> DateTime.to_unix(:nanosecond)}

  defp bind_value(@time_field, v) when is_integer(v), do: {:ok, v}
  defp bind_value(@time_field, other), do: {:error, {:unsupported, {:timestamp_value, other}}}
  defp bind_value(_field, value), do: {:ok, value}

  @doc "Backtick-style double-quotes `name` for use as an InfluxQL identifier, doubling a literal embedded quote by escaping it -- InfluxQL's own quoting syntax, applied unconditionally for consistency (harmless when not strictly required, confirmed directly) rather than only when a name collides with a reserved word or contains a special character. Shared with `Scry.Engine.InfluxDB` itself (`SHOW FIELD KEYS FROM \#{quote_ident(source)}`), so there is exactly one implementation, not two kept in sync by hand."
  @spec quote_ident(String.t()) :: String.t()
  def quote_ident(name), do: "\"" <> String.replace(name, "\"", "\\\"") <> "\""
end
