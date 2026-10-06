//! Cancellation and async-runtime contracts for the SQLite worker migration.

use std::time::Duration;

use sqmeow_adapters::Backend;
use sqmeow_db::error::Error;
use tokio_util::sync::CancellationToken;

const NO_CAP: usize = usize::MAX;

#[tokio::test(flavor = "current_thread")]
async fn sqlite_work_does_not_block_the_runtime_and_cancellation_keeps_the_session() {
    let backend = Backend::connect("sqlite::memory:").await.unwrap();
    backend
        .execute(
            "create temp table session_state (id int)",
            NO_CAP,
            CancellationToken::new(),
        )
        .await
        .unwrap();
    let cancel = CancellationToken::new();
    let stop = cancel.clone();
    let query = backend.execute(
        "with recursive n(x) as (select 1 union all select x+1 from n where x<100000000) select sum(x) from n",
        NO_CAP,
        cancel,
    );
    let timer = async move {
        tokio::time::sleep(Duration::from_millis(20)).await;
        stop.cancel();
    };
    let (result, ()) =
        tokio::time::timeout(Duration::from_secs(3), async { tokio::join!(query, timer) })
            .await
            .expect("SQLite must leave runtime timers responsive");
    assert!(matches!(result, Err(Error::Cancelled)));
    backend
        .execute(
            "insert into session_state values (1)",
            NO_CAP,
            CancellationToken::new(),
        )
        .await
        .unwrap();
    backend.close().await;
}

#[tokio::test(flavor = "current_thread")]
async fn cancelling_queued_work_does_not_interrupt_the_active_request_or_write() {
    let backend = Backend::connect("sqlite::memory:").await.unwrap();
    backend
        .execute(
            "create table writes (id int)",
            NO_CAP,
            CancellationToken::new(),
        )
        .await
        .unwrap();
    let active = backend.execute(
        "with recursive n(x) as (select 1 union all select x+1 from n where x<1000000) select sum(x) from n",
        NO_CAP,
        CancellationToken::new(),
    );
    let queued = async {
        tokio::time::sleep(Duration::from_millis(5)).await;
        let cancel = CancellationToken::new();
        cancel.cancel();
        backend
            .execute("insert into writes values (1)", NO_CAP, cancel)
            .await
    };
    let (active, queued) = tokio::join!(active, queued);
    assert_eq!(active.unwrap().row_count(), 1);
    assert!(matches!(queued, Err(Error::Cancelled)));
    let rows = backend
        .execute("select * from writes", NO_CAP, CancellationToken::new())
        .await
        .unwrap();
    assert_eq!(rows.row_count(), 0);
    backend.close().await;
}

#[tokio::test]
async fn a_pre_cancelled_apply_commits_nothing_and_leaves_no_transaction() {
    let backend = Backend::connect("sqlite::memory:").await.unwrap();
    backend
        .execute(
            "create table writes (id int)",
            NO_CAP,
            CancellationToken::new(),
        )
        .await
        .unwrap();
    let cancel = CancellationToken::new();
    cancel.cancel();
    let result = backend
        .apply(&["insert into writes values (1)".to_owned()], cancel)
        .await;
    assert!(matches!(result, Err(Error::Cancelled)));
    let rows = backend
        .execute("select * from writes", NO_CAP, CancellationToken::new())
        .await
        .unwrap();
    assert_eq!(rows.row_count(), 0);
    backend
        .execute("begin", NO_CAP, CancellationToken::new())
        .await
        .unwrap();
    backend
        .execute("rollback", NO_CAP, CancellationToken::new())
        .await
        .unwrap();
    backend.close().await;
}

#[tokio::test]
async fn repeated_close_and_requests_after_close_do_not_hang() {
    let backend = Backend::connect("sqlite::memory:").await.unwrap();
    backend.close().await;
    tokio::time::timeout(Duration::from_secs(1), backend.close())
        .await
        .expect("close must be idempotent");
    let result = tokio::time::timeout(
        Duration::from_secs(1),
        backend.execute("select 1", NO_CAP, CancellationToken::new()),
    )
    .await
    .expect("a closed worker must answer with an error");
    assert!(result.is_err());
}

#[tokio::test]
async fn abandoning_an_apply_rolls_back_before_the_next_request() {
    let backend = Backend::connect("sqlite::memory:").await.unwrap();
    backend.execute("create table abandoned (id int primary key, value int); insert into abandoned values (1, 10)", NO_CAP, CancellationToken::new()).await.unwrap();
    let statements = [
        "update abandoned set value = 20 where id = 1".into(),
        "with recursive n(x) as (select 1 union all select x+1 from n where x<100000000) select sum(x) from n".into(),
    ];
    assert!(
        tokio::time::timeout(
            Duration::from_millis(50),
            backend.apply(&statements, CancellationToken::new())
        )
        .await
        .is_err()
    );
    let rows = tokio::time::timeout(
        Duration::from_secs(3),
        backend.execute(
            "select value from abandoned",
            NO_CAP,
            CancellationToken::new(),
        ),
    )
    .await
    .unwrap()
    .unwrap();
    assert_eq!(rows.cell(0, 0), Some(&sqmeow_db::value::Cell::Int(10)));
    backend.close().await;
}

#[tokio::test]
async fn cancelling_a_busy_write_is_prompt_and_does_not_poison_the_next_request() {
    let suffix = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap()
        .as_nanos();
    let root = std::env::temp_dir().join("opencode");
    std::fs::create_dir_all(&root).unwrap();
    let path = root.join(format!(
        "sqmeow-worker-busy-{}-{suffix}.db",
        std::process::id()
    ));
    let url = format!("sqlite://{}?mode=rwc", path.display());
    let owner = Backend::connect(&url).await.unwrap();
    owner
        .execute(
            "create table writes (id int)",
            NO_CAP,
            CancellationToken::new(),
        )
        .await
        .unwrap();
    let waiting = Backend::connect(&url).await.unwrap();
    owner
        .execute("begin immediate", NO_CAP, CancellationToken::new())
        .await
        .unwrap();
    let cancel = CancellationToken::new();
    let stop = cancel.clone();
    let query = waiting.execute("insert into writes values (1)", NO_CAP, cancel);
    let timer = async move {
        tokio::time::sleep(Duration::from_millis(20)).await;
        stop.cancel();
    };
    let (result, ()) =
        tokio::time::timeout(Duration::from_secs(3), async { tokio::join!(query, timer) })
            .await
            .expect("busy cancellation must not wait for the full busy timeout");
    assert!(matches!(result, Err(Error::Cancelled)));
    owner
        .execute("rollback", NO_CAP, CancellationToken::new())
        .await
        .unwrap();
    waiting
        .execute(
            "insert into writes values (2)",
            NO_CAP,
            CancellationToken::new(),
        )
        .await
        .unwrap();
    let rows = waiting
        .execute("select * from writes", NO_CAP, CancellationToken::new())
        .await
        .unwrap();
    assert_eq!(rows.row_count(), 1);
    waiting.close().await;
    owner.close().await;
    std::fs::remove_file(path).unwrap();
}
