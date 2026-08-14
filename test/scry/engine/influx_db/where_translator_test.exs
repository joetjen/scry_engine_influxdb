defmodule Scry.Engine.InfluxDB.WhereTranslatorTest do
  use ExUnit.Case, async: true

  alias Scry.Engine.InfluxDB.WhereTranslator

  describe "compile/2 -- basic shapes" do
    test "an empty wheres list compiles to no clause at all" do
      assert {:ok, nil, %{}} = WhereTranslator.compile([], %{})
    end

    test "a single comparison binds one parameter" do
      wheres = [{:cmp, :eq, ["host"], "server1"}]
      assert {:ok, clause, bind_params} = WhereTranslator.compile(wheres, %{})
      assert clause == ~s("host" = $p0)
      assert bind_params == %{"p0" => "server1"}
    end

    test "multiple top-level wheres combine with AND" do
      wheres = [{:cmp, :eq, ["host"], "server1"}, {:cmp, :gt, ["value"], 10}]
      assert {:ok, clause, bind_params} = WhereTranslator.compile(wheres, %{})
      assert clause == "(\"host\" = $p0 AND \"value\" > $p1)"
      assert bind_params == %{"p0" => "server1", "p1" => 10}
    end

    test "explicit AND/OR nest correctly" do
      wheres = [
        {:or, {:cmp, :eq, ["host"], "server1"}, {:cmp, :eq, ["host"], "server2"}}
      ]

      assert {:ok, clause, bind_params} = WhereTranslator.compile(wheres, %{})
      assert clause == "(\"host\" = $p0 OR \"host\" = $p1)"
      assert bind_params == %{"p0" => "server1", "p1" => "server2"}
    end
  end

  describe "compile/2 -- every operator" do
    for {op, influxql} <- [eq: "=", not_eq: "!=", gt: ">", ge: ">=", lt: "<", le: "<="] do
      test "#{op} translates to #{influxql}" do
        wheres = [{:cmp, unquote(op), ["value"], 1}]
        assert {:ok, clause, _bind_params} = WhereTranslator.compile(wheres, %{})
        assert clause == ~s("value" #{unquote(influxql)} $p0)
      end
    end
  end

  describe "compile/2 -- NOT of a plain comparison" do
    test "NOT of an equality rewrites to !=" do
      wheres = [{:not, {:cmp, :eq, ["host"], "server1"}}]
      assert {:ok, clause, _} = WhereTranslator.compile(wheres, %{})
      assert clause == ~s("host" != $p0)
    end

    test "NOT of an inequality rewrites to =" do
      wheres = [{:not, {:cmp, :not_eq, ["host"], "server1"}}]
      assert {:ok, clause, _} = WhereTranslator.compile(wheres, %{})
      assert clause == ~s("host" = $p0)
    end

    test "NOT of a compound expression declines outright" do
      wheres = [{:not, {:and, {:cmp, :eq, ["a"], 1}, {:cmp, :eq, ["b"], 2}}}]

      assert {:error, {:unsupported, {:construct, :complex_not}}} =
               WhereTranslator.compile(wheres, %{})
    end
  end

  describe "compile/2 -- the time field converts to a Unix nanosecond integer" do
    test "a DateTime.t() threshold" do
      dt = DateTime.new!(~D[2026-01-01], ~T[00:00:00])
      wheres = [{:cmp, :ge, ["time"], dt}]
      assert {:ok, _clause, bind_params} = WhereTranslator.compile(wheres, %{})
      assert bind_params["p0"] == DateTime.to_unix(dt, :nanosecond)
    end

    test "a NaiveDateTime.t() threshold" do
      ndt = ~N[2026-01-01 00:00:00]
      wheres = [{:cmp, :ge, ["time"], ndt}]
      assert {:ok, _clause, bind_params} = WhereTranslator.compile(wheres, %{})
      expected = ndt |> DateTime.from_naive!("Etc/UTC") |> DateTime.to_unix(:nanosecond)
      assert bind_params["p0"] == expected
    end

    test "a bare integer is assumed already-nanoseconds" do
      wheres = [{:cmp, :ge, ["time"], 12_345}]
      assert {:ok, _clause, bind_params} = WhereTranslator.compile(wheres, %{})
      assert bind_params["p0"] == 12_345
    end

    test "an unrecognized time value declines outright" do
      wheres = [{:cmp, :ge, ["time"], "not a date"}]

      assert {:error, {:unsupported, {:timestamp_value, "not a date"}}} =
               WhereTranslator.compile(wheres, %{})
    end
  end

  describe "compile/2 -- {:param, name} resolution" do
    test "resolves against the params map" do
      wheres = [{:cmp, :eq, ["host"], {:param, "h"}}]
      assert {:ok, _clause, bind_params} = WhereTranslator.compile(wheres, %{"h" => "server1"})
      assert bind_params == %{"p0" => "server1"}
    end

    test "a missing param is a clear query error" do
      wheres = [{:cmp, :eq, ["host"], {:param, "h"}}]

      assert {:error, {:query_error, {:missing_param, "h"}}} =
               WhereTranslator.compile(wheres, %{})
    end
  end

  describe "compile/2 -- unsupported shapes decline outright, never silently narrow" do
    test "an :in leaf declines" do
      wheres = [{:in, ["host"], ["server1", "server2"]}]

      assert {:error, {:unsupported, {:construct, :where_shape}}} =
               WhereTranslator.compile(wheres, %{})
    end
  end
end
