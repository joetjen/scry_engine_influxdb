# scry_engine_influxdb

A real [`Scry.Core.EngineBehaviour`](https://github.com/joetjen/scry_core)
implementation over InfluxDB 1.x, via [`req`](https://hex.pm/packages/req)
-- not `instream` (confirmed stale, and architecturally the wrong
shape; see below). The `time-series` kind's *fourth* real backend,
after
[`scry_engine_ch`](https://github.com/joetjen/scry_engine_ch)/
[`scry_engine_redistimeseries`](https://github.com/joetjen/scry_engine_redistimeseries)/
[`scry_engine_loki`](https://github.com/joetjen/scry_engine_loki) --
and the first with a genuinely SQL-like native query language
(InfluxQL) to translate `WHERE` into for real, rather than a bare
numeric-range primitive or an extraction-only posture.

`scry_time_series`'s own `LAST`-lowering pass already rewrites `LAST
<duration> OF <field>`/`LAST <from> TO <to> OF <field>` into an
ordinary `WHERE` predicate before any engine ever sees the query --
the identical "zero time-series-specific code needed" finding
established three times over already -- so this package's own real
work is `Scry.Engine.InfluxDB.WhereTranslator`.

Source: <https://github.com/joetjen/scry_engine_influxdb>. The
behaviour this implements lives in
[`scry_core`](https://github.com/joetjen/scry_core).

## Usage

```elixir
{:ok, conn} = Scry.Engine.InfluxDB.Conn.open(database: "mydb")

{:ok, query} = Scry.Core.parse(~s(SELECT cpu_usage WHERE host = "server1" { value }))
{:ok, cursor} = Scry.Core.Executor.run(query, Scry.Engine.InfluxDB, conn)
rows = Scry.Core.Cursor.to_list(cursor)
# rows == [%{"value" => 42.5}]
```

Writing points is entirely the caller's own job -- this package is
schema-agnostic and issues nothing but `GET /query`/`SHOW FIELD KEYS`/
`SHOW TAG KEYS` reads.

### Local development / running the test suite

```sh
docker run -d --name scry-influxdb -p 8086:8086 influxdb:1.8
```

## No dedicated driver -- confirmed disqualified on two independent grounds

`instream` is confirmed stale (last Hex release April 2023, no
InfluxDB 3.x support) *and* has the identical disqualifying shape
`snap` had for `scry_engine_elasticsearch`:
a compile-time `use Instream.Connection` macro-based module defined in
the *consuming* application, not a value opened at runtime the way
this ecosystem's own `Conn.open/1` convention needs. `req` talks to
InfluxDB 1.8's own classic HTTP API (`/query`, `/write`) directly
instead, the same "no client-specific protocol to speak" reasoning
already used for `scry_engine_elasticsearch`/`scry_engine_couchdb`/
`scry_engine_loki`. Targets InfluxDB 1.x specifically (not 2.x/3.x) --
the simplest, most stable API surface for validating the time-series
kind's own constructs: plain username/password (or none) and a fixed
database, no bucket/org/DBRP-mapping model, and InfluxQL rather than
Flux.

## `source` maps onto one InfluxDB measurement, inside one fixed database

`database` is fixed at `Conn.open/1` time, and `SELECT cpu_usage
{ ... }` becomes `SELECT * FROM "cpu_usage"` inside that one database
-- the same relationship a SQL table has to its own schema. Every row
exposes InfluxDB's own real column set: `"time"` (a real `DateTime.t()`,
decoded from the server's own `epoch=ns` Unix-nanosecond form) plus
every tag and field InfluxDB itself returns, both flattened together
with no distinction at query time.

## A real, bind-parameterized `WHERE` translator -- a different posture from this family's other time-series adapters

InfluxQL is a genuinely SQL-like query language with its own real
`WHERE` clause and real bound-parameter support (`$name` placeholders
plus a `params` JSON argument, confirmed directly against a real
server -- not manual string interpolation), unlike a bare `TS.RANGE`
numeric-range primitive (`scry_engine_redistimeseries`) or a LogQL
stream selector with no boolean predicate language of its own
(`scry_engine_loki`). So `Scry.Engine.InfluxDB.WhereTranslator` mirrors
the same full-`WHERE`-translation posture `scry_engine_duckdbex`/
`scry_engine_ch`/`scry_engine_myxql` already have for real SQL --
`{:cmp, ...}` leaves combined via `AND`/`OR`, plus `NOT` of a plain
equality/inequality (rewritten to the opposite operator -- InfluxQL has
no general boolean `NOT` over a compound expression) -- rather than the
narrower "extract only what's safe, leave the rest generic" posture the
other time-series adapters in this family use. An `:in` leaf or any
other unrecognized shape declines outright, never silently narrows.

## `ORDER BY`/`LIMIT`/`OFFSET` push down only when InfluxQL itself can express them

A real, confirmed InfluxQL restriction, not a stylistic scope choice:
`ORDER BY` accepts *only* `time` (`ASC`/`DESC`) -- confirmed directly,
`ORDER BY value DESC` is a real, clean InfluxQL parse error (`"only
ORDER BY time supported at this time"`). So `ORDER BY`/`LIMIT`/`OFFSET`
push down together only when `order_bys` is empty or exactly one key on
`"time"` -- the identical "narrower but always correct" choice
`scry_engine_redistimeseries` already makes. When pushed, `order_bys`/
`limit`/`offset` are cleared from the query handed to `Scry.Core.
QueryOps.run_flat/3` afterward, the same real, confirmed `scry_engine_
elasticsearch` double-application finding applies here too. `WHERE` is
never cleared, even when fully pushed down -- re-checking an already-
satisfied predicate is a safe no-op.

`GROUP BY`/aggregates are never pushed to InfluxQL's own -- the
identical "no time-bucketing construct in the language yet" gap already
documented for `scry_engine_redistimeseries`/the corrected
`scry_engine_timescaledb` entry.

## Installation

```elixir
def deps do
  [
    {:scry_engine_influxdb, "~> 0.1.0"}
  ]
end
```

## Documentation

Documentation is generated with [ExDoc](https://github.com/elixir-lang/ex_doc):

- Released versions are published to [HexDocs](https://hexdocs.pm) once the
  package ships, at <https://hexdocs.pm/scry_engine_influxdb>.
