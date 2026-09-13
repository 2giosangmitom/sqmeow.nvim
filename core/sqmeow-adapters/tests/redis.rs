//! The Redis adapter against a real server.
//!
//! Needs a server. `just db-up` starts one and `just test-rust` passes its URL in. Without
//! `SQMEOW_TEST_REDIS_URL` these tests report that they were skipped rather than failing, so
//! `cargo test` still works on a machine with no Docker.

use sqmeow_adapters::Backend;
use sqmeow_db::{Cell, Error, KeyType, RelationKind, ResultSet};
use tokio_util::sync::CancellationToken;

const NO_CAP: usize = usize::MAX;

// The tests share one database and run in parallel, so each one owns keys under its own prefix.

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

async fn connect(url: &str) -> Backend {
    Backend::connect(url)
        .await
        .expect("the test server should accept a connection")
}

async fn run(backend: &Backend, command: &str) -> ResultSet {
    backend
        .execute(command, NO_CAP, CancellationToken::new())
        .await
        .unwrap_or_else(|error| panic!("{command} should run: {error}"))
}

fn names(result: &ResultSet) -> Vec<&str> {
    result.columns().iter().map(|c| c.name.as_str()).collect()
}

#[tokio::test]
async fn connects_and_reports_its_dialect() {
    let backend = connect(&server!()).await;
    assert_eq!(backend.dialect().name(), "redis");
}

#[tokio::test]
async fn refuses_a_server_that_is_not_there() {
    let error = Backend::connect("redis://127.0.0.1:1/0").await.unwrap_err();
    assert!(matches!(error, Error::Driver(_)), "{error}");
}

#[tokio::test]
async fn reads_back_a_string_it_wrote() {
    let backend = connect(&server!()).await;
    run(&backend, r#"SET test:string "hello world""#).await;

    let result = run(&backend, "GET test:string").await;
    assert_eq!(names(&result), vec!["value"]);
    assert_eq!(result.cell(0, 0), Some(&Cell::Text("hello world".into())));
}

#[tokio::test]
async fn a_missing_key_is_null() {
    let backend = connect(&server!()).await;
    let result = run(&backend, "GET test:absent").await;
    assert_eq!(result.cell(0, 0), Some(&Cell::Null));
}

#[tokio::test]
async fn a_hash_is_one_row_per_field() {
    let backend = connect(&server!()).await;
    run(&backend, "DEL test:hash").await;
    run(&backend, "HSET test:hash name alice age 30").await;

    let result = run(&backend, "HGETALL test:hash").await;
    assert_eq!(names(&result), vec!["field", "value"]);

    let mut pairs: Vec<(String, String)> = (0..result.row_count())
        .map(|row| {
            let text = |column| result.cell(row, column).unwrap().display("").into_owned();
            (text(0), text(1))
        })
        .collect();
    pairs.sort();
    assert_eq!(
        pairs,
        vec![
            ("age".to_owned(), "30".to_owned()),
            ("name".to_owned(), "alice".to_owned())
        ]
    );
}

#[tokio::test]
async fn a_list_is_one_row_per_element() {
    let backend = connect(&server!()).await;
    run(&backend, "DEL test:list").await;
    run(&backend, "RPUSH test:list a b c").await;

    let result = run(&backend, "LRANGE test:list 0 -1").await;
    assert_eq!(names(&result), vec!["value"]);
    assert_eq!(result.row_count(), 3);
    assert_eq!(result.cell(2, 0), Some(&Cell::Text("c".into())));
}

#[tokio::test]
async fn scores_sit_beside_their_members() {
    let backend = connect(&server!()).await;
    run(&backend, "DEL test:zset").await;
    run(&backend, "ZADD test:zset 1 alice 2 bob").await;

    let result = run(&backend, "ZRANGE test:zset 0 -1 WITHSCORES").await;
    assert_eq!(names(&result), vec!["1", "2"]);
    assert_eq!(result.cell(0, 0), Some(&Cell::Text("alice".into())));
    assert_eq!(result.cell(1, 1), Some(&Cell::Float(2.0)));
}

#[tokio::test]
async fn reports_an_error_and_keeps_working() {
    let backend = connect(&server!()).await;
    let error = backend
        .execute("NOPE", NO_CAP, CancellationToken::new())
        .await
        .unwrap_err();

    assert!(
        error.to_string().to_lowercase().contains("unknown command"),
        "{error}"
    );
    assert_eq!(
        run(&backend, "PING").await.cell(0, 0),
        Some(&Cell::Text("PONG".into()))
    );
}

#[tokio::test]
async fn stops_at_the_row_cap_and_says_so() {
    let backend = connect(&server!()).await;
    run(&backend, "DEL test:capped").await;
    let values: Vec<String> = (1..=20).map(|n| n.to_string()).collect();
    run(&backend, &format!("RPUSH test:capped {}", values.join(" "))).await;

    let result = backend
        .execute("LRANGE test:capped 0 -1", 5, CancellationToken::new())
        .await
        .expect("the command should run");
    assert_eq!(result.row_count(), 5);
    assert!(result.is_truncated());
}

#[tokio::test]
async fn cancelling_a_blocked_command_stops_it() {
    let backend = connect(&server!()).await;
    let cancel = CancellationToken::new();

    let stopper = cancel.clone();
    tokio::spawn(async move {
        tokio::time::sleep(std::time::Duration::from_millis(50)).await;
        stopper.cancel();
    });

    let error = backend
        .execute("BLPOP test:never 2", NO_CAP, cancel)
        .await
        .unwrap_err();
    assert!(matches!(error, Error::Cancelled), "{error}");
}

#[tokio::test]
async fn a_command_that_outlasts_half_a_second_is_not_cut_off() {
    let backend = connect(&server!()).await;
    // Nothing is pushed, so this waits out its whole second and answers nil.
    let result = run(&backend, "BLPOP test:slow 1").await;
    assert_eq!(result.cell(0, 0), Some(&Cell::Null));
}

#[tokio::test]
async fn lists_the_current_database() {
    let backend = connect(&server!()).await;
    let schemas = backend.schemas().await.expect("schemas should load");

    assert_eq!(schemas.len(), 1);
    assert!(schemas[0].is_default);
    assert!(schemas[0].name.starts_with("db"), "{}", schemas[0].name);
}

#[tokio::test]
async fn lists_keys_by_what_they_hold() {
    let backend = connect(&server!()).await;
    for key in ["string", "hash", "list", "set", "zset", "stream"] {
        run(&backend, &format!("DEL test:kinds:{key}")).await;
    }
    run(&backend, "SET test:kinds:string v").await;
    run(&backend, "HSET test:kinds:hash f v").await;
    run(&backend, "RPUSH test:kinds:list v").await;
    run(&backend, "SADD test:kinds:set v").await;
    run(&backend, "ZADD test:kinds:zset 1 v").await;
    run(&backend, "XADD test:kinds:stream * f v").await;

    let schema = backend.schemas().await.unwrap().remove(0).name;
    let relations = backend.relations(&schema).await.expect("keys should load");
    let kind = |name: &str| {
        relations
            .iter()
            .find(|relation| relation.name == name)
            .map(|relation| relation.kind)
    };

    assert_eq!(
        kind("test:kinds:string"),
        Some(RelationKind::Key(KeyType::String))
    );
    assert_eq!(
        kind("test:kinds:hash"),
        Some(RelationKind::Key(KeyType::Hash))
    );
    assert_eq!(
        kind("test:kinds:list"),
        Some(RelationKind::Key(KeyType::List))
    );
    assert_eq!(
        kind("test:kinds:set"),
        Some(RelationKind::Key(KeyType::Set))
    );
    assert_eq!(
        kind("test:kinds:zset"),
        Some(RelationKind::Key(KeyType::SortedSet))
    );
    assert_eq!(
        kind("test:kinds:stream"),
        Some(RelationKind::Key(KeyType::Stream))
    );
}
