// Shared helpers for server-backed adapter tests.
//
// Included with `include!("common/harness.rs")`. Each file keeps its own
// cases; only the identical `server!`/`connect`/`run` boilerplate lives here.

use sqmeow_adapters::Backend;
use sqmeow_db::result::ResultSet;
use tokio_util::sync::CancellationToken;

const NO_CAP: usize = usize::MAX;

/// The server URL, or a note explaining why the test did nothing.
macro_rules! server {
    ($var:literal) => {
        match std::env::var($var) {
            Ok(url) => url,
            Err(_) => {
                eprintln!("skipped: set {}, or run `just db-up`", $var);
                return;
            }
        }
    };
}

async fn connect(url: &str) -> Backend {
    Backend::connect(url)
        .await
        .expect("the test server should accept a connection")
}

async fn run(backend: &Backend, sql: &str) -> ResultSet {
    backend
        .execute(sql, NO_CAP, CancellationToken::new())
        .await
        .unwrap_or_else(|error| panic!("{sql} should run: {error}"))
}
