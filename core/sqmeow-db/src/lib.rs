//! The database contract for sqmeow.nvim.
//!
//! This crate knows nothing about the editor and nothing about any particular driver. It defines
//! the shape every adapter meets, the one value type every driver decodes into, and the result set
//! the renderer reads. Adding a database means implementing [`Adapter`], not touching anything
//! downstream of it.

pub mod adapter;
pub mod error;
pub mod result;
pub mod sql;
pub mod value;

pub use adapter::{Adapter, Dialect};
pub use error::{Error, Result};
pub use result::{Column, ResultSet};
pub use sql::Statement;
pub use value::Cell;
