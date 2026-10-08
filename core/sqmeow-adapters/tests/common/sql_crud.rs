async fn crud_round_trip(backend: &Backend, create: &str) {
    run(backend, create).await;
    run(
        backend,
        "insert into sqmeow_crud_smoke (id, name) values (1, 'alice')",
    )
    .await;
    let selected = run(backend, "select name from sqmeow_crud_smoke where id = 1").await;
    assert_eq!(selected.row_count(), 1);
    assert_eq!(
        selected.cell(0, 0),
        Some(&sqmeow_db::value::Cell::Text("alice".into()))
    );

    run(
        backend,
        "update sqmeow_crud_smoke set name = 'bob' where id = 1",
    )
    .await;
    let updated = run(backend, "select name from sqmeow_crud_smoke where id = 1").await;
    assert_eq!(
        updated.cell(0, 0),
        Some(&sqmeow_db::value::Cell::Text("bob".into()))
    );

    let editable = run(
        backend,
        "select id, name from sqmeow_crud_smoke where id = 1",
    )
    .await;
    match editable.source() {
        Some(sqmeow_db::edit::Source::Tables(tables)) => {
            assert_eq!(tables.len(), 1);
            assert_eq!(
                tables[0].key,
                vec![0],
                "edits must locate rows by their primary key"
            );
        }
        source => panic!("expected a keyed table source, got {source:?}"),
    }
    let changes = sqmeow_db::edit::Changes {
        updates: vec![(0, vec![(1, "planned".into())])],
        ..Default::default()
    };
    let plan = backend.plan(&editable, &changes).unwrap();
    backend
        .apply(&plan, CancellationToken::new())
        .await
        .unwrap();
    assert_eq!(
        run(backend, "select name from sqmeow_crud_smoke where id = 1")
            .await
            .cell(0, 0),
        Some(&sqmeow_db::value::Cell::Text("planned".into()))
    );

    let refreshed = run(
        backend,
        "select id, name from sqmeow_crud_smoke where id = 1",
    )
    .await;
    let stale_changes = sqmeow_db::edit::Changes {
        updates: vec![(0, vec![(1, "missing".into())])],
        ..Default::default()
    };
    let stale_plan = backend.plan(&refreshed, &stale_changes).unwrap();
    run(backend, "delete from sqmeow_crud_smoke where id = 1").await;
    assert_eq!(
        run(backend, "select * from sqmeow_crud_smoke")
            .await
            .row_count(),
        0
    );
    assert!(
        backend
            .apply(&stale_plan, CancellationToken::new())
            .await
            .is_err(),
        "a stale edit must not silently succeed after its row was deleted"
    );
    run(backend, "drop table sqmeow_crud_smoke").await;
    backend.close().await;
}
