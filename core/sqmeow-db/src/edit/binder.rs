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
}

impl TableBinder {
    /// Record that result column `column` shows `table`'s column `name`.
    pub fn bind(&mut self, column: usize, table: TableName, name: impl Into<String>) {
        self.bound.push((column, table, name.into()));
    }

    /// The tables whose whole primary key is in the result, or `None` when no table is.
    pub fn build(mut self, primary_key: impl Fn(&TableName) -> Vec<String>) -> Option<Source> {
        self.bound.sort_by_key(|(column, ..)| *column);

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
                let primary = primary_key(&table);
                if primary.is_empty() {
                    return None;
                }
                let mut key = primary
                    .iter()
                    .map(|wanted| {
                        columns
                            .iter()
                            .find(|(_, name)| name == wanted)
                            .map(|(at, _)| *at)
                    })
                    .collect::<Option<Vec<usize>>>()?;
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

    fn keys(table: &TableName) -> Vec<String> {
        match table.name.as_str() {
            "people" | "teams" => vec!["id".into()],
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
    fn a_table_without_its_key_or_shown_twice_is_left_out() {
        let mut binder = TableBinder::default();
        binder.bind(0, TableName::parse("people"), "id");
        binder.bind(1, TableName::parse("people"), "id");
        binder.bind(2, TableName::parse("teams"), "name");
        binder.bind(3, TableName::parse("loose"), "v");
        assert_eq!(binder.build(keys), None);
    }
}
