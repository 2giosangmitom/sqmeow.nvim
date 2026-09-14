//! The ScyllaDB adapter against a real ScyllaDB server.

/// The server URL, or a note explaining why the test did nothing.
macro_rules! server {
    () => {
        match std::env::var("SQMEOW_TEST_SCYLLA_URL") {
            Ok(url) => url,
            Err(_) => {
                eprintln!("skipped: set SQMEOW_TEST_SCYLLA_URL, or run `just db-up`");
                return;
            }
        }
    };
}

include!("common/scylla_cases.rs");

#[tokio::test]
async fn the_server_really_is_scylla() {
    let backend = connect(&server!()).await;
    // Only ScyllaDB has this table.
    run(&backend, "SELECT version FROM system.versions").await;
}
