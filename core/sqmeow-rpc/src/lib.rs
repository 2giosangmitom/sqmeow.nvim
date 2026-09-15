//! Provides a msgpack-rpc transport between Neovim and the engine.
//!
//! The engine speaks msgpack-rpc over its standard streams. This crate
//! owns the framing, the dispatch of requests and notifications, and the
//! [`Client`] used to call the peer. A [`Connection`] ties a
//! [`Transport`] to a [`Handler`] implementation.
//!
//! # Examples
//!
//! ```no_run
//! use sqmeow_rpc::{Connection, Handler, Reply};
//! use std::sync::Arc;
//! use rmpv::Value;
//!
//! struct Echo;
//! impl Handler for Echo {
//!     fn on_request(self: Arc<Self>, method: String, _params: Vec<Value>, reply: Reply) {
//!         reply.ok(Value::from(format!("echo {method}")));
//!     }
//! }
//! ```

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
