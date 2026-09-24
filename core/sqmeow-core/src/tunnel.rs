//! Opens SSH tunnels to reach databases.

use std::process::Stdio;
use std::time::Duration;

use sqmeow_db::Dialect;
use tokio::io::AsyncReadExt;
use tokio::net::TcpStream;
use tokio::process::{Child, Command};

/// An `ssh` forwarding a local port, stopped when dropped.
#[derive(Debug)]
pub struct Tunnel {
    _child: Child,
}

/// Forward a free local port through `ssh` to `via`, written `user@host` or `user@host:port`, on to
/// the database `url` names, and answer with the URL rewritten to reach it through the tunnel.
pub async fn open(program: &str, url: &str, via: &str) -> Result<(String, Tunnel), String> {
    let (scheme, rest) = url
        .split_once("://")
        .ok_or("a tunnel needs a URL that names a host")?;
    let default = match Dialect::from_url(url).ok_or("a tunnel needs a URL the plugin speaks")? {
        Dialect::Postgres => 5432,
        Dialect::MySql => 3306,
        Dialect::Redis => 6379,
        Dialect::MongoDb => 27017,
        Dialect::Scylla => 9042,
        Dialect::SurrealDb => 8000,
        Dialect::ClickHouse if scheme.eq_ignore_ascii_case("clickhouses") => 8443,
        Dialect::ClickHouse => 8123,
        Dialect::Oracle if scheme.eq_ignore_ascii_case("oracletcps") => 2484,
        Dialect::Oracle => 1521,
        Dialect::Sqlite | Dialect::DuckDb => {
            return Err("a database in a file is not reached through a tunnel".to_owned());
        }
    };
    if scheme.eq_ignore_ascii_case("mongodb+srv") {
        return Err(
            "a MongoDB SRV address finds its hosts in DNS, so it cannot go through one tunnel"
                .to_owned(),
        );
    }

    let end = rest.find(['/', '?', '#']).unwrap_or(rest.len());
    let (authority, tail) = rest.split_at(end);
    let (login, address) = match authority.rsplit_once('@') {
        Some((login, address)) => (Some(login), address),
        None => (None, authority),
    };
    if address.contains(',') {
        return Err("a tunnel reaches one host, and the URL names several".to_owned());
    }
    let (host, port) = split_address(address, default)?;
    let (destination, ssh_port) = match via.rsplit_once(':') {
        Some((destination, port)) if port.parse::<u16>().is_ok() => (destination, Some(port)),
        _ => (via, None),
    };

    let local = std::net::TcpListener::bind("127.0.0.1:0")
        .and_then(|listener| listener.local_addr())
        .map_err(|error| format!("no local port is free for the tunnel: {error}"))?
        .port();
    let mut command = Command::new(program);
    command
        .args([
            "-N",
            "-o",
            "ExitOnForwardFailure=yes",
            "-o",
            "BatchMode=yes",
            "-L",
        ])
        .arg(format!("127.0.0.1:{local}:{host}:{port}"));
    if let Some(port) = ssh_port {
        command.args(["-p", port]);
    }
    let mut child = command
        .arg(destination)
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::piped())
        .kill_on_drop(true)
        .spawn()
        .map_err(|error| format!("`{program}` could not be started: {error}"))?;

    let deadline = tokio::time::Instant::now() + sqmeow_adapters::CONNECT_TIMEOUT;
    while TcpStream::connect(("127.0.0.1", local)).await.is_err() {
        if let Ok(Some(status)) = child.try_wait() {
            let mut stderr = String::new();
            if let Some(mut pipe) = child.stderr.take() {
                let _ = pipe.read_to_string(&mut stderr).await;
            }
            return Err(format!(
                "ssh to `{via}` exited with {status}: {}",
                stderr.trim()
            ));
        }
        if tokio::time::Instant::now() >= deadline {
            return Err(format!("ssh to `{via}` did not open the tunnel in time"));
        }
        tokio::time::sleep(Duration::from_millis(100)).await;
    }

    let login = login.map_or_else(String::new, |login| format!("{login}@"));
    Ok((
        format!("{scheme}://{login}127.0.0.1:{local}{tail}"),
        Tunnel { _child: child },
    ))
}

/// A host and its port, `default` when the address names none.
fn split_address(address: &str, default: u16) -> Result<(String, u16), String> {
    let (host, port) = match address.strip_prefix('[') {
        Some(rest) => {
            let (host, after) = rest
                .split_once(']')
                .ok_or("an IPv6 address is missing its `]`")?;
            (format!("[{host}]"), after.strip_prefix(':'))
        }
        None => match address.rsplit_once(':') {
            Some((host, port)) => (host.to_owned(), Some(port)),
            None => (address.to_owned(), None),
        },
    };
    let host = if host.is_empty() {
        "localhost".to_owned()
    } else {
        host
    };
    let port = match port {
        Some(port) => port
            .parse()
            .map_err(|_| format!("`{port}` is not a port"))?,
        None => default,
    };
    Ok((host, port))
}

#[cfg(test)]
mod tests {
    use tokio::io::AsyncWriteExt;

    use super::*;

    /// A stand-in for `ssh` that forwards the `-L` port itself.
    const FORWARDING: &str = r#"#!/usr/bin/env python3
import socket, sys, threading
_, local, host, port = sys.argv[sys.argv.index("-L") + 1].rsplit(":", 3)
server = socket.socket()
server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
server.bind(("127.0.0.1", int(local)))
server.listen()
def pipe(source, sink):
    while data := source.recv(65536):
        sink.sendall(data)
    sink.shutdown(socket.SHUT_WR)
while True:
    client, _ = server.accept()
    upstream = socket.create_connection((host.strip("[]"), int(port)))
    threading.Thread(target=pipe, args=(client, upstream), daemon=True).start()
    threading.Thread(target=pipe, args=(upstream, client), daemon=True).start()
"#;

    fn script(name: &str, body: &str) -> String {
        use std::io::Write;
        use std::process::{Command, Stdio};

        let path = std::env::temp_dir().join(format!("sqmeow-{name}-{}", std::process::id()));
        // Written by a child: a write descriptor inherited by a process another test forks would
        // make running the script fail with ETXTBSY.
        let mut writer = Command::new("sh")
            .args(["-c", r#"cat > "$1" && chmod 755 "$1""#, "sh"])
            .arg(&path)
            .stdin(Stdio::piped())
            .spawn()
            .unwrap();
        writer
            .stdin
            .take()
            .unwrap()
            .write_all(body.as_bytes())
            .unwrap();
        assert!(writer.wait().unwrap().success());
        path.display().to_string()
    }

    #[tokio::test]
    async fn a_url_is_rewritten_to_reach_the_database_through_the_tunnel() {
        let database = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let port = database.local_addr().unwrap().port();
        tokio::spawn(async move {
            while let Ok((mut socket, _)) = database.accept().await {
                let _ = socket.write_all(b"hello").await;
            }
        });

        let ssh = script("ssh-forwarding", FORWARDING);
        let (url, _tunnel) = open(
            &ssh,
            &format!("postgres://app:pw@127.0.0.1:{port}/shop?sslmode=disable"),
            "me@bastion:2222",
        )
        .await
        .unwrap();

        let local: u16 = url
            .strip_prefix("postgres://app:pw@127.0.0.1:")
            .and_then(|rest| rest.strip_suffix("/shop?sslmode=disable"))
            .expect("the address is all that changes")
            .parse()
            .unwrap();
        assert_ne!(local, port);
        let mut stream = TcpStream::connect(("127.0.0.1", local)).await.unwrap();
        let mut greeting = String::new();
        stream.read_to_string(&mut greeting).await.unwrap();
        assert_eq!(greeting, "hello");
    }

    #[tokio::test]
    async fn an_ssh_that_fails_says_why() {
        let ssh = script(
            "ssh-refused",
            "#!/bin/sh\necho 'Permission denied (publickey).' >&2\nexit 255\n",
        );
        let error = open(&ssh, "mysql://root@db.internal/app", "me@bastion")
            .await
            .unwrap_err();
        assert!(error.contains("Permission denied"), "{error}");
    }

    #[tokio::test]
    async fn a_url_a_tunnel_cannot_carry_is_refused() {
        for url in [
            "sqlite:app.db",
            "mongodb+srv://cluster.example.net/app",
            "scylla://a,b/ks",
        ] {
            assert!(open("ssh", url, "me@bastion").await.is_err(), "{url}");
        }
    }

    #[test]
    fn an_address_takes_the_dialects_port_when_it_names_none() {
        assert_eq!(
            split_address("db.internal", 5432).unwrap(),
            ("db.internal".to_owned(), 5432)
        );
        assert_eq!(
            split_address("[::1]:6000", 5432).unwrap(),
            ("[::1]".to_owned(), 6000)
        );
        assert_eq!(
            split_address("", 3306).unwrap(),
            ("localhost".to_owned(), 3306)
        );
    }
}
