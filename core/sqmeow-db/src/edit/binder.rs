//! Tracing result columns back to the tables that store them.

use std::collections::HashSet;

use super::{Source, Table};

/// A table as the catalog names it.
#[derive(Debug, Clone, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub struct TableName {
    pub schema: Option<String>,
    pub name: String,
}

impl TableName {
    pub fn new(schema: Option<&str>, name: &str) -> Self {
        Self {
            schema: schema.map(str::to_owned),
            name: name.to_owned(),
        }
    }

    /// Read `schema.table` or a bare `table`.
    pub fn parse(qualified: &str) -> Self {
        match qualified.rsplit_once('.') {
            Some((schema, name)) => Self::new(Some(schema), name),
            None => Self::new(None, qualified),
        }
    }
}

/// Collects where each result column came from and keeps the tables whose rows can be found again.
///
/// Every SQL adapter feeds it the same way, so which tables are editable is decided in one place.
#[derive(Debug, Default)]
pub struct TableBinder {
    bound: Vec<(usize, TableName, String)>,
    /// Find a table with no whole key in the result by every column it shows.
    every_column: bool,
}

impl TableBinder {
    /// Find a table with no whole key in the result by every column the result shows of it, which
    /// suits only a query whose rows are table rows.
    pub fn every_column(mut self, every_column: bool) -> Self {
        self.every_column = every_column;
        self
    }

    /// Record that result column `column` shows `table`'s column `name`.
    pub fn bind(&mut self, column: usize, table: TableName, name: impl Into<String>) {
        self.bound.push((column, table, name.into()));
    }

    /// The tables with a whole key in the result, or `None` when no table has one. `keys` lists a
    /// table's primary key, then its unique keys, and the first one found in full is used.
    pub fn build(mut self, keys: impl Fn(&TableName) -> Vec<Vec<String>>) -> Option<Source> {
        self.bound.sort_by_key(|(column, ..)| *column);
        let every_column = self.every_column;

        let mut grouped: Vec<(TableName, Vec<(usize, String)>)> = Vec::new();
        for (column, table, name) in self.bound {
            match grouped.iter_mut().find(|(known, _)| *known == table) {
                Some((_, columns)) => columns.push((column, name)),
                None => grouped.push((table, vec![(column, name)])),
            }
        }

        let tables: Vec<Table> = grouped
            .into_iter()
            .filter_map(|(table, columns)| {
                // A table column shown twice is a self-join, whose sides cannot be told apart.
                let mut seen = HashSet::new();
                if !columns.iter().all(|(_, name)| seen.insert(name)) {
                    return None;
                }
                let mut key = keys(&table)
                    .iter()
                    .filter(|key| !key.is_empty())
                    .find_map(|key| {
                        key.iter()
                            .map(|wanted| {
                                columns
                                    .iter()
                                    .find(|(_, name)| name == wanted)
                                    .map(|(at, _)| *at)
                            })
                            .collect::<Option<Vec<usize>>>()
                    })
                    .or_else(|| {
                        every_column.then(|| columns.iter().map(|(at, _)| *at).collect())
                    })?;
                key.sort_unstable();
                Some(Table {
                    schema: table.schema,
                    name: table.name,
                    key,
                    columns,
                })
            })
            .collect();

        (!tables.is_empty()).then_some(Source::Tables(tables))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn keys(table: &TableName) -> Vec<Vec<String>> {
        match table.name.as_str() {
            "people" | "teams" => vec![vec!["id".into()]],
            "badges" => vec![
                vec![],
                vec!["code".into(), "kind".into()],
                vec!["slug".into()],
            ],
            _ => Vec::new(),
        }
    }

    fn tables(source: Option<Source>) -> Vec<Table> {
        match source {
            Some(Source::Tables(tables)) => tables,
            other => panic!("expected tables, got {other:?}"),
        }
    }

    #[test]
    fn each_joined_table_with_its_key_is_editable() {
        let mut binder = TableBinder::default();
        binder.bind(3, TableName::parse("public.teams"), "id");
        binder.bind(0, TableName::parse("public.people"), "id");
        binder.bind(1, TableName::parse("public.people"), "name");
        binder.bind(2, TableName::parse("public.teams"), "name");

        let tables = tables(binder.build(keys));
        assert_eq!(tables.len(), 2);
        assert_eq!(tables[0].qualified(), "public.people");
        assert_eq!(tables[0].key, vec![0]);
        assert_eq!(tables[1].key, vec![3]);
        assert_eq!(tables[1].column(2), Some("name"));
    }

    #[test]
    fn a_table_without_a_primary_key_is_found_by_a_unique_one() {
        let mut binder = TableBinder::default();
        binder.bind(0, TableName::parse("badges"), "slug");
        binder.bind(1, TableName::parse("badges"), "label");
        assert_eq!(tables(binder.build(keys))[0].key, vec![0]);
    }

    #[test]
    fn a_table_without_a_key_is_found_by_every_column_when_asked() {
        let mut binder = TableBinder::default().every_column(true);
        binder.bind(1, TableName::parse("loose"), "v");
        binder.bind(0, TableName::parse("loose"), "w");
        assert_eq!(tables(binder.build(keys))[0].key, vec![0, 1]);
    }

    #[test]
    fn a_table_without_its_key_or_shown_twice_is_left_out() {
        let mut binder = TableBinder::default();
        binder.bind(0, TableName::parse("people"), "id");
        binder.bind(1, TableName::parse("people"), "id");
        binder.bind(2, TableName::parse("teams"), "name");
        binder.bind(3, TableName::parse("loose"), "v");
        assert_eq!(binder.build(keys), None);
    }
}
