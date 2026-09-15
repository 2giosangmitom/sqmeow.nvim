//! Defines the database contract for sqmeow.nvim.
//!
//! This crate owns the adapter trait, the value and schema types, and the
//! helpers for editing, exporting, and filtering results. Adapters in
//! `sqmeow-adapters` implement [`Adapter`] for each dialect, while the
//! engine in `sqmeow-core` orchestrates calls through that trait.

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
    ColumnNode, Details, ForeignKeyNode, IndexNode, KeyType, RelationKind, RelationNode, RoleNode,
    RoutineKind, RoutineNode, SchemaNode,
};
pub use result::{Column, ResultSet};
pub use sql::Statement;
pub use types::{ForeignKey, KeyKind, TypeClass};
pub use value::Cell;
