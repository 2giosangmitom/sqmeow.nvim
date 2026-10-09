//! Native session lifecycle and small, typed catalog-query helpers.
use sqmeow_db::error::{Error, Result};
use std::marker::PhantomData;
use std::pin::Pin;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use std::task::{Context, Poll};
use tokio::io::{AsyncRead, AsyncWrite, ReadBuf};
use tokio_postgres::types::{FromSqlOwned, ToSql};
use tokio_postgres::{Client, Config, Row};
use tokio_postgres_rustls::MakeRustlsConnect;

#[derive(Clone)]
pub(super) struct Options {
    config: Config,
    pub(super) tls: MakeRustlsConnect,
}
impl std::fmt::Debug for Options {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str("PostgresOptions { .. }")
    }
}

impl Options {
    pub(super) fn parse(input: &str, database: Option<&str>) -> Result<(Self, bool)> {
        let mut url = url::Url::parse(input).map_err(Error::driver)?;
        let pairs: Vec<_> = url
            .query_pairs()
            .map(|(k, v)| (k.into_owned(), v.into_owned()))
            .collect();
        url.set_query(None);
        let decode = |value: &str| {
            percent_encoding::percent_decode_str(value)
                .decode_utf8()
                .map(|s| s.into_owned())
                .map_err(Error::driver)
        };
        let mut host = url
            .host_str()
            .map(decode)
            .transpose()?
            .or_else(|| std::env::var("PGHOST").ok())
            .unwrap_or_else(|| "localhost".into());
        let mut port = url
            .port()
            .or_else(|| std::env::var("PGPORT").ok().and_then(|p| p.parse().ok()))
            .unwrap_or(5432);
        let mut user = if !url.username().is_empty() {
            Some(decode(url.username())?)
        } else {
            std::env::var("PGUSER").ok()
        };
        let mut password = url
            .password()
            .map(decode)
            .transpose()?
            .or_else(|| std::env::var("PGPASSWORD").ok());
        let mut dbname = if url.path().trim_matches('/').is_empty() {
            std::env::var("PGDATABASE").ok()
        } else {
            Some(decode(url.path().trim_start_matches('/'))?)
        };
        let mut config = Config::new();
        if let Ok(name) = std::env::var("PGAPPNAME") {
            config.application_name(name);
        }
        let mut sslmode = std::env::var("PGSSLMODE").unwrap_or_else(|_| "prefer".into());
        let mut root = std::env::var("PGSSLROOTCERT").ok();
        let mut cert = std::env::var("PGSSLCERT").ok();
        let mut key = std::env::var("PGSSLKEY").ok();
        let mut options = std::env::var("PGOPTIONS").unwrap_or_default();
        for (name, value) in pairs {
            match name.as_str() {
                "sslmode" | "ssl-mode" => sslmode = value,
                "sslrootcert" | "ssl-root-cert" | "ssl-ca" => root = Some(value),
                "sslcert" | "ssl-cert" => cert = Some(value),
                "sslkey" | "ssl-key" => key = Some(value),
                "statement-cache-capacity" => {
                    value.parse::<usize>().map_err(Error::driver)?;
                }
                "host" | "hostaddr" => host = value,
                "port" => port = value.parse().map_err(Error::driver)?,
                "dbname" => dbname = Some(value),
                "user" => user = Some(value),
                "password" => password = Some(value),
                "application_name" => {
                    config.application_name(&value);
                }
                "options" => {
                    options.push(' ');
                    options.push_str(&value);
                }
                name if name.starts_with("options[") && name.ends_with(']') => {
                    options.push_str(&format!(" -c {}={value}", &name[8..name.len() - 1]));
                }
                // SQLx ignored unknown URL parameters too.
                _ => {}
            }
        }
        config.host(&host).port(port);
        if let Some(user) = user {
            config.user(user);
        }
        if let Some(password) = password {
            config.password(password);
        }
        if let Some(dbname) = dbname {
            config.dbname(dbname);
        }
        if !options.is_empty() {
            config.options(&options);
        }
        let cluster = database.is_none() && config.get_dbname().is_none();
        if let Some(database) = database {
            config.dbname(database);
        } else if cluster {
            config.dbname("postgres");
        }
        use tokio_postgres::config::SslMode;
        config.ssl_mode(match sslmode.as_str() {
            "disable" | "allow" => SslMode::Disable,
            "prefer" => SslMode::Prefer,
            "require" | "verify-ca" | "verify-full" => SslMode::Require,
            _ => return Err(Error::driver(format!("invalid sslmode: {sslmode}"))),
        });
        let provider = Arc::new(rustls::crypto::ring::default_provider());
        if config.get_ssl_mode() == SslMode::Disable {
            let tls = rustls::ClientConfig::builder_with_provider(provider.clone())
                .with_safe_default_protocol_versions()
                .map_err(Error::driver)?
                .dangerous()
                .with_custom_certificate_verifier(Arc::new(Verifier {
                    verify_ca: false,
                    roots: Arc::new(rustls::RootCertStore::empty()),
                    provider,
                }))
                .with_no_client_auth();
            return Ok((
                Self {
                    config,
                    tls: MakeRustlsConnect::new(tls),
                },
                cluster,
            ));
        }
        let mut roots = rustls::RootCertStore::empty();
        for cert in rustls_native_certs::load_native_certs().certs {
            roots.add(cert).map_err(Error::driver)?;
        }
        if let Some(path) = root {
            use rustls::pki_types::pem::PemObject;
            for cert in
                rustls::pki_types::CertificateDer::pem_file_iter(path).map_err(Error::driver)?
            {
                roots
                    .add(cert.map_err(Error::driver)?)
                    .map_err(Error::driver)?;
            }
        }
        let roots = Arc::new(roots);
        let builder = rustls::ClientConfig::builder_with_provider(provider.clone())
            .with_safe_default_protocol_versions()
            .map_err(Error::driver)?;
        let builder = if sslmode == "verify-full" {
            builder.with_root_certificates(roots.clone())
        } else {
            builder
                .dangerous()
                .with_custom_certificate_verifier(Arc::new(Verifier {
                    verify_ca: sslmode == "verify-ca",
                    roots,
                    provider,
                }))
        };
        let tls = match (cert, key) {
            (Some(cert), Some(key)) => {
                use rustls::pki_types::pem::PemObject;
                let certs = rustls::pki_types::CertificateDer::pem_file_iter(cert)
                    .map_err(Error::driver)?
                    .collect::<std::result::Result<Vec<_>, _>>()
                    .map_err(Error::driver)?;
                let key =
                    rustls::pki_types::PrivateKeyDer::from_pem_file(key).map_err(Error::driver)?;
                builder
                    .with_client_auth_cert(certs, key)
                    .map_err(Error::driver)?
            }
            (None, None) => builder.with_no_client_auth(),
            _ => {
                return Err(Error::driver(
                    "sslcert and sslkey must be supplied together",
                ));
            }
        };
        Ok((
            Self {
                config,
                tls: MakeRustlsConnect::new(tls),
            },
            cluster,
        ))
    }

    pub(super) async fn open_retrying(&self) -> Result<Session> {
        let open =
            crate::connect_retrying_with(|| self.config.connect(self.tls.clone()), retryable);
        let (client, connection) = tokio::time::timeout(crate::CONNECT_TIMEOUT, open)
            .await
            .map_err(|_| Error::driver("PostgreSQL connection timed out"))?
            .map_err(driver)?;
        let task = tokio::spawn(async move {
            if let Err(error) = connection.await {
                tracing::debug!(%error, "PostgreSQL connection ended");
            }
        });
        Ok(Session {
            retired: AtomicBool::new(false),
            client: tokio::sync::RwLock::new(Some(Arc::new(client))),
            task: Mutex::new(Some(task)),
        })
    }

    /// Native cancellation returns after write/shutdown, not server acknowledgment.
    /// The stream's shutdown therefore also waits for server EOF before reuse.
    pub(super) async fn cancel(&self, client: &Client) -> Result<()> {
        use tokio_postgres::config::Host;
        let host = self
            .config
            .get_hosts()
            .first()
            .ok_or_else(|| Error::driver("PostgreSQL cancellation has no host"))?;
        let port = self.config.get_ports().first().copied().unwrap_or(5432);
        match host {
            Host::Tcp(host) => {
                let stream = tokio::net::TcpStream::connect((host.as_str(), port))
                    .await
                    .map_err(Error::driver)?;
                self.cancel_on(client, stream, host).await
            }
            #[cfg(unix)]
            Host::Unix(path) => {
                let stream = tokio::net::UnixStream::connect(path.join(format!(".s.PGSQL.{port}")))
                    .await
                    .map_err(Error::driver)?;
                self.cancel_on(client, stream, "").await
            }
        }
    }

    async fn cancel_on<S>(&self, client: &Client, stream: S, host: &str) -> Result<()>
    where
        S: AsyncRead + AsyncWrite + Unpin + Send + 'static,
    {
        use tokio_postgres::tls::MakeTlsConnect;
        let tls = <MakeRustlsConnect as MakeTlsConnect<EofOnShutdown<S>>>::make_tls_connect(
            &mut self.tls.clone(),
            host,
        )
        .map_err(Error::driver)?;
        client
            .cancel_token()
            .cancel_query_raw(EofOnShutdown(stream), tls)
            .await
            .map_err(driver)
    }
}

/// Applies to plaintext and underneath rustls: once all cancellation bytes (and
/// TLS close-notify) are written, consume the peer's closure through TCP EOF.
struct EofOnShutdown<S>(S);
impl<S: AsyncRead + Unpin> AsyncRead for EofOnShutdown<S> {
    fn poll_read(
        mut self: Pin<&mut Self>,
        cx: &mut Context<'_>,
        buf: &mut ReadBuf<'_>,
    ) -> Poll<std::io::Result<()>> {
        Pin::new(&mut self.0).poll_read(cx, buf)
    }
}
impl<S: AsyncRead + AsyncWrite + Unpin> AsyncWrite for EofOnShutdown<S> {
    fn poll_write(
        mut self: Pin<&mut Self>,
        cx: &mut Context<'_>,
        buf: &[u8],
    ) -> Poll<std::io::Result<usize>> {
        Pin::new(&mut self.0).poll_write(cx, buf)
    }
    fn poll_flush(mut self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<std::io::Result<()>> {
        Pin::new(&mut self.0).poll_flush(cx)
    }
    fn poll_shutdown(mut self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<std::io::Result<()>> {
        std::task::ready!(Pin::new(&mut self.0).poll_shutdown(cx))?;
        loop {
            let mut bytes = [0; 1024];
            let mut buf = ReadBuf::new(&mut bytes);
            std::task::ready!(Pin::new(&mut self.0).poll_read(cx, &mut buf))?;
            if buf.filled().is_empty() {
                return Poll::Ready(Ok(()));
            }
        }
    }
}

// Match SQLx's explicit SSL modes: only verify-ca/full authenticate the server.
// Even non-authenticating modes still verify the TLS handshake signatures.
#[derive(Debug)]
struct Verifier {
    verify_ca: bool,
    roots: Arc<rustls::RootCertStore>,
    provider: Arc<rustls::crypto::CryptoProvider>,
}
impl rustls::client::danger::ServerCertVerifier for Verifier {
    fn verify_server_cert(
        &self,
        cert: &rustls::pki_types::CertificateDer<'_>,
        intermediates: &[rustls::pki_types::CertificateDer<'_>],
        _: &rustls::pki_types::ServerName<'_>,
        _: &[u8],
        now: rustls::pki_types::UnixTime,
    ) -> std::result::Result<rustls::client::danger::ServerCertVerified, rustls::Error> {
        if self.verify_ca {
            let cert = rustls::server::ParsedCertificate::try_from(cert)?;
            rustls::client::verify_server_cert_signed_by_trust_anchor(
                &cert,
                &self.roots,
                intermediates,
                now,
                self.provider.signature_verification_algorithms.all,
            )?;
        }
        Ok(rustls::client::danger::ServerCertVerified::assertion())
    }
    fn verify_tls12_signature(
        &self,
        message: &[u8],
        cert: &rustls::pki_types::CertificateDer<'_>,
        signature: &rustls::DigitallySignedStruct,
    ) -> std::result::Result<rustls::client::danger::HandshakeSignatureValid, rustls::Error> {
        rustls::crypto::verify_tls12_signature(
            message,
            cert,
            signature,
            &self.provider.signature_verification_algorithms,
        )
    }
    fn verify_tls13_signature(
        &self,
        message: &[u8],
        cert: &rustls::pki_types::CertificateDer<'_>,
        signature: &rustls::DigitallySignedStruct,
    ) -> std::result::Result<rustls::client::danger::HandshakeSignatureValid, rustls::Error> {
        rustls::crypto::verify_tls13_signature(
            message,
            cert,
            signature,
            &self.provider.signature_verification_algorithms,
        )
    }
    fn supported_verify_schemes(&self) -> Vec<rustls::SignatureScheme> {
        self.provider
            .signature_verification_algorithms
            .supported_schemes()
    }
}

fn retryable(error: &tokio_postgres::Error) -> bool {
    use std::error::Error as _;
    let mut source = error.source();
    while let Some(error) = source {
        if let Some(io) = error.downcast_ref::<std::io::Error>() {
            return matches!(
                io.kind(),
                std::io::ErrorKind::ConnectionReset
                    | std::io::ErrorKind::ConnectionAborted
                    | std::io::ErrorKind::UnexpectedEof
                    | std::io::ErrorKind::BrokenPipe
            );
        }
        source = error.source();
    }
    false
}

pub(super) fn driver(error: tokio_postgres::Error) -> Error {
    if error.code() == Some(&tokio_postgres::error::SqlState::QUERY_CANCELED) {
        return Error::Cancelled;
    }
    Error::driver(
        error
            .as_db_error()
            .map_or_else(|| error.to_string(), |db| db.to_string()),
    )
}

pub(super) fn commit_error(error: tokio_postgres::Error) -> Error {
    if error.as_db_error().is_some() {
        driver(error)
    } else {
        Error::driver(format!(
            "PostgreSQL commit outcome unknown; verify edits before retrying: {error}"
        ))
    }
}

#[derive(Debug)]
pub(super) struct Session {
    retired: AtomicBool,
    client: tokio::sync::RwLock<Option<Arc<Client>>>,
    task: Mutex<Option<tokio::task::JoinHandle<()>>>,
}
impl Session {
    /// Drop must retire synchronously, before the execution mutex is released.
    pub(super) fn in_flight(&self) -> InFlight<'_> {
        InFlight {
            session: self,
            complete: false,
        }
    }
    fn retire_now(&self) {
        self.retired.store(true, Ordering::Release);
        if let Some(task) = self.task.lock().unwrap().take() {
            task.abort();
        }
    }
    pub(super) async fn retire(&self) {
        self.retire_now();
        self.client.write().await.take();
    }
    pub(super) async fn client(&self) -> Result<Arc<Client>> {
        if self.retired.load(Ordering::Acquire) {
            return Err(Error::driver("PostgreSQL connection is retired"));
        }
        let client = self
            .client
            .read()
            .await
            .clone()
            .ok_or_else(|| Error::driver("PostgreSQL connection is closed"))?;
        if self.retired.load(Ordering::Acquire) {
            return Err(Error::driver("PostgreSQL connection is retired"));
        }
        Ok(client)
    }
    pub(super) async fn close(&self) {
        self.client.write().await.take();
        let task = self.task.lock().unwrap().take();
        if let Some(mut task) = task
            && tokio::time::timeout(crate::STOP_TIMEOUT, &mut task)
                .await
                .is_err()
        {
            task.abort();
        }
    }
}
pub(super) struct InFlight<'a> {
    session: &'a Session,
    complete: bool,
}
impl InFlight<'_> {
    pub(super) fn complete(&mut self) {
        self.complete = true;
    }
}
impl Drop for InFlight<'_> {
    fn drop(&mut self) {
        if !self.complete {
            self.session.retire_now();
        }
    }
}
impl Drop for Session {
    fn drop(&mut self) {
        if let Some(task) = self.task.get_mut().unwrap().take() {
            task.abort();
        }
    }
}

// These helpers only issue native extended-protocol catalog queries; they are not an execution layer.
pub(super) struct Query<'a, T> {
    sql: &'a str,
    params: Vec<Box<dyn ToSql + Sync + Send + 'a>>,
    decode: fn(Row) -> std::result::Result<T, tokio_postgres::Error>,
    marker: PhantomData<T>,
}
pub(super) fn query(sql: &str) -> Query<'_, Row> {
    Query {
        sql,
        params: Vec::new(),
        decode: Ok,
        marker: PhantomData,
    }
}
pub(super) fn query_as<T: CatalogRow>(sql: &str) -> Query<'_, T> {
    Query {
        sql,
        params: Vec::new(),
        decode: T::decode,
        marker: PhantomData,
    }
}
pub(super) fn query_scalar<T: FromSqlOwned>(sql: &str) -> Query<'_, T> {
    Query {
        sql,
        params: Vec::new(),
        decode: |row| row.try_get(0),
        marker: PhantomData,
    }
}
impl<'a, T> Query<'a, T> {
    pub(super) fn bind(mut self, value: impl ToSql + Sync + Send + 'a) -> Self {
        self.params.push(Box::new(value));
        self
    }
    pub(super) async fn fetch_all(self, session: &Session) -> Result<Vec<T>> {
        let params: Vec<&(dyn ToSql + Sync)> = self.params.iter().map(|p| &**p as _).collect();
        session
            .client()
            .await?
            .query(self.sql, &params)
            .await
            .map_err(driver)?
            .into_iter()
            .map(|row| (self.decode)(row).map_err(driver))
            .collect()
    }
    pub(super) async fn fetch_optional(self, session: &Session) -> Result<Option<T>> {
        Ok(self.fetch_all(session).await?.into_iter().next())
    }
    pub(super) async fn fetch_one(self, session: &Session) -> Result<T> {
        self.fetch_optional(session)
            .await?
            .ok_or_else(|| Error::driver("catalog query returned no row"))
    }
}
pub(super) trait CatalogRow: Sized {
    fn decode(row: Row) -> std::result::Result<Self, tokio_postgres::Error>;
}
macro_rules! tuple {
    ($($t:ident:$i:tt),+) => {
        impl<$($t: FromSqlOwned),+> CatalogRow for ($($t,)+) {
            fn decode(row: Row) -> std::result::Result<Self,tokio_postgres::Error> { Ok(($(row.try_get::<_, $t>($i)?,)+)) }
        }
    }
}
tuple!(A:0,B:1);
tuple!(A:0,B:1,C:2,D:3);
tuple!(A:0,B:1,C:2,D:3,E:4);
tuple!(A:0,B:1,C:2,D:3,E:4,F:5,G:6);

pub(super) fn foreign_key(row: &Row) -> Option<sqmeow_db::types::ForeignKey> {
    Some(sqmeow_db::types::ForeignKey {
        table: row
            .try_get::<_, Option<String>>("references_table")
            .ok()??,
        column: row
            .try_get::<_, Option<String>>("references_column")
            .ok()??,
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use tokio::io::{AsyncReadExt, AsyncWriteExt};

    #[test]
    fn disabled_tls_does_not_read_certificate_files() {
        assert!(Options::parse(
            "postgres://user@localhost/db?sslmode=disable&sslrootcert=/nonexistent/sqmeow-root&sslcert=/nonexistent/sqmeow-cert&sslkey=/nonexistent/sqmeow-key",
            None,
        ).is_ok());
    }

    #[tokio::test]
    async fn cancellation_shutdown_waits_for_peer_eof() {
        let (local, mut peer) = tokio::io::duplex(128);
        let mut stream = EofOnShutdown(local);
        stream.write_all(b"cancel").await.unwrap();
        let waiter = tokio::spawn(async move { stream.shutdown().await });
        let mut packet = Vec::new();
        peer.read_to_end(&mut packet).await.unwrap();
        assert_eq!(packet, b"cancel");
        assert!(
            !waiter.is_finished(),
            "write shutdown is not cancellation acknowledgment"
        );
        // Also tolerate TLS closure bytes before transport EOF.
        peer.write_all(b"peer closure").await.unwrap();
        drop(peer);
        waiter.await.unwrap().unwrap();
    }

    #[tokio::test]
    async fn cancellation_shutdown_can_be_deadlined_without_peer_eof() {
        let (local, _peer) = tokio::io::duplex(128);
        let mut stream = EofOnShutdown(local);
        assert!(
            tokio::time::timeout(std::time::Duration::from_millis(20), stream.shutdown(),)
                .await
                .is_err()
        );
    }

    #[tokio::test]
    async fn retired_session_aborts_its_driver_and_rejects_reuse() {
        let (sender, receiver) = tokio::sync::oneshot::channel::<()>();
        let task = tokio::spawn(async move {
            let _sender = sender;
            std::future::pending::<()>().await;
        });
        let session = Session {
            retired: AtomicBool::new(false),
            client: tokio::sync::RwLock::new(None),
            task: Mutex::new(Some(task)),
        };
        session.retire().await;
        assert!(session.client().await.is_err());
        assert!(
            receiver.await.is_err(),
            "retirement must abort the socket driver"
        );
    }

    #[tokio::test]
    async fn dropped_in_flight_guard_retires_synchronously() {
        let session = Session {
            retired: AtomicBool::new(false),
            client: tokio::sync::RwLock::new(None),
            task: Mutex::new(None),
        };
        let mut complete = session.in_flight();
        complete.complete();
        drop(complete);
        assert!(!session.retired.load(Ordering::Acquire));
        drop(session.in_flight());
        assert!(session.retired.load(Ordering::Acquire));
        assert!(
            session
                .client()
                .await
                .unwrap_err()
                .to_string()
                .contains("retired")
        );
    }

    #[tokio::test]
    async fn commit_transport_error_warns_against_blind_retry() {
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let port = listener.local_addr().unwrap().port();
        let closer = tokio::spawn(async move {
            let (stream, _) = listener.accept().await.unwrap();
            drop(stream);
        });
        let error = Config::new()
            .host("127.0.0.1")
            .port(port)
            .user("test")
            .connect(tokio_postgres::NoTls)
            .await
            .err()
            .unwrap();
        closer.await.unwrap();
        let message = commit_error(error).to_string();
        assert!(message.contains("commit outcome unknown"), "{message}");
        assert!(
            message.contains("verify edits before retrying"),
            "{message}"
        );
    }
}
