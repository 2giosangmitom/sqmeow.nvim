//! The ScyllaDB adapter against a real Apache Cassandra server.

/// The server URL, or a note explaining why the test did nothing.
macro_rules! server {
    () => {
        match std::env::var("SQMEOW_TEST_CASSANDRA_URL") {
            Ok(url) => url,
            Err(_) => {
                eprintln!("skipped: set SQMEOW_TEST_CASSANDRA_URL, or run `just db-up`");
                return;
            }
        }
    };
}

include!("common/scylla_cases.rs");

#[tokio::test]
async fn the_server_really_is_cassandra() {
    let backend = connect(&server!()).await;
    // ScyllaDB reports 3.0.8 here.
    let result = run(&backend, "SELECT release_version FROM system.local").await;
    let version = result.cell(0, 0).unwrap().text("").into_owned();
    assert!(version.starts_with('5'), "{version}");
}
