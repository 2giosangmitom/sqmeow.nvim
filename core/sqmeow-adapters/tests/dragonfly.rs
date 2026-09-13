//! The Redis adapter against a real Dragonfly server.
//!
//! Needs a server. `just db-up` starts one and `just test-rust` passes its URL in. Without
//! `SQMEOW_TEST_DRAGONFLY_URL` these tests report that they were skipped rather than failing, so
//! `cargo test` still works on a machine with no Docker.

/// The server URL, or a note explaining why the test did nothing.
macro_rules! server {
    () => {
        match std::env::var("SQMEOW_TEST_DRAGONFLY_URL") {
            Ok(url) => url,
            Err(_) => {
                eprintln!("skipped: set SQMEOW_TEST_DRAGONFLY_URL, or run `just db-up`");
                return;
            }
        }
    };
}

include!("common/redis_cases.rs");

#[tokio::test]
async fn the_server_really_is_dragonfly() {
    // Otherwise a URL pointed at a Redis server would pass every case above and prove nothing.
    let backend = connect(&server!()).await;
    let info = run(&backend, "INFO server").await;
    let text = info
        .cell(0, 0)
        .map(|cell| cell.text("").into_owned())
        .unwrap_or_default();
    assert!(text.contains("dragonfly_version"), "{text}");
}
