//! The Redis adapter against a real Redis server.

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
