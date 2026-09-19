//! The Redis adapter against a master Redis Sentinel watches.

use sqmeow_adapters::Backend;
use sqmeow_db::{Cell, Changes, KeyType, RelationKind, ResultSet};
use tokio_util::sync::CancellationToken;

/// The server URL, or a note explaining why the test did nothing.
macro_rules! server {
    () => {
        match std::env::var("SQMEOW_TEST_REDIS_SENTINEL_URL") {
            Ok(url) => url,
            Err(_) => {
                eprintln!("skipped: set SQMEOW_TEST_REDIS_SENTINEL_URL, or run `just db-up`");
                return;
            }
        }
    };
}

async fn run(backend: &Backend, command: &str) -> ResultSet {
    backend
        .execute(command, usize::MAX, CancellationToken::new())
        .await
        .unwrap_or_else(|error| panic!("{command} should run: {error}"))
}

#[tokio::test]
async fn every_key_is_read_back_from_where_it_was_written() {
    let backend = Backend::connect(&server!()).await.unwrap();
    assert_eq!(backend.dialect().name(), "redis");
    for index in 0..30 {
        run(
            &backend,
            &format!("SET redis_sentinel:spread:{index} v{index}"),
        )
        .await;
    }
    for index in 0..30 {
        let result = run(&backend, &format!("GET redis_sentinel:spread:{index}")).await;
        assert_eq!(result.cell(0, 0), Some(&Cell::Text(format!("v{index}"))));
    }
}

#[tokio::test]
async fn the_drawer_lists_every_key() {
    let backend = Backend::connect(&server!()).await.unwrap();
    for index in 0..30 {
        run(&backend, &format!("SET redis_sentinel:listed:{index} x")).await;
    }
    let relations = backend.relations("db0").await.unwrap();
    for index in 0..30 {
        let key = format!("redis_sentinel:listed:{index}");
        let found = relations.iter().find(|relation| relation.name == key);
        assert_eq!(
            found.map(|relation| relation.kind),
            Some(RelationKind::Key(KeyType::String)),
            "{key}"
        );
    }
}

#[tokio::test]
async fn a_hash_is_edited_in_place() {
    let backend = Backend::connect(&server!()).await.unwrap();
    run(&backend, "DEL redis_sentinel:hash").await;
    run(&backend, "HSET redis_sentinel:hash name al").await;

    let result = run(&backend, "HGETALL redis_sentinel:hash").await;
    let changes = Changes {
        updates: vec![(0, vec![(1, "bo".into())])],
        ..Changes::default()
    };
    let plan = backend.plan(&result, &changes).unwrap();
    backend
        .apply(&plan, CancellationToken::new())
        .await
        .expect("the plan should apply");

    let after = run(&backend, "HGET redis_sentinel:hash name").await;
    assert_eq!(after.cell(0, 0), Some(&Cell::Text("bo".into())));
}
