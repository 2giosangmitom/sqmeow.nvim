//! msgpack-rpc transport for sqmeow.nvim.
//!
//! Neovim starts the core with `jobstart(cmd, { rpc = true })`, which makes the two processes
//! peers on one msgpack-rpc channel rather than a parent parsing a child's output. Both sides can
//! call the other, so the core reaches the editor's API directly instead of asking Lua to relay.
//!
//! The crate has no database knowledge and no `sqmeow` protocol knowledge, which is what lets the
//! protocol be tested without a database and the database code be tested without an editor.

mod client;
mod connection;
mod error;
mod handler;
mod message;
mod nvim;
mod transport;

pub use client::Client;
pub use connection::Connection;
pub use error::{Error, Result};
pub use handler::{Handler, Reply};
pub use message::Message;
pub use nvim::Nvim;
pub use transport::{Transport, stdio};

pub use rmpv::Value;
