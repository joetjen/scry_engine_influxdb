defmodule Scry.Engine.InfluxDB.Conn do
  @moduledoc """
  Wraps the base URL, database name, and optional credentials of a
  reachable InfluxDB 1.x server -- no actual connection exists to open
  at all, unlike most other adapters in this family: InfluxDB's own
  classic HTTP API (`/query`, `/write`) is plain, stateless JSON-over-
  HTTP, the identical shape `Scry.Engine.Elasticsearch.Conn`/`Scry.
  Engine.CouchDB.Conn`/`Scry.Engine.Loki.Conn` already document. Unlike
  Loki/CouchDB, `auth` is genuinely optional here -- confirmed directly,
  a stock local InfluxDB 1.8 container accepts unauthenticated requests
  by default (no admin user created), the same posture `scry_engine_
  elasticsearch`'s own stock, security-disabled container has.

  `database` is fixed once, at `open/1` time, not per-query -- the same
  "one primary scope, set at connection time" convention `scry_engine_
  couchdb`'s own database-per-tree-key model set per *query* differs
  from deliberately: InfluxDB's own measurement/database split maps
  cleanly onto Scry's `source` (a measurement) living inside one fixed
  database, the same relationship a SQL table has to its own schema.

  ## A real, confirmed error-reporting quirk

  InfluxDB 1.x's own `/query` endpoint reports two structurally
  different kinds of failure, both needing to be checked, neither
  reducible to "just look at the HTTP status": a genuine parse error
  (bad InfluxQL syntax) returns a real `4xx` with a top-level `{"error":
  "..."}"` body, but a *semantic* error against an otherwise
  syntactically valid query (`"database not found: ..."`, confirmed
  directly querying a nonexistent database) comes back as an ordinary
  `200 OK` with the error embedded *inside* `results[0]["error"]`
  instead -- `query/3` checks both shapes explicitly.
  """

  @type t :: %__MODULE__{
          base_url: String.t(),
          database: String.t(),
          auth: {String.t(), String.t()} | nil
        }

  @enforce_keys [:database]
  defstruct base_url: "http://localhost:8086", database: nil, auth: nil

  @doc """
  Wraps `base_url` (default `"http://localhost:8086"`, a stock local
  InfluxDB 1.8 container), a required `database:` name, and an optional
  `auth: {username, password}` pair.
  """
  @spec open(keyword()) :: {:ok, t()}
  def open(opts) do
    base_url =
      opts |> Keyword.get(:base_url, "http://localhost:8086") |> String.trim_trailing("/")

    database = Keyword.fetch!(opts, :database)
    auth = Keyword.get(opts, :auth)
    {:ok, %__MODULE__{base_url: base_url, database: database, auth: auth}}
  end

  @doc """
  Runs `influxql` (with `$name`-style bound parameters, `bind_params`
  their real values -- InfluxDB's own native parameter-binding feature,
  confirmed directly, not manual string interpolation) against
  `/query`, always requesting `epoch=ns` (Unix-nanosecond timestamps,
  confirmed the cleanest native precision -- the default ISO-8601
  string form would need parsing back into a `DateTime.t()` for no
  benefit). Returns the first (and, for every query this package ever
  generates, only) statement's own result map directly.
  """
  @spec query(t(), String.t(), map()) :: {:ok, map()} | {:error, {:query_error, term()}}
  def query(
        %__MODULE__{base_url: base_url, database: database, auth: auth},
        influxql,
        bind_params \\ %{}
      ) do
    query_params =
      [db: database, epoch: "ns", q: influxql] ++ maybe_bind_params(bind_params)

    req_opts = [params: query_params] ++ maybe_auth(auth)

    case Req.get(base_url <> "/query", req_opts) do
      {:ok, %Req.Response{status: 200, body: %{"results" => [%{"error" => reason} | _]}}} ->
        {:error, {:query_error, reason}}

      {:ok, %Req.Response{status: 200, body: %{"results" => [result | _]}}} ->
        {:ok, result}

      {:ok, %Req.Response{body: %{"error" => reason}}} ->
        {:error, {:query_error, reason}}

      {:ok, %Req.Response{body: body}} ->
        {:error, {:query_error, body}}

      {:error, reason} ->
        {:error, {:query_error, reason}}
    end
  end

  @doc "Writes `line_protocol` (one or more newline-separated Line Protocol entries) to `/write` -- test/fixture use only, never called from `execute/3` itself."
  @spec write(t(), String.t()) :: :ok | {:error, {:query_error, term()}}
  def write(%__MODULE__{base_url: base_url, database: database, auth: auth}, line_protocol) do
    req_opts = [params: [db: database], body: line_protocol] ++ maybe_auth(auth)

    case Req.post(base_url <> "/write", req_opts) do
      {:ok, %Req.Response{status: 204}} -> :ok
      {:ok, %Req.Response{body: body}} -> {:error, {:query_error, body}}
      {:error, reason} -> {:error, {:query_error, reason}}
    end
  end

  defp maybe_bind_params(bind_params) when map_size(bind_params) == 0, do: []
  defp maybe_bind_params(bind_params), do: [params: Jason.encode!(bind_params)]

  defp maybe_auth(nil), do: []
  defp maybe_auth({username, password}), do: [auth: {:basic, username <> ":" <> password}]
end
