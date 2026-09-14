//! What the sqlx adapters share.

use std::collections::HashMap;
use std::future::Future;
use std::sync::Mutex;
use std::time::Instant;

use futures_util::{Stream, StreamExt};
use sqlx::{
    AssertSqlSafe, ColumnIndex, Database, Decode, Either, Executor, Pool, Row, SqlSafeStr, Type,
    TypeInfo,
};
use sqmeow_db::{
    Cell, Column, Error, ForeignKey, KeyKind, Result, ResultSet, Source, TableBinder, TableName,
};
use tokio_util::sync::CancellationToken;

/// Where a result column came from: its table, and its name in that table.
pub(crate) type Origin = Option<(TableName, String)>;

/// Prepare a statement to learn what its result looks like, before running it.
pub(crate) async fn prepare<DB>(pool: &Pool<DB>, statement: &str) -> Option<DB::Statement>
where
    DB: Database,
    for<'c> &'c mut DB::Connection: Executor<'c, Database = DB>,
{
    let sql = AssertSqlSafe(statement.to_owned()).into_sql_str();
    match pool.prepare(sql).await {
        Ok(prepared) => Some(prepared),
        Err(error) => {
            tracing::debug!(%error, "could not prepare a statement to read its columns");
            None
        }
    }
}

/// A prepared statement's result columns, classified by the type the driver names.
pub(crate) fn result_columns<C: sqlx::Column>(prepared: &[C]) -> Vec<Column> {
    prepared
        .iter()
        .map(|column| Column::new(column.name(), column.type_info().name()))
        .collect()
}

/// The table column each result column came from, for a driver that says.
pub(crate) fn origins<C: sqlx::Column>(prepared: &[C]) -> Vec<Origin> {
    prepared
        .iter()
        .map(|column| {
            let origin = column.origin();
            let origin = origin.table_column()?;
            // MySQL names the table with its schema when it knows one.
            Some((TableName::parse(&origin.table), origin.name.to_string()))
        })
        .collect()
}

/// What each sqlx adapter supplies to the shared query flow in [`run`].
pub(crate) trait SqlxAdapter: Sync {
    type Db: Database;

    fn pool(&self) -> &Pool<Self::Db>;

    /// A statement's columns and where its rows are stored, read before it runs.
    fn describe(
        &self,
        statement: &str,
    ) -> impl Future<Output = (Vec<Column>, Option<Source>)> + Send;

    fn decode(row: &<Self::Db as Database>::Row, index: usize) -> Cell;

    fn affected(outcome: &<Self::Db as Database>::QueryResult) -> u64;

    /// Stop a cancelled query on the server.
    fn stop_running(&self) -> impl Future<Output = ()> + Send {
        async {}
    }

    /// Forget the tables read so far.
    fn forget(&self);
}

/// Run and read one statement through an adapter, describing it through `origin`, the query it
/// wraps or itself.
pub(crate) async fn run<A: SqlxAdapter>(
    adapter: &A,
    statement: &str,
    origin: &str,
    max_rows: usize,
    cancel: &CancellationToken,
) -> Result<ResultSet>
where
    for<'c> &'c mut <A::Db as Database>::Connection: Executor<'c, Database = A::Db>,
{
    let (columns, source) = adapter.describe(origin).await;
    let outcome = execute(
        adapter.pool(),
        statement,
        columns,
        max_rows,
        cancel,
        A::affected,
        A::decode,
    )
    .await;
    if matches!(outcome, Err(Error::Cancelled)) {
        adapter.stop_running().await;
    }
    if may_change_schema(statement) {
        adapter.forget();
    }
    let mut result = outcome?;
    result.set_source(source);
    Ok(result)
}

/// Run one statement and read what it produced into a result set.
async fn execute<DB>(
    pool: &Pool<DB>,
    statement: &str,
    columns: Vec<Column>,
    max_rows: usize,
    cancel: &CancellationToken,
    affected: impl Fn(&DB::QueryResult) -> u64,
    decode: impl Fn(&DB::Row, usize) -> Cell,
) -> Result<ResultSet>
where
    DB: Database,
    for<'c> &'c mut DB::Connection: Executor<'c, Database = DB>,
{
    let started = Instant::now();
    let width = columns.len();
    let mut result = ResultSet::new(statement, columns);

    // The SQL is whatever the user typed into their own editor, against their own database.
    let stream = sqlx::raw_sql(AssertSqlSafe(statement.to_owned())).fetch_many(pool);

    drain(
        stream,
        &mut result,
        max_rows,
        cancel,
        affected,
        |row| result_columns(row.columns()),
        |row| {
            // A row can be wider than preparing predicted.
            (0..width.max(row.len()))
                .map(|index| decode(row, index))
                .collect()
        },
    )
    .await?;

    result.set_elapsed(started.elapsed());
    Ok(result)
}

/// Read a query's output into a result set.
async fn drain<S, Q, R>(
    mut stream: S,
    result: &mut ResultSet,
    max_rows: usize,
    cancel: &CancellationToken,
    affected: impl Fn(&Q) -> u64,
    describe: impl Fn(&R) -> Vec<Column>,
    decode: impl Fn(&R) -> Vec<Cell>,
) -> Result<()>
where
    S: Stream<Item = std::result::Result<Either<Q, R>, sqlx::Error>> + Unpin,
{
    loop {
        tokio::select! {
            // Cancellation wins a tie.
            biased;

            () = cancel.cancelled() => return Err(Error::Cancelled),

            item = stream.next() => match item {
                None => return Ok(()),
                Some(Err(error)) => return Err(Error::driver(error)),
                Some(Ok(Either::Left(outcome))) => result.set_affected(affected(&outcome)),
                Some(Ok(Either::Right(row))) => {
                    // A statement that would not prepare arrives with no columns, and the first row
                    // is the first thing to say what they are.
                    if result.columns().is_empty() {
                        result.adopt_columns(describe(&row));
                    }
                    if result.row_count() >= max_rows {
                        // Stopping here drops the stream, which tells the server to stop sending.
                        result.mark_truncated();
                        return Ok(());
                    }
                    result.push_row(decode(&row));
                }
            },
        }
    }
}

/// Run statements in one transaction, rolling all of them back when any fails.
pub(crate) async fn transact<DB>(
    pool: &Pool<DB>,
    statements: &[String],
    affected: impl Fn(&DB::QueryResult) -> u64,
) -> Result<()>
where
    DB: Database,
    for<'c> &'c mut DB::Connection: Executor<'c, Database = DB>,
{
    let mut transaction = pool.begin().await.map_err(Error::driver)?;
    for statement in statements {
        let outcome = sqlx::raw_sql(AssertSqlSafe(statement.clone()))
            .execute(&mut *transaction)
            .await
            .map_err(|error| Error::driver(format!("{error}\nin: {statement}")))?;
        check_affected(statement, affected(&outcome))?;
    }
    transaction.commit().await.map_err(Error::driver)
}

/// Refuse a planned `UPDATE` or `DELETE` that found no row.
pub(crate) fn check_affected(statement: &str, affected: u64) -> Result<()> {
    // The planner spells these in capitals; a statement it did not write is not checked.
    if (statement.starts_with("UPDATE ") || statement.starts_with("DELETE ")) && affected == 0 {
        return Err(Error::driver(format!(
            "no row had that key any more, so nothing was changed\nin: {statement}"
        )));
    }
    Ok(())
}

/// Whether a statement may have changed a table an adapter holds a picture of.
pub(crate) fn may_change_schema(statement: &str) -> bool {
    !matches!(
        sqmeow_db::sql::first_word(statement).as_str(),
        "select"
            | "with"
            | "values"
            | "table"
            | "show"
            | "explain"
            | "describe"
            | "desc"
            | "insert"
            | "update"
            | "delete"
            | "replace"
            | "merge"
            | "set"
    )
}

/// Last resort for a value no decoder claimed.
pub(crate) fn text_or_bytes<'r, R>(row: &'r R, index: usize, type_name: &str) -> Cell
where
    R: Row,
    usize: ColumnIndex<R>,
    String: Decode<'r, R::Database> + Type<R::Database>,
    Vec<u8>: Decode<'r, R::Database> + Type<R::Database>,
{
    if let Ok(text) = row.try_get::<String, _>(index) {
        return Cell::Text(text);
    }
    if let Ok(bytes) = row.try_get::<Vec<u8>, _>(index) {
        return Cell::bytes(&bytes);
    }
    Cell::Unsupported {
        type_name: type_name.to_owned(),
        raw: String::new(),
    }
}

/// What a drawer column's foreign key points at, read from `references_table` and
/// `references_column`, if it has one.
pub(crate) fn foreign_key<'r, R>(row: &'r R) -> Option<ForeignKey>
where
    R: Row,
    &'static str: ColumnIndex<R>,
    String: Decode<'r, R::Database> + Type<R::Database>,
{
    Some(ForeignKey {
        table: row
            .try_get::<Option<String>, _>("references_table")
            .ok()??,
        column: row
            .try_get::<Option<String>, _>("references_column")
            .ok()??,
    })
}

/// Which columns of each table are keys, by table name and then column name.
#[derive(Debug, Default)]
pub(crate) struct TableKeys(Mutex<HashMap<TableName, HashMap<String, KeyKind>>>);

impl TableKeys {
    /// Forget every table, so each is read again the next time a result comes from it.
    pub(crate) fn forget(&self) {
        if let Ok(mut known) = self.0.lock() {
            known.clear();
        }
    }

    /// Mark the result columns that are keys in the table they came from, reading each table not
    /// seen before with `read`.
    pub(crate) async fn mark<F, Fut>(&self, origins: &[Origin], columns: &mut [Column], read: F)
    where
        F: Fn(TableName) -> Fut,
        Fut: Future<Output = HashMap<String, KeyKind>>,
    {
        let missing: Vec<TableName> = {
            let Ok(known) = self.0.lock() else {
                return;
            };
            let mut missing: Vec<TableName> = origins
                .iter()
                .flatten()
                .map(|(table, _)| table.clone())
                .filter(|table| !known.contains_key(table))
                .collect();
            missing.sort_unstable();
            missing.dedup();
            missing
        };

        for table in missing {
            let found = read(table.clone()).await;
            if let Ok(mut known) = self.0.lock() {
                known.insert(table, found);
            }
        }

        let Ok(known) = self.0.lock() else {
            return;
        };
        for (column, origin) in columns.iter_mut().zip(origins) {
            if let Some(kind) = origin
                .as_ref()
                .and_then(|(table, name)| known.get(table)?.get(name))
            {
                column.key = *kind;
            }
        }
    }

    /// Where a result's rows are stored, from the tables read so far.
    pub(crate) fn source(&self, origins: &[Origin]) -> Option<Source> {
        let known = self.0.lock().ok()?;
        let mut binder = TableBinder::default();
        for (column, origin) in origins.iter().enumerate() {
            if let Some((table, name)) = origin {
                binder.bind(column, table.clone(), name.clone());
            }
        }
        binder.build(|table| {
            known.get(table).map_or_else(Vec::new, |keys| {
                keys.iter()
                    .filter(|(_, kind)| **kind == KeyKind::Primary)
                    .map(|(name, _)| name.clone())
                    .collect()
            })
        })
    }
}

#[cfg(test)]
mod tests {
    use super::may_change_schema;

    #[test]
    fn only_statements_that_read_or_write_rows_keep_the_schema() {
        for statement in [
            "select 1",
            "  WITH x AS (select 1) select * from x",
            "-- a note\nupdate t set a = 1",
            "/* a note */ insert into t values (1)",
            "show tables",
        ] {
            assert!(!may_change_schema(statement), "{statement}");
        }
        for statement in [
            "alter table t add column c int",
            "DROP TABLE t",
            "create index i on t (a)",
            "rollback",
            "do $$ begin end $$",
            "call p()",
            "-- only a note",
        ] {
            assert!(may_change_schema(statement), "{statement}");
        }
    }
}
