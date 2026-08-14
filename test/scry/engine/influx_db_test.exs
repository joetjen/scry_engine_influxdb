defmodule Scry.Engine.InfluxDBTest do
  @moduledoc """
  `Scry.Engine.InfluxDB` -- confirms `execute/3` translates ordinary
  `WHERE` predicates (including `LAST`-lowered timestamp bounds) into
  real, bind-parameterized InfluxQL and executes it against a real
  InfluxDB 1.8 container, that `ORDER BY`/`LIMIT`/`OFFSET` push down
  only when InfluxQL itself can express them (`time` only) and are
  cleared from the query handed to `Scry.Core.QueryOps.run_flat/3`
  when they are (never double-applied), that `GROUP BY`/aggregates
  apply generically, and that `%Scry.Core.CombinedQuery{}`/a
  `WITH`-bound source both resolve via `Scry.Core.QueryOps.
  run_document/4` -- all against a real server, not just plausible-
  looking output.

  **Requires a real, reachable InfluxDB 1.8 instance** -- run one
  locally via `docker run -d --name scry-influxdb -p 8086:8086
  influxdb:1.8`. Runs `async: false` -- every test shares one real
  server and a small, fixed set of points, dropped and rebuilt in
  `setup_all`.
  """

  use ExUnit.Case, async: false

  alias Scry.Core.{CombinedQuery, Query}
  alias Scry.Engine.InfluxDB, as: Engine
  alias Scry.Engine.InfluxDB.Conn

  @database "scry_engine_influxdb_test"

  setup_all do
    {:ok, conn} = Conn.open(database: @database)
    now = DateTime.utc_now()
    seed!(conn, now)
    %{conn: conn, now: now}
  end

  defp seed!(conn, now) do
    # `CREATE`/`DROP DATABASE` name their own target database directly
    # in the InfluxQL text -- the request's own `db=` query parameter
    # (always `@database` here, via `conn`) is irrelevant to either,
    # confirmed directly, so the ordinary `conn` works fine for these
    # too, no separate connection needed.
    {:ok, _} = Conn.query(conn, "DROP DATABASE #{@database}")
    {:ok, _} = Conn.query(conn, "CREATE DATABASE #{@database}")

    write_at!(conn, now, -300, %{"host" => "server1", "region" => "us"}, 42.5)
    write_at!(conn, now, -120, %{"host" => "server2", "region" => "eu"}, 13.2)
    write_at!(conn, now, -30, %{"host" => "server1", "region" => "us"}, 99.9)
  end

  defp write_at!(conn, now, offset_seconds, tags, value) do
    ts_ns = DateTime.to_unix(now, :nanosecond) + offset_seconds * 1_000_000_000
    tag_str = Enum.map_join(tags, ",", fn {k, v} -> "#{k}=#{v}" end)
    :ok = Conn.write(conn, "cpu_usage,#{tag_str} value=#{value} #{ts_ns}")
  end

  defp materialize({:ok, rows}), do: {:ok, rows |> Enum.to_list()}
  defp materialize(other), do: other

  defp since(now, offset_seconds), do: DateTime.add(now, offset_seconds, :second)

  describe "ordinary WHERE, including LAST-lowered timestamp bounds" do
    test "matches every point with no WHERE at all", %{conn: conn} do
      query = %Query{source: ["cpu_usage"], select: [{:field, ["host"]}]}
      assert {:ok, rows} = materialize(Engine.execute(conn, query, %{}))
      assert length(rows) == 3
    end

    test "a timestamp lower bound narrows correctly", %{conn: conn, now: now} do
      query = %Query{
        source: ["cpu_usage"],
        wheres: [{:cmp, :ge, ["time"], since(now, -200)}],
        select: [{:field, ["host"]}]
      }

      assert {:ok, rows} = materialize(Engine.execute(conn, query, %{}))
      assert length(rows) == 2
    end

    test "a tag equality narrows correctly", %{conn: conn} do
      query = %Query{
        source: ["cpu_usage"],
        wheres: [{:cmp, :eq, ["host"], "server1"}],
        select: [{:field, ["value"]}]
      }

      assert {:ok, rows} = materialize(Engine.execute(conn, query, %{}))
      assert Enum.map(rows, & &1["value"]) |> Enum.sort() == [42.5, 99.9]
    end

    test "a numeric field comparison narrows correctly", %{conn: conn} do
      query = %Query{
        source: ["cpu_usage"],
        wheres: [{:cmp, :gt, ["value"], 50}],
        select: [{:field, ["host"]}]
      }

      assert {:ok, [row]} = materialize(Engine.execute(conn, query, %{}))
      assert row == %{"host" => "server1"}
    end

    test "AND combines two predicates correctly", %{conn: conn} do
      query = %Query{
        source: ["cpu_usage"],
        wheres: [{:cmp, :eq, ["host"], "server1"}, {:cmp, :lt, ["value"], 50}],
        select: [{:field, ["value"]}]
      }

      assert {:ok, [row]} = materialize(Engine.execute(conn, query, %{}))
      assert row == %{"value" => 42.5}
    end

    test "an unmatched WHERE returns an empty result, not an error", %{conn: conn} do
      query = %Query{
        source: ["cpu_usage"],
        wheres: [{:cmp, :eq, ["host"], "no_such_host"}],
        select: [{:field, ["value"]}]
      }

      assert {:ok, []} = materialize(Engine.execute(conn, query, %{}))
    end
  end

  describe "ORDER BY/LIMIT/OFFSET -- pushed down only when InfluxQL can express them" do
    test "ORDER BY time DESC + LIMIT push down and are not double-applied", %{conn: conn} do
      query = %Query{
        source: ["cpu_usage"],
        order_bys: [{{:field, ["time"]}, :desc}],
        limit: 1,
        select: [{:field, ["value"]}]
      }

      assert {:ok, [row]} = materialize(Engine.execute(conn, query, %{}))
      assert row == %{"value" => 99.9}
    end

    test "OFFSET composes with ORDER BY time ASC", %{conn: conn} do
      query = %Query{
        source: ["cpu_usage"],
        order_bys: [{{:field, ["time"]}, :asc}],
        limit: 1,
        offset: 1,
        select: [{:field, ["value"]}]
      }

      assert {:ok, [row]} = materialize(Engine.execute(conn, query, %{}))
      assert row == %{"value" => 13.2}
    end

    test "ORDER BY on a non-time field is not pushed down, but still works generically", %{
      conn: conn
    } do
      query = %Query{
        source: ["cpu_usage"],
        order_bys: [{{:field, ["value"]}, :desc}],
        limit: 1,
        select: [{:field, ["value"]}]
      }

      assert {:ok, [row]} = materialize(Engine.execute(conn, query, %{}))
      assert row == %{"value" => 99.9}
    end
  end

  describe "GROUP BY/aggregates apply generically, never pushed to InfluxQL's own" do
    test "GROUP BY host with count()", %{conn: conn} do
      query = %Query{
        source: ["cpu_usage"],
        group_bys: [["host"]],
        select: [
          {:field, ["host"]},
          {:computed, "total", {:call, "count", [{:field, ["value"]}]}}
        ]
      }

      assert {:ok, rows} = materialize(Engine.execute(conn, query, %{}))
      by_host = Map.new(rows, &{&1["host"], &1["total"]})
      assert by_host == %{"server1" => 2, "server2" => 1}
    end
  end

  describe "%Scry.Core.CombinedQuery{} and a WITH-bound source" do
    test "CombinedQuery delegates to Scry.Core.QueryOps.run_document/4", %{conn: conn} do
      left = %Query{
        source: ["cpu_usage"],
        wheres: [{:cmp, :eq, ["host"], "server1"}, {:cmp, :eq, ["value"], 42.5}],
        select: [{:field, ["value"]}]
      }

      right = %Query{
        source: ["cpu_usage"],
        wheres: [{:cmp, :eq, ["host"], "server2"}],
        select: [{:field, ["value"]}]
      }

      combined = %CombinedQuery{op: :union, left: left, right: right}

      assert {:ok, rows} = materialize(Engine.execute(conn, combined, %{}))
      assert rows |> Enum.map(& &1["value"]) |> Enum.sort() == [13.2, 42.5]
    end

    test "a WITH-bound top-level source runs the binding instead of a real measurement", %{
      conn: conn
    } do
      binding = %Query{
        source: ["cpu_usage"],
        wheres: [{:cmp, :eq, ["host"], "server2"}],
        select: [{:field, ["value"]}]
      }

      query = %Query{
        source: ["server2_only"],
        with_bindings: %{"server2_only" => binding},
        select: [{:field, ["value"]}]
      }

      assert {:ok, rows} = materialize(Engine.execute(conn, query, %{}))
      assert Enum.map(rows, & &1["value"]) == [13.2]
    end
  end

  describe "describe_source/2" do
    test "reports field/tag names with real server-reported types", %{conn: conn} do
      assert {:ok, fields} = Engine.describe_source(conn, "cpu_usage")
      by_name = Map.new(fields, &{&1.name, &1})

      assert by_name["value"].scalar == :float
      assert by_name["value"].nullable == true
      assert by_name["host"].scalar == :string
      assert by_name["region"].scalar == :string
    end

    test "a measurement with no observed points at all is not found", %{conn: conn} do
      assert {:error, :not_found} = Engine.describe_source(conn, "no_such_measurement")
    end
  end
end
