//! Laying out sqmeow.nvim result sets.
//!
//! Knows about result sets and about terminal columns, and nothing about databases or the editor.
//! That is what lets grid layout be tested against fixture data with no server and no Neovim.

pub mod grid;
pub mod width;

pub use grid::{GridOptions, GridStyle, Layout};
