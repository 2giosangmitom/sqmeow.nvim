//! MessagePack-RPC transport between Neovim and the engine: framing,
//! request/notification dispatch, and the client used to call the peer.

pub mod client;
pub mod connection;
pub mod error;
pub mod handler;
pub mod message;
pub mod transport;
