//! Driver-independent result provenance and transaction-safety helpers.

use std::collections::HashMap;
use std::future::Future;
use std::sync::Mutex;

use sqmeow_db::edit::{Source, TableBinder, TableName};
use sqmeow_db::error::{Error, Result};
use sqmeow_db::result::Column;
use sqmeow_db::sql::Sides;
use sqmeow_db::types::KeyKind;

/// Where a result column came from: its table, and its name in that table.
pub(crate) type Origin = Option<(TableName, String)>;

/// A statement's failure, after its transaction was rolled back.
pub(crate) fn rolled_back(error: impl std::fmt::Display) -> Error {
    Error::driver(format!("nothing was applied: {error}"))
}

/// Refuse a planned `UPDATE` or `DELETE` that did not change exactly one row.
pub(crate) fn check_affected(statement: &str, affected: u64) -> Result<()> {
    if !matches!(
        sqmeow_db::sql::first_word(statement).as_str(),
        "update" | "delete"
    ) {
        return Ok(());
    }
    match affected {
        1 => Ok(()),
        0 => Err(Error::driver(format!(
            "no row had that key any more, so nothing was changed\nin: {statement}"
        ))),
        many => Err(Error::driver(format!(
            "{many} rows matched where one was meant, so nothing was changed\nin: {statement}"
        ))),
    }
}

/// Whether a statement may have changed a table an adapter holds a picture of.
pub(crate) fn may_change_schema(statement: &str) -> bool {
    if sqmeow_db::sql::first_word(statement).is_empty() {
        return false;
    }
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

/// Which columns of one table are keys.
#[derive(Debug, Default)]
pub(crate) struct Keys {
    pub(crate) kinds: HashMap<String, KeyKind>,
    pub(crate) unique: Vec<Vec<String>>,
    pub(crate) generated: Vec<String>,
}

/// Which columns of each table are keys, by table name.
#[derive(Debug, Default)]
pub(crate) struct TableKeys(Mutex<HashMap<TableName, Keys>>);

impl TableKeys {
    pub(crate) fn forget(&self) {
        if let Ok(mut known) = self.0.lock() {
            known.clear();
        }
    }

    /// Mark result columns, reading metadata only for tables not yet cached.
    pub(crate) async fn mark<F, Fut>(&self, origins: &[Origin], columns: &mut [Column], read: F)
    where
        F: Fn(TableName) -> Fut,
        Fut: Future<Output = Keys>,
    {
        let missing: Vec<TableName> = {
            let Ok(known) = self.0.lock() else { return };
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
        let Ok(known) = self.0.lock() else { return };
        for (column, origin) in columns.iter_mut().zip(origins) {
            if let Some(kind) = origin
                .as_ref()
                .and_then(|(table, name)| known.get(table)?.kinds.get(name))
            {
                column.key = *kind;
            }
            column.generated = origin.as_ref().is_some_and(|(table, name)| {
                known
                    .get(table)
                    .is_some_and(|keys| keys.generated.contains(name))
            });
        }
    }

    /// Bind writable results using primary/unique keys and self-join sides.
    pub(crate) fn source(&self, origins: &[Origin], plain: bool, sides: Sides) -> Option<Source> {
        let known = self.0.lock().ok()?;
        let mut binder = TableBinder::default().every_column(plain).sides(sides);
        for (column, origin) in origins.iter().enumerate() {
            if let Some((table, name)) = origin {
                binder.bind(column, table.clone(), name.clone());
            }
        }
        binder.build(|table| {
            known.get(table).map_or_else(Vec::new, |keys| {
                let primary = keys
                    .kinds
                    .iter()
                    .filter(|(_, kind)| **kind == KeyKind::Primary)
                    .map(|(name, _)| name.clone())
                    .collect();
                std::iter::once(primary)
                    .chain(keys.unique.iter().cloned())
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
