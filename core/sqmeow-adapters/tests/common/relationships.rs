/// Exercise catalog discovery with structured names and three distinct constraints.
async fn relationship_fixture(backend: &sqmeow_adapters::Backend, schema: &str) {
    let parent_name = "rel.parent";
    let child_name = "rel.child";
    let parent = format!(
        "{}.{}",
        backend.quote_ident(schema),
        backend.quote_ident(parent_name)
    );
    let child = format!(
        "{}.{}",
        backend.quote_ident(schema),
        backend.quote_ident(child_name)
    );
    for table in [&child, &parent] {
        let _ = backend
            .execute(
                &format!("drop table {table}"),
                usize::MAX,
                tokio_util::sync::CancellationToken::new(),
            )
            .await;
    }
    let self_key = backend.quote_ident("rel.self");
    let first_key = backend.quote_ident("rel.first");
    let second_key = backend.quote_ident("rel.second");
    let [a, b, c, d, e, f, p, q] =
        ["a", "b", "c", "d", "e", "f", "p", "q"].map(|name| backend.quote_ident(name));
    run(backend, &format!("create table {parent} ({a} integer, {b} integer, {p} integer, {q} integer, primary key ({b}, {a}), constraint {self_key} foreign key ({p}, {q}) references {parent} ({b}, {a}))")).await;
    run(backend, &format!("create table {child} ({c} integer, {d} integer, {e} integer, {f} integer, constraint {first_key} foreign key ({d}, {c}) references {parent} ({b}, {a}), constraint {second_key} foreign key ({e}, {f}) references {parent} ({b}, {a}))")).await;
    let outgoing = backend.relationships(schema, child_name).await.unwrap();
    assert_eq!(outgoing.len(), 2);
    assert_ne!(outgoing[0].name, outgoing[1].name);
    for key in &outgoing {
        assert_eq!(key.source_schema, schema);
        assert_eq!(key.source_relation, child_name);
        assert_eq!(key.target_schema, schema);
        assert_eq!(key.target_relation, parent_name);
    }
    let first = outgoing.iter().find(|key| key.name == "rel.first").unwrap();
    assert_eq!(first.columns, ["d", "c"]);
    assert_eq!(first.referenced, ["b", "a"]);
    let incoming = backend.relationships(schema, parent_name).await.unwrap();
    assert_eq!(incoming.len(), 3);
    for key in &outgoing {
        assert!(incoming.contains(key));
    }
    let self_keys: Vec<_> = incoming
        .iter()
        .filter(|key| key.source_relation == parent_name)
        .collect();
    assert_eq!(self_keys.len(), 1);
    assert_eq!(self_keys[0].columns, ["p", "q"]);
    assert_eq!(self_keys[0].referenced, ["b", "a"]);
    run(backend, &format!("drop table {child}")).await;
    run(backend, &format!("drop table {parent}")).await;
}
