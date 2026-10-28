//! TLS trust selection for every outgoing `reqwest` client.
//!
//! reqwest 0.13 verifies certificates through `rustls-platform-verifier`. That
//! works out of the box on Windows, macOS, iOS and Linux, but on Android it
//! must be initialised over JNI with a bundled Kotlin helper, which this app
//! does not ship. Until it is initialised the verifier cannot run, so every
//! HTTPS request fails (Bangumi, covers, OAuth, update checks, WebDAV).
//! reqwest 0.12, used by 1.1.1, trusted the bundled Mozilla roots instead.
//!
//! Android therefore goes back to the bundled roots. Every other platform
//! keeps the operating-system verifier, so user/enterprise roots (for example
//! a local proxy's CA) still work there. Android no longer honours roots the
//! user installed in system settings, exactly as in 1.1.1.

/// Applies the platform's TLS trust policy to `builder`.
///
/// A no-op everywhere except Android.
pub(crate) fn configure(builder: reqwest::ClientBuilder) -> reqwest::ClientBuilder {
    #[cfg(target_os = "android")]
    {
        builder.tls_backend_preconfigured(bundled_roots_config())
    }
    #[cfg(not(target_os = "android"))]
    {
        builder
    }
}

/// rustls client configuration that trusts the compiled-in Mozilla roots.
///
/// Kept separate from [`configure`] so the exact configuration can be checked
/// by unit tests on any host that builds it.
#[cfg(any(target_os = "android", test))]
pub(crate) fn bundled_roots_config() -> rustls::ClientConfig {
    let roots = rustls::RootCertStore {
        roots: webpki_roots::TLS_SERVER_ROOTS.to_vec(),
    };
    let mut config = rustls::ClientConfig::builder_with_provider(std::sync::Arc::new(
        rustls::crypto::aws_lc_rs::default_provider(),
    ))
    .with_safe_default_protocol_versions()
    .expect("aws-lc-rs supports the default TLS versions")
    .with_root_certificates(roots)
    .with_no_client_auth();
    // reqwest would set the same list for its own rustls backend; a
    // preconfigured config is used as-is, so HTTP/2 negotiation is set here.
    config.alpn_protocols = vec![b"h2".to_vec(), b"http/1.1".to_vec()];
    config
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn bundled_config_negotiates_http2_then_http1() {
        let config = bundled_roots_config();
        assert_eq!(
            config.alpn_protocols,
            vec![b"h2".to_vec(), b"http/1.1".to_vec()]
        );
    }

    #[test]
    fn bundled_config_builds_a_working_reqwest_client() {
        // `tls_backend_preconfigured` silently falls back to an "unknown
        // backend" error at build time if the rustls versions ever diverge
        // from reqwest's, so building proves the types still line up.
        let client = reqwest::Client::builder()
            .tls_backend_preconfigured(bundled_roots_config())
            .build();
        assert!(client.is_ok(), "{client:?}");
    }

    #[test]
    fn configure_never_breaks_client_construction() {
        assert!(configure(reqwest::Client::builder()).build().is_ok());
    }
}
