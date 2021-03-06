defmodule Ecto.Mnesia.Adapter do
  @moduledoc """
  Core Ecto Mnesia adapter implementation.
  """
  require Logger
  alias :mnesia, as: Mnesia
  alias Ecto.Mnesia.{Record, Table}
  alias Ecto.Mnesia.Record.{Context, Ordering, Update}

  @behaviour Ecto.Adapter

  @required_apps [:mnesia]

  defmacro __before_compile__(_env), do: :ok

  @doc """
  Ensure all applications necessary to run the adapter are started.
  """
  def ensure_all_started(_repo, type) do
    @required_apps
    |> Enum.each(fn app ->
      {:ok, _} = Application.ensure_all_started(app, type)
    end)

    {:ok, @required_apps}
  end

  @doc """
  Returns the childspec that starts the adapter process.
  This method is called from `Ecto.Repo.Supervisor.init/2`.
  """
  def child_spec(_repo, _opts), do: Supervisor.Spec.supervisor(Supervisor, [[], [strategy: :one_for_one]])

  @doc """
  Automatically generate next ID for binary keys, leave sequence keys empty for generation on insert.
  """
  def autogenerate(:id), do: nil
  def autogenerate(:embed_id), do: Ecto.UUID.autogenerate()
  def autogenerate(:binary_id), do: Ecto.UUID.autogenerate()

  @doc """
  Prepares are called by Ecto before `execute/6` methods.
  """
  def prepare(operation, %Ecto.Query{from: {table, schema}, order_bys: order_bys, limit: limit} = query) do
    ordering_fn = order_bys |> Ordering.get_ordering_fn()
    context = table |> Context.new(schema)
    limit = limit |> get_limit()
    {:nocache, {operation, query, limit, context, ordering_fn}}
  end

  @doc """
  Perform `mnesia:select` on prepared query and convert the results to Ecto Schema.
  """
  def execute(_repo, %{sources: {{table, _schema}}, fields: _fields, take: _take},
                      {:nocache, {:all, %Ecto.Query{} = query, limit, context, ordering_fn}},
                      sources, _preprocess, _opts) do
    context = context |> Context.assign_query(query, sources)
    match_spec = Context.get_match_spec(context)
    Logger.debug("Selecting by match specification `#{inspect match_spec}` with limit `#{inspect limit}`")

    result = table
    |> Table.select(match_spec, limit)
    |> Record.to_query_result(context)
    |> ordering_fn.()

    {length(result), result}
  end

  @doc """
  Deletes all records that match Ecto.Query
  """
  def execute(_repo, %{sources: {{table, _schema}}, fields: _fields, take: _take},
                      {:nocache, {:delete_all, %Ecto.Query{} = query, limit, context, ordering_fn}},
                      sources, _preprocess, opts) do
    context = context |> Context.assign_query(query, sources)
    match_spec = Context.get_match_spec(context)
    Logger.debug("Deleting all records by match specification `#{inspect match_spec}` with limit `#{inspect limit}`")

    table = table |> Table.get_name()
    Table.transaction(fn ->
      table
      |> Table.select(match_spec, limit)
      |> Enum.map(fn record ->
        {:ok, _} = Table.delete(table, List.first(record))
        record
      end)
      |> return_all(context, ordering_fn, opts)
    end)
  end

  @doc """
  Update all records by a Ecto.Query.
  """
  def execute(_repo, %{sources: {{table, _schema}}, fields: _fields, take: _take},
                      {:nocache, {:update_all, %Ecto.Query{updates: updates} = query, limit, context, ordering_fn}},
                      sources, _preprocess, opts) do
    context = context |> Context.assign_query(query, sources)
    match_spec = Context.get_match_spec(context)
    Logger.debug("Updating all records by match specification `#{inspect match_spec}` with limit `#{inspect limit}`")

    table = table |> Table.get_name()
    Table.transaction(fn ->
      table
      |> Table.select(match_spec, limit)
      |> Enum.map(fn record ->
        update = record
        |> Update.update_record(updates, sources, context)
        |> List.insert_at(0, table)
        |> List.to_tuple()

        {:ok, result} = Table.update(table, List.first(record), update)
        result
      end)
      |> return_all(context, ordering_fn, opts)
    end)
  end

  # Constructs return for `*_all` methods.
  defp return_all(records, context, ordering_fn, opts) do
    case Keyword.get(opts, :returning) do
      true ->
        result = records
        |> Enum.map(fn record ->
          record |> Tuple.to_list() |> List.delete_at(0)
        end)
        |> Record.to_query_result(context)
        |> ordering_fn.()

        {length(result), result}
      _ ->
        {length(records), nil}
    end
  end

  @doc """
  Insert Ecto Schema struct to Mnesia database.
  """
  def insert(_repo, %{autogenerate_id: autogenerate_id, schema: schema, source: {_, table}}, sources,
             _on_conflict, _returning, _opts) do
    do_insert(table, schema, autogenerate_id, sources)
  end

  @doc """
  Insert all
  """
  # TODO: deal with `opts`: `on_conflict` and `returning`
  def insert_all(_repo, %{autogenerate_id: autogenerate_id, schema: schema, source: {_, table}},
                 _header, rows, _on_conflict, _returning, _opts) do
    table = table |> Table.get_name()
    {count, _rows} = Table.transaction(fn ->
      rows
      |> Enum.reduce({0, []}, fn params, {index, acc} ->
        {:ok, record} = do_insert(table, schema, autogenerate_id, params)
        {index + 1, [record] ++ acc}
      end)
    end)

    {count, nil}
  end

  # Insert schema without primary keys
  defp do_insert(table, schema, nil, params) do
    record = schema |> Record.new(params, table)
    case Table.insert(table, record) do
      {:ok, ^record} ->
        {:ok, params}
      {:error, reason} ->
        {:error, reason}
    end
  end

  # Insert schema with auto-generating primary key value
  defp do_insert(table, schema, {pk_field, _pk_type}, params) do
    params = params |> put_new_pk(pk_field, table)
    record = schema |> Record.new(params, table)
    case Table.insert(table, record) do
      {:ok, ^record} ->
        {:ok, params}
      {:error, :already_exists} ->
        {:invalid, [{:unique, pk_field}]}
      {:error, reason} ->
        {:error, reason}
    end
  end

  # Generate new sequenced primary key for table
  defp put_new_pk(params, pk_field, table) when is_list(params) and is_atom(pk_field) do
    {_, params} = params
    |> Keyword.get_and_update(pk_field, fn
      nil -> {nil, Table.next_id(table)}
      val -> {val, val}
    end)

    params
  end

  @doc """
  Run `fun` inside a Mnesia transaction
  """
  def transaction(_repo, _opts, fun) do
    case Table.transaction(fun) do
      {:error, reason} ->
        {:error, reason}
      result ->
        {:ok, result}
    end
  end

  @doc """
  Returns true when called inside a transaction.
  """
  def in_transaction?(_repo), do: Mnesia.is_transaction()

  @doc """
  Transaction rollbacks is not supported
  """
  def rollback(_repo, _tid), do: Mnesia.abort(:rollback)

  @doc """
  Deletes a record from a Mnesia database.
  """
  def delete(_repo, %{schema: _schema, source: {_, table}, autogenerate_id: autogenerate_id}, filter, _opts) do
    pk = get_pk!(filter, autogenerate_id)
    case Table.delete(table, pk) do
      {:ok, ^pk} -> {:ok, []}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Updates record stored in a Mnesia database.
  """
  def update(_repo, %{schema: schema, source: {_, table}, autogenerate_id: autogenerate_id},
             params, filter, _autogen, _opts) do
    pk = get_pk!(filter, autogenerate_id)

    record = schema
    |> Record.new(params, table)

    case table |> Table.update(pk, record) do
      {:ok, _record} -> {:ok, params}
      error -> error
    end
  end

  # Extract primary key value or raise an error
  defp get_pk!(params, {pk_field, _pk_type}), do: get_pk!(params, pk_field)
  defp get_pk!(params, pk_field) do
    case Keyword.fetch(params, pk_field) do
      :error -> raise Ecto.NoPrimaryKeyValueError
      {:ok, pk} -> pk
    end
  end

  # Extract limit from an `Ecto.Query`
  defp get_limit(nil), do: nil
  defp get_limit(%Ecto.Query.QueryExpr{expr: limit}), do: limit

  # Required methods for Ecto type casing
  def loaders({:embed, _value} = primitive, _type), do: [&Ecto.Adapters.SQL.load_embed(primitive, &1)]
  def loaders(:binary_id, type), do: [Ecto.UUID, type]
  def loaders(primitive, _type), do: [primitive]

  def dumpers({:embed, _value} = primitive, _type), do: [&Ecto.Adapters.SQL.dump_embed(primitive, &1)]
  def dumpers(:binary_id, type), do: [type, Ecto.UUID]
  def dumpers(primitive, _type), do: [primitive]
end
