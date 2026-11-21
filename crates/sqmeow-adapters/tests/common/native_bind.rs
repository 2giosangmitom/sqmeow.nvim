async fn bound_values_remain_data(
    backend: &Backend,
    sql: &str,
    values: &[sqmeow_db::sql::parameters::Value],
    text: &str,
) {
    let result = backend
        .execute_bound(sql, values, NO_CAP, CancellationToken::new())
        .await
        .unwrap();
    assert_eq!(result.row_count(), 1);
    assert_eq!(
        result.cell(0, 0).as_deref(),
        Some(&sqmeow_db::value::Cell::Text(text.into()))
    );
    assert_eq!(
        result.cell(0, 1).as_deref(),
        Some(&sqmeow_db::value::Cell::Text(text.into()))
    );
    assert_eq!(result.cell(0, 2).as_deref(), Some(&sqmeow_db::value::Cell::Null));
    backend.close().await;
}
