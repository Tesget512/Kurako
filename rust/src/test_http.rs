//! A minimal scripted HTTP/1.1 server for transport tests.
//!
//! Production code never links this: it exists so OAuth and personal-token
//! request paths, form fields, headers and fail-closed behavior can be tested
//! against a loopback endpoint instead of a real provider. Every response is
//! scripted and every request is captured; nothing here touches the network
//! beyond `127.0.0.1`.

use std::collections::VecDeque;
use std::sync::{Arc, Mutex};

use tokio::io::{AsyncBufReadExt, AsyncReadExt, AsyncWriteExt, BufReader};
use tokio::net::{TcpListener, TcpStream};

/// One request as the server saw it. Bodies are kept raw; tests decode them.
#[derive(Clone)]
pub(crate) struct CapturedRequest {
    pub method: String,
    pub path: String,
    pub headers: Vec<(String, String)>,
    pub body: Vec<u8>,
}

impl CapturedRequest {
    pub fn header(&self, name: &str) -> Option<&str> {
        let lower = name.to_ascii_lowercase();
        self.headers
            .iter()
            .find(|(k, _)| k.to_ascii_lowercase() == lower)
            .map(|(_, v)| v.as_str())
    }
}

/// What the server does with the n-th connection.
pub(crate) enum ScriptedStep {
    Respond {
        status: u16,
        headers: Vec<(String, String)>,
        body: Vec<u8>,
    },
    /// Accept the connection and never answer; used to exercise timeouts.
    Silence,
    /// Accept the connection and close it without a response.
    Close,
}

pub(crate) fn respond_json(status: u16, body: impl Into<Vec<u8>>) -> ScriptedStep {
    ScriptedStep::Respond {
        status,
        headers: vec![("Content-Type".into(), "application/json".into())],
        body: body.into(),
    }
}

pub(crate) fn respond(status: u16, content_type: &str, body: Vec<u8>) -> ScriptedStep {
    ScriptedStep::Respond {
        status,
        headers: vec![("Content-Type".into(), content_type.into())],
        body,
    }
}

pub(crate) struct MockHttpServer {
    port: u16,
    requests: Arc<Mutex<Vec<CapturedRequest>>>,
    handle: tokio::task::JoinHandle<()>,
}

impl MockHttpServer {
    /// Bind a loopback listener. The n-th accepted connection runs the n-th
    /// scripted step; connections beyond the script get a bare 500.
    pub(crate) async fn start(script: Vec<ScriptedStep>) -> Self {
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let port = listener.local_addr().unwrap().port();
        let requests: Arc<Mutex<Vec<CapturedRequest>>> = Arc::new(Mutex::new(Vec::new()));
        let script: Arc<Mutex<VecDeque<ScriptedStep>>> = Arc::new(Mutex::new(script.into()));
        let sink = Arc::clone(&requests);
        let handle = tokio::spawn(async move {
            loop {
                let Ok((stream, _)) = listener.accept().await else {
                    break;
                };
                let step = script.lock().unwrap().pop_front();
                let sink = Arc::clone(&sink);
                tokio::spawn(async move {
                    handle_connection(stream, step, sink).await;
                });
            }
        });
        Self {
            port,
            requests,
            handle,
        }
    }

    pub(crate) fn base_url(&self) -> String {
        format!("http://127.0.0.1:{}", self.port)
    }

    pub(crate) fn requests(&self) -> Vec<CapturedRequest> {
        self.requests.lock().unwrap().clone()
    }

    /// One line of response text per request, for quick assertions.
    pub(crate) fn request_lines(&self) -> Vec<String> {
        self.requests()
            .iter()
            .map(|r| format!("{} {}", r.method, r.path))
            .collect()
    }

    pub(crate) fn abort(&self) {
        self.handle.abort();
    }
}

async fn handle_connection(
    stream: TcpStream,
    step: Option<ScriptedStep>,
    sink: Arc<Mutex<Vec<CapturedRequest>>>,
) {
    let (read_half, mut write_half) = stream.into_split();
    let mut reader = BufReader::new(read_half);

    // Read the request head.
    let mut head = Vec::new();
    match reader.read_until(b'\n', &mut head).await {
        Ok(0) | Err(_) => return,
        Ok(_) => {}
    }
    let mut head_text = String::from_utf8_lossy(&head).into_owned();
    loop {
        let mut line = Vec::new();
        match reader.read_until(b'\n', &mut line).await {
            Ok(0) | Err(_) => return,
            Ok(_) => {}
        }
        let trimmed = String::from_utf8_lossy(&line).into_owned();
        if trimmed == "\r\n" || trimmed == "\n" {
            break;
        }
        head_text.push_str(&trimmed);
    }

    let mut lines = head_text.split("\r\n");
    let request_line = lines.next().unwrap_or_default().to_string();
    let mut parts = request_line.split_whitespace();
    let method = parts.next().unwrap_or_default().to_string();
    let path = parts.next().unwrap_or_default().to_string();

    let mut content_length = 0usize;
    let mut headers = Vec::new();
    for line in lines {
        if let Some((name, value)) = line.split_once(':') {
            let name = name.trim().to_string();
            let value = value.trim().to_string();
            if name.eq_ignore_ascii_case("content-length") {
                content_length = value.parse().unwrap_or(0);
            }
            headers.push((name, value));
        }
    }

    let mut body = vec![0u8; content_length];
    if content_length > 0 && reader.read_exact(&mut body).await.is_err() {
        return;
    }

    sink.lock().unwrap().push(CapturedRequest {
        method,
        path,
        headers,
        body,
    });

    match step {
        Some(ScriptedStep::Silence) => {
            // Hold the connection open without answering; the caller's
            // timeout is what ends this.
            std::future::pending::<()>().await;
        }
        Some(ScriptedStep::Close) => {}
        Some(ScriptedStep::Respond {
            status,
            headers,
            body,
        }) => {
            let reason = match status {
                200 => "OK",
                201 => "Created",
                202 => "Accepted",
                302 => "Found",
                400 => "Bad Request",
                401 => "Unauthorized",
                403 => "Forbidden",
                404 => "Not Found",
                502 => "Bad Gateway",
                _ => "Status",
            };
            let mut response = format!("HTTP/1.1 {status} {reason}\r\n");
            for (name, value) in &headers {
                response.push_str(&format!("{name}: {value}\r\n"));
            }
            response.push_str(&format!("Content-Length: {}\r\n", body.len()));
            response.push_str("Connection: close\r\n\r\n");
            let _ = write_half.write_all(response.as_bytes()).await;
            let _ = write_half.write_all(&body).await;
            let _ = write_half.flush().await;
        }
        None => {
            let _ = write_half
                .write_all(
                    b"HTTP/1.1 500 Internal Server Error\r\nContent-Length: 0\r\nConnection: close\r\n\r\n",
                )
                .await;
        }
    }
    let _ = write_half.shutdown().await;
}
