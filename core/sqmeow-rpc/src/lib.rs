//! msgpack-rpc transport for sqmeow.nvim.

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
