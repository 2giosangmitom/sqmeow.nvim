//! The PostgreSQL adapter against QuestDB, which ignores `default_transaction_read_only`.

use sqmeow_adapters::Backend;
use tokio_util::sync::CancellationToken;

/// The server URL, or a note explaining why the test did nothing.
macro_rules! server {
    () => {
        match std::env::var("SQMEOW_TEST_QUESTDB_URL") {
            Ok(url) => url,
            Err(_) => {
                eprintln!("skipped: set SQMEOW_TEST_QUESTDB_URL, or run `just db-up`");
                return;
            }
        }
    };
}

#[tokio::test]
async fn a_read_only_connection_falls_back_to_the_engine_check() {
    let backend = Backend::connect_to(&server!(), None, true)
        .await
        .expect("a server without read-only sessions should still connect");
    assert!(backend.read_only_unenforced());
    backend
        .execute("select 1", usize::MAX, CancellationToken::new())
        .await
        .expect("queries should still run");
}
