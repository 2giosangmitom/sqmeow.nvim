//! The Redis adapter against a real Redis server.
//!
//! Needs a server. `just db-up` starts one and `just test-rust` passes its URL in. Without
//! `SQMEOW_TEST_REDIS_URL` these tests report that they were skipped rather than failing, so
//! `cargo test` still works on a machine with no Docker.

/// The server URL, or a note explaining why the test did nothing.
macro_rules! server {
    () => {
        match std::env::var("SQMEOW_TEST_REDIS_URL") {
            Ok(url) => url,
            Err(_) => {
                eprintln!("skipped: set SQMEOW_TEST_REDIS_URL, or run `just db-up`");
                return;
            }
        }
    };
}

include!("common/redis_cases.rs");
