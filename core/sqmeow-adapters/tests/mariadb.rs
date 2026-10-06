//! MySQL-protocol compatibility on an actual MariaDB server.

include!("common/harness.rs");
include!("common/relationships.rs");

#[tokio::test]
async fn mariadb_relationships_preserve_catalog_endpoints() {
    let url = server!("SQMEOW_TEST_MARIADB_URL");
    let backend = connect(&url.replacen("mysql://", "mariadb://", 1)).await;
    let schema = backend
        .schemas()
        .await
        .unwrap()
        .into_iter()
        .find(|schema| schema.is_default)
        .unwrap();
    relationship_fixture(&backend, &schema.name).await;
    backend.close().await;
}

#[tokio::test]
async fn mariadb_bound_text_is_data_and_large_numbers_stay_exact() {
    use sqmeow_db::sql::parameters::Value;
    use sqmeow_db::value::Cell;

    let url = server!("SQMEOW_TEST_MARIADB_URL");
    let backend = connect(&url).await;
    let input = "Robert'); DROP TABLE users; --";
    let result = backend
        .execute_bound(
            "select ? as value",
            &[Value::Text(input.into())],
            NO_CAP,
            CancellationToken::new(),
        )
        .await
        .unwrap();
    assert_eq!(result.cell(0, 0), Some(&Cell::Text(input.into())));
    let result = run(&backend, "select cast('18446744073709551615' as unsigned), cast('12345678901234567890.1234567890' as decimal(30,10))").await;
    assert_eq!(
        result.cell(0, 0),
        Some(&Cell::Decimal("18446744073709551615".into()))
    );
    assert_eq!(
        result.cell(0, 1),
        Some(&Cell::Decimal("12345678901234567890.1234567890".into()))
    );
    backend.close().await;
}

#[tokio::test]
async fn mariadb_preserves_session_parameters_and_cancel_reuse() {
    let url = server!("SQMEOW_TEST_MARIADB_URL");
    let backend = connect(&url).await;
    run(
        &backend,
        "create temporary table sqmeow_maria_session (id int primary key, name varchar(100))",
    )
    .await;
    run(
        &backend,
        "insert into sqmeow_maria_session values (1, 'original')",
    )
    .await;
    let result = backend
        .execute_bound(
            "select name from sqmeow_maria_session where id = ?",
            &[sqmeow_db::sql::parameters::Value::Int(1)],
            NO_CAP,
            CancellationToken::new(),
        )
        .await
        .unwrap();
    assert_eq!(result.row_count(), 1);
    let cancel = CancellationToken::new();
    let stop = cancel.clone();
    let query = backend.execute("select sleep(30)", NO_CAP, cancel);
    let timer = async move {
        tokio::time::sleep(std::time::Duration::from_millis(100)).await;
        stop.cancel();
    };
    let (result, ()) = tokio::join!(query, timer);
    assert!(matches!(result, Err(sqmeow_db::error::Error::Cancelled)));
    assert_eq!(
        run(&backend, "select * from sqmeow_maria_session")
            .await
            .row_count(),
        1
    );
    backend.close().await;
}

#[tokio::test]
async fn mariadb_edit_application_is_atomic_and_keeps_noop_updates() {
    let url = server!("SQMEOW_TEST_MARIADB_URL");
    let backend = connect(&url).await;
    run(
        &backend,
        "create temporary table sqmeow_maria_edit (id int primary key, name varchar(100))",
    )
    .await;
    run(
        &backend,
        "insert into sqmeow_maria_edit values (1, 'original')",
    )
    .await;
    backend
        .apply(
            &["update sqmeow_maria_edit set name = 'original' where id = 1".to_owned()],
            CancellationToken::new(),
        )
        .await
        .unwrap();
    let failed = backend
        .apply(
            &[
                "update sqmeow_maria_edit set name = 'changed' where id = 1".to_owned(),
                "delete from sqmeow_maria_edit where id = 99".to_owned(),
            ],
            CancellationToken::new(),
        )
        .await;
    assert!(failed.is_err());
    assert_eq!(
        run(
            &backend,
            "select * from sqmeow_maria_edit where name = 'original'"
        )
        .await
        .row_count(),
        1
    );
    backend.close().await;
}
