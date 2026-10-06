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

use sqmeow_db::sql::parameters::{Kind, Value};

#[tokio::test]
async fn native_binds_keep_types_nulls_and_repeated_text() {
    let backend = connect(&server!()).await;
    table(&backend, "bound_values", "id int PRIMARY KEY, large bigint, flag boolean, fraction float, precise double, first text, repeated text, missing int").await;
    let text = "it's \\ data; ' OR true -- :name ?";
    let write = backend.execute_bound(
        "INSERT INTO sqmeow.bound_values (id, large, flag, fraction, precise, first, repeated, missing) VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
        &[Value::Int(42), Value::Int(i64::MAX), Value::Bool(true), Value::Float(1.5), Value::Float(2.25), Value::Text(text.into()), Value::Text(text.into()), Value::Null(Kind::Int)],
        NO_CAP, CancellationToken::new(),
    ).await.unwrap();
    assert_eq!(write.row_count(), 0);
    let result = backend.execute_bound(
        "SELECT id, large, flag, fraction, precise, first, repeated, missing FROM sqmeow.bound_values WHERE id = ?",
        &[Value::Int(42)], NO_CAP, CancellationToken::new(),
    ).await.unwrap();
    let expected = [
        Cell::Int(42),
        Cell::Int(i64::MAX),
        Cell::Bool(true),
        Cell::Float(1.5),
        Cell::Float(2.25),
        Cell::Text(text.into()),
        Cell::Text(text.into()),
        Cell::Null,
    ];
    for (index, cell) in expected.iter().enumerate() {
        assert_eq!(result.cell(0, index), Some(cell));
    }
    assert!(result.source().is_some());
    assert_eq!(result.columns()[0].key, KeyKind::Primary);
    let capped = backend
        .execute_bound(
            "SELECT id FROM sqmeow.bound_values WHERE id = ?",
            &[Value::Int(42)],
            0,
            CancellationToken::new(),
        )
        .await
        .unwrap();
    assert!(capped.is_truncated());
    assert_eq!(capped.row_count(), 0);
}

#[tokio::test]
async fn invalid_bound_types_and_cancellation_keep_the_session_usable() {
    let backend = connect(&server!()).await;
    table(
        &backend,
        "bound_errors",
        "id int PRIMARY KEY, fraction float",
    )
    .await;
    for values in [
        vec![Value::Int(i64::MAX), Value::Float(1.0)],
        vec![Value::Int(1), Value::Float(f64::MAX)],
        vec![Value::Text("1".into()), Value::Float(1.0)],
        vec![Value::Int(1)],
    ] {
        let error = backend
            .execute_bound(
                "INSERT INTO sqmeow.bound_errors (id, fraction) VALUES (?, ?)",
                &values,
                NO_CAP,
                CancellationToken::new(),
            )
            .await
            .unwrap_err();
        assert!(matches!(error, Error::Driver(_)), "{error}");
    }
    let cancel = CancellationToken::new();
    cancel.cancel();
    let error = backend
        .execute_bound(
            "SELECT id FROM sqmeow.bound_errors WHERE id = ?",
            &[Value::Int(1)],
            NO_CAP,
            cancel,
        )
        .await
        .unwrap_err();
    assert!(matches!(error, Error::Cancelled));
    run(&backend, "SELECT release_version FROM system.local").await;
    assert_eq!(
        run(&backend, "SELECT id FROM sqmeow.bound_errors")
            .await
            .row_count(),
        0
    );
}

#[tokio::test]
async fn the_server_really_is_scylla() {
    let backend = connect(&server!()).await;
    // Only ScyllaDB has this table.
    run(&backend, "SELECT version FROM system.versions").await;
}
