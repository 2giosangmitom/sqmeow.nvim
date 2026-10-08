// Simple cases every Redis-protocol server must pass.

use sqmeow_adapters::Backend;
use sqmeow_db::error::Error;
use sqmeow_db::result::ResultSet;
use sqmeow_db::value::Cell;
use tokio_util::sync::CancellationToken;

const NO_CAP: usize = usize::MAX;

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
async fn commands_create_read_update_and_delete_rows() {
    let backend = connect(&server!()).await;
    run(&backend, r#"SET test:string "hello world""#).await;

    let result = run(&backend, "GET test:string").await;
    assert_eq!(result.cell(0, 0), Some(&Cell::Text("hello world".into())));
    let properties = backend
        .details("db0", "test:string")
        .await
        .unwrap()
        .properties;
    assert!(
        properties
            .iter()
            .any(|(name, value)| name == "type" && value == "string")
    );
    run(&backend, "SET test:string updated").await;
    assert_eq!(
        run(&backend, "GET test:string").await.cell(0, 0),
        Some(&Cell::Text("updated".into()))
    );
    run(&backend, "DEL test:string").await;
    assert_eq!(
        run(&backend, "EXISTS test:string").await.cell(0, 0),
        Some(&Cell::Int(0))
    );
    backend.close().await;
}

#[tokio::test]
async fn cancelling_a_blocked_command_stops_it() {
    let backend = connect(&server!()).await;
    run(&backend, "DEL test:never").await;
    let cancel = CancellationToken::new();
    let stopper = cancel.clone();
    let command = backend.execute("BLPOP test:never 2", NO_CAP, cancel);
    let timer = async move {
        tokio::time::sleep(std::time::Duration::from_millis(50)).await;
        stopper.cancel();
    };
    let (result, ()) = tokio::time::timeout(std::time::Duration::from_secs(3), async {
        tokio::join!(command, timer)
    })
    .await
    .expect("blocked command must answer cancellation");
    assert!(matches!(result, Err(Error::Cancelled)));
    assert_eq!(
        run(&backend, "PING").await.cell(0, 0),
        Some(&Cell::Text("PONG".into()))
    );
    backend.close().await;
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
