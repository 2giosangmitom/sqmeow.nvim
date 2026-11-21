//! Connection-URL and TLS helpers for adapters that read their own URLs.

use std::sync::Arc;

use percent_encoding::percent_decode_str;
use sqmeow_db::error::{Error, Result};

/// Percent-decode one URL component as UTF-8.
pub(crate) fn decode(text: &str) -> Result<String> {
    percent_decode_str(text)
        .decode_utf8()
        .map(|text| text.into_owned())
        .map_err(Error::driver)
}

/// The undecoded pieces of `scheme://login@authority/path?options`.
pub(crate) struct UrlParts<'a> {
    pub scheme: &'a str,
    pub login: Option<&'a str>,
    pub authority: &'a str,
    pub path: &'a str,
    pub options: &'a str,
}

/// Split a URL at `://`, `?`, the first `/` and the last `@` of the authority.
pub(crate) fn split_url(url: &str) -> Result<UrlParts<'_>> {
    let (scheme, rest) = url
        .split_once("://")
        .ok_or_else(|| Error::UnsupportedUrl(url.to_owned()))?;
    let (rest, options) = rest.split_once('?').unwrap_or((rest, ""));
    let (authority, path) = rest.split_once('/').unwrap_or((rest, ""));
    let (login, authority) = match authority.rsplit_once('@') {
        Some((login, authority)) => (Some(login), authority),
        None => (None, authority),
    };
    Ok(UrlParts {
        scheme,
        login,
        authority,
        path,
        options,
    })
}

/// Split `user:password` and decode both halves; a missing password is empty.
pub(crate) fn credentials(login: &str) -> Result<(String, String)> {
    let (user, password) = login.split_once(':').unwrap_or((login, ""));
    Ok((decode(user)?, decode(password)?))
}

/// `host` with `port` appended unless it names one; an empty host is localhost.
pub(crate) fn with_port(host: &str, port: u16) -> String {
    let host = if host.is_empty() { "localhost" } else { host };
    // A bracketed IPv6 address has colons of its own.
    if host.ends_with(']') || !host.contains(':') {
        format!("{host}:{port}")
    } else {
        host.to_owned()
    }
}

/// A TLS configuration trusting the machine's roots and the certificates in the `ca` file.
pub(crate) fn tls_config(ca: Option<&str>) -> Result<Arc<rustls::ClientConfig>> {
    let mut roots = rustls::RootCertStore::empty();
    for certificate in rustls_native_certs::load_native_certs().certs {
        // A root the machine holds that rustls cannot read is one fewer to trust, not a failure.
        let _ = roots.add(certificate);
    }
    if let Some(path) = ca {
        use rustls::pki_types::CertificateDer;
        use rustls::pki_types::pem::PemObject;

        let certificates = CertificateDer::pem_file_iter(path)
            .map_err(|error| Error::driver(format!("`{path}` could not be read: {error}")))?;
        for certificate in certificates {
            let certificate = certificate.map_err(|error| {
                Error::driver(format!("`{path}` holds no certificate: {error}"))
            })?;
            roots.add(certificate).map_err(Error::driver)?;
        }
    }
    let provider = Arc::new(rustls::crypto::ring::default_provider());
    let config = rustls::ClientConfig::builder_with_provider(provider)
        .with_safe_default_protocol_versions()
        .map_err(Error::driver)?
        .with_root_certificates(roots)
        .with_no_client_auth();
    Ok(Arc::new(config))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_tls_configuration_trusts_the_machine_and_refuses_a_missing_ca_file() {
        assert!(tls_config(None).is_ok());
        let error = tls_config(Some("/nonexistent/ca.pem")).unwrap_err();
        assert!(error.to_string().contains("/nonexistent/ca.pem"), "{error}");
    }

    #[test]
    fn hosts_get_a_default_port_unless_they_name_one() {
        assert_eq!(with_port("", 1), "localhost:1");
        assert_eq!(with_port("db:5", 1), "db:5");
        assert_eq!(with_port("[::1]", 1), "[::1]:1");
        assert_eq!(with_port("[::1]:5", 1), "[::1]:5");
    }
}
