async fn failed_apply_rolls_back(backend: &Backend, create: &str) {
    run(backend, create).await;
    run(
        backend,
        "insert into sqmeow_rollback_smoke values (1, 'before')",
    )
    .await;
    let error = backend
        .apply(
            &[
                "update sqmeow_rollback_smoke set name = 'after' where id = 1".into(),
                "insert into sqmeow_rollback_missing values (1)".into(),
            ],
            CancellationToken::new(),
        )
        .await
        .unwrap_err();
    assert!(
        error
            .to_string()
            .to_lowercase()
            .contains("sqmeow_rollback_missing"),
        "{error}"
    );
    assert_eq!(
        run(
            backend,
            "select name from sqmeow_rollback_smoke where id = 1"
        )
        .await
        .cell(0, 0),
        Some(&sqmeow_db::value::Cell::Text("before".into()))
    );
    backend
        .apply(
            &["update sqmeow_rollback_smoke set name = 'reused' where id = 1".into()],
            CancellationToken::new(),
        )
        .await
        .unwrap();
    assert_eq!(
        run(
            backend,
            "select name from sqmeow_rollback_smoke where id = 1"
        )
        .await
        .cell(0, 0),
        Some(&sqmeow_db::value::Cell::Text("reused".into()))
    );
    run(backend, "drop table sqmeow_rollback_smoke").await;
    backend.close().await;
}
