//! Provides a msgpack-rpc transport between Neovim and the engine.
//!
//! The engine speaks msgpack-rpc over its standard streams. This crate
//! owns the framing, the dispatch of requests and notifications, and the
//! client used to call the peer.

pub mod client;
pub mod connection;
pub mod error;
pub mod handler;
pub mod message;
pub mod transport;
