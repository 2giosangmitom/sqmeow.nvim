//! The sqmeow.nvim database engine.

mod archive;
mod args;
mod core;
mod session;
mod template;
mod tunnel;
mod value;

use std::sync::Arc;

use sqmeow_rpc::{Connection, Nvim};
use tracing_subscriber::EnvFilter;

use crate::core::Core;

fn main() -> std::process::ExitCode {
    // `--version` lets the installer check a binary it did not download, without the cost and the
    // side effects of opening a channel to it.
    if std::env::args().any(|arg| arg == "--version" || arg == "-V") {
        println!("sqmeow-core {}", env!("CARGO_PKG_VERSION"));
        return std::process::ExitCode::SUCCESS;
    }

    init_tracing();

    let runtime = match tokio::runtime::Builder::new_multi_thread()
        .enable_all()
        .build()
    {
        Ok(runtime) => runtime,
        Err(error) => {
            eprintln!("sqmeow-core: could not start the async runtime: {error}");
            return std::process::ExitCode::FAILURE;
        }
    };

    runtime.block_on(serve());
    tracing::info!("sqmeow-core stopped");
    std::process::ExitCode::SUCCESS
}

async fn serve() {
    let connection = Connection::stdio();
    let core = Arc::new(Core::new(Nvim::new(connection.client())));
    let shutdown = core.shutdown_signal();

    tracing::info!(version = env!("CARGO_PKG_VERSION"), "sqmeow-core started");

    tokio::select! {
        // The editor closed the channel, which is the usual way a session ends.
        () = connection.serve(Arc::clone(&core)) => tracing::debug!("channel closed"),
        // The plugin asked to stop, so the editor is still there and expects us to exit.
        () = shutdown.notified() => tracing::debug!("shutdown requested"),
    }
}

fn init_tracing() {
    let filter = EnvFilter::try_from_env("SQMEOW_LOG").unwrap_or_else(|_| EnvFilter::new("warn"));
    tracing_subscriber::fmt()
        // stdout belongs to the protocol.
        .with_writer(std::io::stderr)
        // The editor shows stderr as plain text.
        .with_ansi(false)
        .with_env_filter(filter)
        .with_target(false)
        .init();
}
