//! What the schema drawer shows.
//!
//! One shape for every database, so the drawer draws a tree without knowing which one it is
//! looking at. What differs between dialects is the query that fills these in, not what comes out.

use crate::types::{ForeignKey, KeyKind, TypeClass};

/// What kind of thing a relation is.
///
/// The drawer shows tables and views differently, and the distinction matters when offering
/// actions: a view has no primary key to write back through.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum RelationKind {
    Table,
    View,
    MaterializedView,
    /// Something the server reports that does not fit above, such as a foreign table.
    Other,
}

impl RelationKind {
    /// The name the editor uses for this kind.
    pub fn name(self) -> &'static str {
        match self {
            Self::Table => "table",
            Self::View => "view",
            Self::MaterializedView => "materialized view",
            Self::Other => "relation",
        }
    }
}

/// What kind of routine a schema holds.
///
/// A function returns a value and a procedure is called for its effect. Which of the two something
/// is decides nothing the plugin does with it yet, but the drawer groups them apart because that
/// is how every database's own tooling presents them.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum RoutineKind {
    Function,
    Procedure,
}

impl RoutineKind {
    /// The name the editor uses for this kind.
    pub fn name(self) -> &'static str {
        match self {
            Self::Function => "function",
            Self::Procedure => "procedure",
        }
    }
}

/// A stored function or procedure.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RoutineNode {
    pub name: String,
    pub kind: RoutineKind,
}

/// A schema, or for MySQL a database.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SchemaNode {
    pub name: String,
    /// Whether this is the one unqualified names resolve to.
    ///
    /// The drawer expands it first, because it is almost always the one the user wants.
    pub is_default: bool,
}

/// A table or a view.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RelationNode {
    pub name: String,
    pub kind: RelationKind,
}

/// A relation together with the schema holding it.
///
/// The drawer walks the tree one level at a time, but the relation picker searches a whole
/// connection at once, so it needs the schema name alongside each relation rather than implied by
/// where the node sits.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct CatalogEntry {
    pub schema: String,
    pub name: String,
    pub kind: RelationKind,
}

/// One column of a relation.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ColumnNode {
    pub name: String,
    /// The database's own type name, as written in the schema.
    pub type_name: String,
    pub nullable: bool,
    pub primary_key: bool,
    /// What this column points at, when it points at anything.
    pub foreign_key: Option<ForeignKey>,
}

impl ColumnNode {
    /// What kind of value this column holds, for the icon the drawer draws beside it.
    pub fn class(&self) -> TypeClass {
        TypeClass::from_type_name(&self.type_name)
    }

    /// Which key this column is, preferring the primary one.
    ///
    /// A column can be both: the child half of a composite primary key is often a foreign key as
    /// well. The primary key wins, because it is the stronger statement about the row.
    pub fn key(&self) -> KeyKind {
        if self.primary_key {
            KeyKind::Primary
        } else if self.foreign_key.is_some() {
            KeyKind::Foreign
        } else {
            KeyKind::None
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn column(type_name: &str) -> ColumnNode {
        ColumnNode {
            name: "x".into(),
            type_name: type_name.into(),
            nullable: true,
            primary_key: false,
            foreign_key: None,
        }
    }

    #[test]
    fn a_column_classifies_by_its_declared_type() {
        assert_eq!(column("character varying(10)").class(), TypeClass::Text);
        assert_eq!(column("bigint").class(), TypeClass::Number);
    }

    #[test]
    fn a_column_with_no_key_is_not_one() {
        assert_eq!(column("int4").key(), KeyKind::None);
    }

    #[test]
    fn the_primary_key_wins_over_a_foreign_one() {
        // The child half of a composite primary key is often a foreign key as well, and the
        // primary key is the stronger statement about the row.
        let mut both = column("int4");
        both.primary_key = true;
        both.foreign_key = Some(ForeignKey {
            table: "authors".into(),
            column: "id".into(),
        });
        assert_eq!(both.key(), KeyKind::Primary);

        both.primary_key = false;
        assert_eq!(both.key(), KeyKind::Foreign);
    }

    #[test]
    fn relation_kinds_have_names_for_the_interface() {
        assert_eq!(RelationKind::Table.name(), "table");
        assert_eq!(RelationKind::View.name(), "view");
        assert_eq!(RelationKind::MaterializedView.name(), "materialized view");
        assert_eq!(RelationKind::Other.name(), "relation");
    }
}
