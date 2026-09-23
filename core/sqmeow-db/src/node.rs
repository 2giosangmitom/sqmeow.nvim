//! Defines nodes rendered by the schema drawer.

use crate::types::{ForeignKey, KeyKind, TypeClass};

/// What kind of thing a relation is.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum RelationKind {
    Table,
    View,
    MaterializedView,
    Sequence,
    /// Something the server reports that does not fit above, such as a foreign table.
    Other,
    /// A Redis key, by the type of value it holds.
    Key(KeyType),
}

impl RelationKind {
    /// The name the editor uses for this kind.
    pub fn name(self) -> &'static str {
        match self {
            Self::Table => "table",
            Self::View => "view",
            Self::MaterializedView => "materialized view",
            Self::Sequence => "sequence",
            Self::Other => "relation",
            Self::Key(_) => "key",
        }
    }
}

/// What a Redis key holds.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum KeyType {
    String,
    Hash,
    List,
    Set,
    SortedSet,
    Stream,
    /// A JSON document, which Redis 8 and Dragonfly both have built in.
    Json,
}

impl KeyType {
    /// Every type, in the order the drawer lists their groups.
    pub const ALL: [Self; 7] = [
        Self::String,
        Self::Hash,
        Self::List,
        Self::Set,
        Self::SortedSet,
        Self::Stream,
        Self::Json,
    ];

    /// Read the answer `TYPE` gives.
    pub fn from_redis(name: &str) -> Option<Self> {
        match name {
            "string" => Some(Self::String),
            "hash" => Some(Self::Hash),
            "list" => Some(Self::List),
            "set" => Some(Self::Set),
            "zset" => Some(Self::SortedSet),
            "stream" => Some(Self::Stream),
            // The name the RedisJSON module gave it, which Redis 8 and Dragonfly both kept.
            "ReJSON-RL" => Some(Self::Json),
            _ => None,
        }
    }

    /// The drawer group's key, which the plugin matches on, and the label it draws.
    pub fn group(self) -> (&'static str, &'static str) {
        match self {
            Self::String => ("strings", "Strings"),
            Self::Hash => ("hashes", "Hashes"),
            Self::List => ("lists", "Lists"),
            Self::Set => ("sets", "Sets"),
            Self::SortedSet => ("sorted_sets", "Sorted sets"),
            Self::Stream => ("streams", "Streams"),
            Self::Json => ("json", "JSON"),
        }
    }
}

/// What kind of routine a schema holds.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum RoutineKind {
    Function,
    Procedure,
    /// A packaged unit: Oracle packages, holding procedures and functions.
    Package,
}

impl RoutineKind {
    /// The name the editor uses for this kind.
    pub fn name(self) -> &'static str {
        match self {
            Self::Function => "function",
            Self::Procedure => "procedure",
            Self::Package => "package",
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
    pub is_default: bool,
}

/// A table or a view.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RelationNode {
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
    /// The default as the schema writes it.
    pub default: Option<String>,
}

/// A role or user a server knows, with what it is allowed.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RoleNode {
    pub name: String,
    pub attributes: Vec<String>,
}

/// A foreign key: `columns` hold values of `referenced` in `target`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ForeignKeyNode {
    pub name: String,
    pub columns: Vec<String>,
    pub target: String,
    pub referenced: Vec<String>,
}

/// What the structure view shows of a relation besides its columns and indexes.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct Details {
    /// Facts about it, such as its comment or a Redis key's TTL.
    pub properties: Vec<(String, String)>,
    /// Comments on its columns, by column name.
    pub column_comments: Vec<(String, String)>,
    pub foreign_keys: Vec<ForeignKeyNode>,
    /// Check constraints, each a name and its expression.
    pub checks: Vec<(String, String)>,
    /// Triggers, each a name and what fires it.
    pub triggers: Vec<(String, String)>,
    /// The statement that creates it, or a MongoDB collection's validator.
    pub definition: Option<String>,
}

/// An index or a unique constraint on a table.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct IndexNode {
    pub name: String,
    /// Its columns in order, or the expressions it is on.
    pub columns: Vec<String>,
    pub unique: bool,
    pub primary: bool,
}

impl ColumnNode {
    /// What kind of value this column holds, for the icon the drawer draws beside it.
    pub fn class(&self) -> TypeClass {
        TypeClass::from_type_name(&self.type_name)
    }

    /// Which key this column is, preferring the primary one.
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
            default: None,
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
        // The child half of a composite primary key is often a foreign key as well, and the primary
        // key is the stronger statement about the row.
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
        assert_eq!(RelationKind::Key(KeyType::Hash).name(), "key");
    }

    #[test]
    fn routine_kinds_have_names_for_the_interface() {
        assert_eq!(RoutineKind::Function.name(), "function");
        assert_eq!(RoutineKind::Procedure.name(), "procedure");
        assert_eq!(RoutineKind::Package.name(), "package");
    }

    #[test]
    fn redis_types_are_read_and_grouped() {
        assert_eq!(KeyType::from_redis("zset"), Some(KeyType::SortedSet));
        assert_eq!(KeyType::from_redis("none"), None);
        assert_eq!(KeyType::from_redis("ReJSON-RL"), Some(KeyType::Json));
        assert_eq!(KeyType::from_redis("MBbloom--"), None);

        let mut groups: Vec<&str> = KeyType::ALL.iter().map(|kind| kind.group().0).collect();
        groups.dedup();
        assert_eq!(
            groups.len(),
            KeyType::ALL.len(),
            "each type has a group of its own"
        );
    }
}
