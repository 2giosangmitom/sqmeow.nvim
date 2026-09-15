//! The database contract for sqmeow.nvim.

pub mod adapter;
pub mod edit;
pub mod error;
pub mod export;
pub mod guard;
pub mod node;
pub mod result;
pub mod sql;
pub mod types;
pub mod value;
pub mod view;
pub mod width;

pub use adapter::{Adapter, Dialect};
pub use edit::{Changes, RedisKind, Source, Table, TableBinder, TableName};
pub use error::{Error, Result};
pub use export::{Format, Rows};
pub use node::{
    ColumnNode, IndexNode, KeyType, RelationKind, RelationNode, RoutineKind, RoutineNode,
    SchemaNode,
};
pub use result::{Column, ResultSet};
pub use sql::Statement;
pub use types::{ForeignKey, KeyKind, TypeClass};
pub use value::Cell;
