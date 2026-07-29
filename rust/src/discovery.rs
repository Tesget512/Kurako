//! Bounded, side-effect-free local file-server discovery.
//!
//! DNS-SD is handled by Flutter's cross-platform `nsd` plugin. This module uses
//! WS-Discovery for Windows 10/11 hosts which usually do not advertise SMB
//! over Bonjour. A bounded TCP/445 probe of the device's nearby IPv4 networks
//! complements it for iOS (where raw multicast needs a restricted entitlement)
//! and for NAS devices which advertise neither protocol.

use crate::models::DiscoveredServer;
use futures::stream::{self, StreamExt};
use if_addrs::IfAddr;
use quick_xml::events::Event;
use quick_xml::Reader;
use std::collections::BTreeMap;
use std::net::{Ipv4Addr, SocketAddr};
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::{Duration, SystemTime, UNIX_EPOCH};
use tokio::net::{TcpSocket, UdpSocket};

const WSD_MULTICAST: &str = "239.255.255.250:3702";
const DISCOVERY_WINDOW: Duration = Duration::from_millis(2400);
const TCP_CONNECT_TIMEOUT: Duration = Duration::from_millis(350);
const TCP_PROBE_CONCURRENCY: usize = 64;
const MAX_SCAN_NETWORKS: usize = 3;
const MAX_DATAGRAM_BYTES: usize = 64 * 1024;
const MAX_RESULTS: usize = 64;
static PROBE_ID: AtomicU64 = AtomicU64::new(1);

pub async fn discover_windows_file_servers() -> Vec<DiscoveredServer> {
    let networks = active_ipv4_networks();
    if networks.is_empty() {
        return Vec::new();
    }

    #[cfg(target_os = "ios")]
    let (wsd, tcp) = (Vec::new(), discover_smb_by_tcp(&networks).await);
    #[cfg(not(target_os = "ios"))]
    let (wsd, tcp) = tokio::join!(discover_by_wsd(&networks), discover_smb_by_tcp(&networks));

    let mut by_host = BTreeMap::new();
    // Prefer WS-Discovery when both methods find the same host because it
    // proves that the endpoint actively announced itself.
    for server in wsd.into_iter().chain(tcp) {
        by_host.entry(server.host.clone()).or_insert(server);
        if by_host.len() >= MAX_RESULTS {
            break;
        }
    }
    by_host.into_values().collect()
}

#[derive(Clone, Copy, Debug, Eq, Ord, PartialEq, PartialOrd)]
struct Ipv4ScanNetwork {
    local_ip: Ipv4Addr,
    first_host: Ipv4Addr,
    last_host: Ipv4Addr,
}

fn active_ipv4_networks() -> Vec<Ipv4ScanNetwork> {
    let Ok(interfaces) = if_addrs::get_if_addrs() else {
        return Vec::new();
    };
    let mut by_range = BTreeMap::new();
    for interface in interfaces {
        let IfAddr::V4(address) = interface.addr else {
            continue;
        };
        if address.ip.is_loopback()
            || address.ip.is_unspecified()
            || address.ip.is_link_local()
            || !address.ip.is_private()
        {
            continue;
        }
        let Some((first_host, last_host)) = bounded_host_range(address.ip, address.prefixlen)
        else {
            continue;
        };
        by_range
            .entry((first_host, last_host))
            .or_insert(Ipv4ScanNetwork {
                local_ip: address.ip,
                first_host,
                last_host,
            });
    }
    by_range.into_values().take(MAX_SCAN_NETWORKS).collect()
}

/// Respect small configured subnets, but clamp broad networks to the local /24
/// so discovery remains bounded to at most 254 targets per interface.
fn bounded_host_range(ip: Ipv4Addr, prefix_len: u8) -> Option<(Ipv4Addr, Ipv4Addr)> {
    if prefix_len >= 31 {
        return None;
    }
    let prefix_len = prefix_len.max(24);
    let mask = u32::MAX << (32 - prefix_len);
    let network = u32::from(ip) & mask;
    let broadcast = network | !mask;
    if broadcast <= network + 1 {
        return None;
    }
    Some((Ipv4Addr::from(network + 1), Ipv4Addr::from(broadcast - 1)))
}

async fn discover_by_wsd(networks: &[Ipv4ScanNetwork]) -> Vec<DiscoveredServer> {
    let futures = networks
        .iter()
        .map(|network| discover_on_interface(network.local_ip));
    futures::future::join_all(futures)
        .await
        .into_iter()
        .flatten()
        .collect()
}

async fn discover_smb_by_tcp(networks: &[Ipv4ScanNetwork]) -> Vec<DiscoveredServer> {
    let probes = networks.iter().flat_map(|network| {
        let first = u32::from(network.first_host);
        let last = u32::from(network.last_host);
        (first..=last).filter_map(move |raw| {
            let target = Ipv4Addr::from(raw);
            (target != network.local_ip).then_some((network.local_ip, target))
        })
    });
    stream::iter(probes)
        .map(|(local_ip, target)| async move {
            probe_smb_port(local_ip, target)
                .await
                .then(|| DiscoveredServer {
                    name: target.to_string(),
                    host: target.to_string(),
                    port: 445,
                    protocol: "smb".to_string(),
                    discovery_source: "TCP/445".to_string(),
                })
        })
        .buffer_unordered(TCP_PROBE_CONCURRENCY)
        .filter_map(|server| async move { server })
        .take(MAX_RESULTS)
        .collect()
        .await
}

async fn probe_smb_port(local_ip: Ipv4Addr, target: Ipv4Addr) -> bool {
    let Ok(socket) = TcpSocket::new_v4() else {
        return false;
    };
    if socket.bind(SocketAddr::from((local_ip, 0))).is_err() {
        return false;
    }
    matches!(
        tokio::time::timeout(
            TCP_CONNECT_TIMEOUT,
            socket.connect(SocketAddr::from((target, 445))),
        )
        .await,
        Ok(Ok(_))
    )
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

    #[test]
    fn broad_network_is_bounded_to_local_slash_24() {
        let (first, last) = bounded_host_range(Ipv4Addr::new(192, 168, 77, 42), 16).unwrap();
        assert_eq!(first, Ipv4Addr::new(192, 168, 77, 1));
        assert_eq!(last, Ipv4Addr::new(192, 168, 77, 254));
    }

    #[test]
    fn narrow_network_keeps_its_configured_boundary() {
        let (first, last) = bounded_host_range(Ipv4Addr::new(192, 168, 77, 211), 26).unwrap();
        assert_eq!(first, Ipv4Addr::new(192, 168, 77, 193));
        assert_eq!(last, Ipv4Addr::new(192, 168, 77, 254));
    }
}
