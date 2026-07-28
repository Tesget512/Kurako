//! Bounded, side-effect-free local file-server discovery.
//!
//! DNS-SD is handled by Flutter's cross-platform `nsd` plugin. This module adds
//! WS-Discovery for Windows 10/11 hosts which usually do not advertise SMB over
//! Bonjour. It sends one standards-based multicast probe per active IPv4
//! interface and only consumes responses; it never scans a subnet or connects
//! to TCP/445.

use crate::models::DiscoveredServer;
use quick_xml::events::Event;
use quick_xml::Reader;
use std::collections::BTreeMap;
use std::net::{IpAddr, Ipv4Addr, SocketAddr};
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::{Duration, SystemTime, UNIX_EPOCH};
use tokio::net::UdpSocket;

const WSD_MULTICAST: &str = "239.255.255.250:3702";
const DISCOVERY_WINDOW: Duration = Duration::from_millis(2400);
const MAX_DATAGRAM_BYTES: usize = 64 * 1024;
const MAX_RESULTS: usize = 64;
static PROBE_ID: AtomicU64 = AtomicU64::new(1);

pub async fn discover_windows_file_servers() -> Vec<DiscoveredServer> {
    let interfaces = match if_addrs::get_if_addrs() {
        Ok(interfaces) => interfaces,
        Err(_) => return Vec::new(),
    };
    let futures = interfaces.into_iter().filter_map(|interface| {
        let IpAddr::V4(ip) = interface.ip() else {
            return None;
        };
        if ip.is_loopback() || ip.is_unspecified() || ip.is_link_local() {
            return None;
        }
        Some(discover_on_interface(ip))
    });
    let mut by_host = BTreeMap::new();
    for servers in futures::future::join_all(futures).await {
        for server in servers {
            by_host.entry(server.host.clone()).or_insert(server);
            if by_host.len() >= MAX_RESULTS {
                break;
            }
        }
    }
    by_host.into_values().collect()
}

async fn discover_on_interface(ip: Ipv4Addr) -> Vec<DiscoveredServer> {
    let socket = match UdpSocket::bind(SocketAddr::from((ip, 0))).await {
        Ok(socket) => socket,
        Err(_) => return Vec::new(),
    };
    let _ = socket.set_multicast_ttl_v4(1);
    let message = probe_message();
    if socket
        .send_to(message.as_bytes(), WSD_MULTICAST)
        .await
        .is_err()
    {
        return Vec::new();
    }

    let deadline = tokio::time::Instant::now() + DISCOVERY_WINDOW;
    let mut buffer = vec![0u8; MAX_DATAGRAM_BYTES];
    let mut found = BTreeMap::new();
    loop {
        let now = tokio::time::Instant::now();
        if now >= deadline || found.len() >= MAX_RESULTS {
            break;
        }
        let received = tokio::time::timeout_at(deadline, socket.recv_from(&mut buffer)).await;
        let Ok(Ok((size, _peer))) = received else {
            break;
        };
        if size == 0 || size > MAX_DATAGRAM_BYTES {
            continue;
        }
        for server in parse_probe_response(&buffer[..size]) {
            found.entry(server.host.clone()).or_insert(server);
        }
    }
    found.into_values().collect()
}

fn probe_message() -> String {
    let seconds = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|duration| duration.as_nanos())
        .unwrap_or(0);
    let id = PROBE_ID.fetch_add(1, Ordering::Relaxed);
    format!(
        r#"<?xml version="1.0" encoding="UTF-8"?>
<e:Envelope xmlns:e="http://www.w3.org/2003/05/soap-envelope"
 xmlns:w="http://schemas.xmlsoap.org/ws/2004/08/addressing"
 xmlns:d="http://schemas.xmlsoap.org/ws/2005/04/discovery">
 <e:Header>
  <w:MessageID>urn:uuid:{seconds:032x}-{id:016x}</w:MessageID>
  <w:To e:mustUnderstand="true">urn:schemas-xmlsoap-org:ws:2005:04:discovery</w:To>
  <w:Action e:mustUnderstand="true">http://schemas.xmlsoap.org/ws/2005/04/discovery/Probe</w:Action>
 </e:Header>
 <e:Body><d:Probe /></e:Body>
</e:Envelope>"#
    )
}

fn parse_probe_response(bytes: &[u8]) -> Vec<DiscoveredServer> {
    let mut reader = Reader::from_reader(bytes);
    reader.config_mut().trim_text(true);
    let mut current = Vec::new();
    let mut xaddrs = Vec::new();
    loop {
        match reader.read_event() {
            Ok(Event::Start(start)) => {
                current = start.local_name().as_ref().to_vec();
            }
            Ok(Event::Text(text)) if current.as_slice() == b"XAddrs" => {
                if let Ok(value) = text.decode() {
                    xaddrs.extend(value.split_whitespace().map(str::to_string));
                }
            }
            Ok(Event::End(_)) => current.clear(),
            Ok(Event::Eof) | Err(_) => break,
            _ => {}
        }
    }

    let mut hosts = BTreeMap::new();
    for address in xaddrs {
        let Ok(url) = reqwest::Url::parse(&address) else {
            continue;
        };
        let Some(host) = url.host_str() else {
            continue;
        };
        let host = host.trim_matches(['[', ']']).to_string();
        if host.is_empty() {
            continue;
        }
        hosts.entry(host.clone()).or_insert(DiscoveredServer {
            name: host.clone(),
            host,
            port: 445,
            protocol: "smb".to_string(),
            discovery_source: "WS-Discovery".to_string(),
        });
    }
    hosts.into_values().collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_windows_probe_match_without_scanning() {
        let xml = br#"<?xml version="1.0"?>
        <s:Envelope xmlns:s="http://www.w3.org/2003/05/soap-envelope"
          xmlns:d="http://schemas.xmlsoap.org/ws/2005/04/discovery">
          <s:Body><d:ProbeMatches><d:ProbeMatch>
          <d:XAddrs>http://192.0.2.211:5357/abc https://server.local/wsd</d:XAddrs>
          </d:ProbeMatch></d:ProbeMatches></s:Body>
        </s:Envelope>"#;
        let servers = parse_probe_response(xml);
        assert_eq!(servers.len(), 2);
        assert!(servers.iter().any(|server| server.host == "192.0.2.211"));
        assert!(servers.iter().all(|server| server.port == 445));
    }

    #[test]
    fn ignores_malformed_xml_and_urls() {
        assert!(parse_probe_response(b"not xml").is_empty());
        let xml = br#"<XAddrs>not-a-url</XAddrs>"#;
        assert!(parse_probe_response(xml).is_empty());
    }
}
