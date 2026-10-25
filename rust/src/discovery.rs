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
use quick_xml::name::{Namespace, ResolveResult};
use quick_xml::reader::NsReader;
use std::collections::BTreeMap;
use std::net::{IpAddr, Ipv4Addr, SocketAddr};
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::{Duration, SystemTime, UNIX_EPOCH};
use tokio::net::UdpSocket;

const WSD_MULTICAST: &str = "239.255.255.250:3702";
const DISCOVERY_WINDOW: Duration = Duration::from_millis(2400);
const SMB2_NEGOTIATE_TIMEOUT: Duration = Duration::from_millis(900);
const TCP_PROBE_CONCURRENCY: usize = 64;
const MAX_SCAN_NETWORKS: usize = 3;
const MAX_DATAGRAM_BYTES: usize = 64 * 1024;
const MAX_RESULTS: usize = 64;
const SOAP_ENVELOPE_NS: &str = "http://www.w3.org/2003/05/soap-envelope";
const WS_ADDRESSING_NS: &str = "http://schemas.xmlsoap.org/ws/2004/08/addressing";
const WS_DISCOVERY_NS: &str = "http://schemas.xmlsoap.org/ws/2005/04/discovery";
const PROBE_MATCHES_ACTION: &str = "http://schemas.xmlsoap.org/ws/2005/04/discovery/ProbeMatches";
static PROBE_ID: AtomicU64 = AtomicU64::new(1);

pub async fn discover_windows_file_servers() -> Vec<DiscoveredServer> {
    let networks = active_ipv4_networks();
    if networks.is_empty() {
        return Vec::new();
    }

    #[cfg(target_os = "ios")]
    let (wsd_candidates, tcp) = (Vec::new(), discover_smb_by_tcp(&networks).await);
    #[cfg(not(target_os = "ios"))]
    let (wsd_candidates, tcp) =
        tokio::join!(discover_by_wsd(&networks), discover_smb_by_tcp(&networks));

    let wsd = verify_candidates(wsd_candidates).await;
    merge_discovered(wsd.into_iter().chain(tcp).collect())
}

fn merge_discovered(mut servers: Vec<DiscoveredServer>) -> Vec<DiscoveredServer> {
    let mut by_endpoint: BTreeMap<(String, u16), DiscoveredServer> = BTreeMap::new();
    for server in servers.drain(..) {
        let key = (server.host.trim().to_ascii_lowercase(), server.port);
        match by_endpoint.get(&key) {
            Some(existing)
                if existing.discovery_source != "TCP/445"
                    || server.discovery_source == "TCP/445" => {}
            _ => {
                by_endpoint.insert(key, server);
            }
        }
    }
    by_endpoint
        .into_values()
        .take(MAX_RESULTS)
        .collect::<Vec<_>>()
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
            let _ = local_ip;
            verify_smb_server(&target.to_string(), 445)
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
        .collect()
        .await
}

pub async fn verify_smb_server(host: &str, port: u16) -> bool {
    let host = host.trim().trim_matches(['[', ']']);
    if host.is_empty() || port == 0 {
        return false;
    }
    if let Ok(ip) = host.parse::<IpAddr>() {
        if ip.is_loopback() || ip.is_unspecified() || ip.is_multicast() {
            return false;
        }
    }
    let address = if host.contains(':') {
        format!("[{host}]:{port}")
    } else {
        format!("{host}:{port}")
    };
    let negotiation = async {
        let mut connection =
            smb2::client::Connection::connect(&address, SMB2_NEGOTIATE_TIMEOUT).await?;
        connection.negotiate().await
    };
    matches!(
        tokio::time::timeout(SMB2_NEGOTIATE_TIMEOUT, negotiation).await,
        Ok(Ok(()))
    )
}

async fn verify_candidates(candidates: Vec<DiscoveredServer>) -> Vec<DiscoveredServer> {
    stream::iter(candidates)
        .map(|server| async move {
            verify_smb_server(&server.host, server.port)
                .await
                .then_some(server)
        })
        .buffer_unordered(TCP_PROBE_CONCURRENCY)
        .filter_map(|server| async move { server })
        .collect()
        .await
}

async fn discover_on_interface(ip: Ipv4Addr) -> Vec<DiscoveredServer> {
    let socket = match UdpSocket::bind(SocketAddr::from((ip, 0))).await {
        Ok(socket) => socket,
        Err(_) => return Vec::new(),
    };
    let _ = socket.set_multicast_ttl_v4(1);
    let (message, message_id) = probe_message();
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
        for server in parse_probe_response(&buffer[..size], &message_id) {
            found.entry(server.host.clone()).or_insert(server);
        }
    }
    found.into_values().collect()
}

fn probe_message() -> (String, String) {
    let seconds = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|duration| duration.as_nanos())
        .unwrap_or(0);
    let id = PROBE_ID.fetch_add(1, Ordering::Relaxed);
    let message_id = format!("urn:uuid:{seconds:032x}-{id:016x}");
    let message = format!(
        r#"<?xml version="1.0" encoding="UTF-8"?>
<e:Envelope xmlns:e="http://www.w3.org/2003/05/soap-envelope"
 xmlns:w="http://schemas.xmlsoap.org/ws/2004/08/addressing"
 xmlns:d="http://schemas.xmlsoap.org/ws/2005/04/discovery"
 xmlns:wsdp="http://schemas.xmlsoap.org/ws/2006/02/devprof">
 <e:Header>
  <w:MessageID>{message_id}</w:MessageID>
  <w:To e:mustUnderstand="true">urn:schemas-xmlsoap-org:ws:2005:04:discovery</w:To>
  <w:Action e:mustUnderstand="true">http://schemas.xmlsoap.org/ws/2005/04/discovery/Probe</w:Action>
 </e:Header>
 <e:Body><d:Probe><d:Types>wsdp:Device</d:Types></d:Probe></e:Body>
</e:Envelope>"#
    );
    (message, message_id)
}

fn parse_probe_response(bytes: &[u8], expected_message_id: &str) -> Vec<DiscoveredServer> {
    #[derive(Clone)]
    struct Element {
        local: String,
        namespace: Option<String>,
    }

    fn suffix_is(stack: &[Element], suffix: &[&str]) -> bool {
        stack.len() >= suffix.len()
            && stack[stack.len() - suffix.len()..]
                .iter()
                .zip(suffix)
                .all(|(element, local)| element.local.as_str() == *local)
    }

    let mut reader = NsReader::from_reader(bytes);
    reader.config_mut().trim_text(true);
    let mut stack = Vec::<Element>::new();
    let mut xaddrs = Vec::new();
    let mut action = String::new();
    let mut relates_to = String::new();
    let mut saw_probe_matches = false;
    let mut valid_envelope = false;
    loop {
        match reader.read_resolved_event() {
            Ok((resolved, Event::Start(start))) => {
                let namespace = match resolved {
                    ResolveResult::Bound(Namespace(value)) => Some(value.to_string()),
                    _ => None,
                };
                stack.push(Element {
                    local: start.local_name().as_ref().to_string(),
                    namespace,
                });
                if stack.len() == 1 {
                    valid_envelope = stack[0].local == "Envelope"
                        && stack[0].namespace.as_deref() == Some(SOAP_ENVELOPE_NS);
                }
                if suffix_is(&stack, &["Body", "ProbeMatches"])
                    && stack
                        .last()
                        .and_then(|element| element.namespace.as_deref())
                        == Some(WS_DISCOVERY_NS)
                {
                    saw_probe_matches = true;
                }
            }
            Ok((_, Event::Text(text))) => {
                let value = text.as_ref().trim();
                if value.is_empty() {
                    continue;
                }
                let Some(element) = stack.last() else {
                    continue;
                };
                if suffix_is(&stack, &["Header", "Action"])
                    && element.namespace.as_deref() == Some(WS_ADDRESSING_NS)
                {
                    action.push_str(value);
                } else if suffix_is(&stack, &["Header", "RelatesTo"])
                    && element.namespace.as_deref() == Some(WS_ADDRESSING_NS)
                {
                    relates_to.push_str(value);
                } else if suffix_is(&stack, &["Body", "ProbeMatches", "ProbeMatch", "XAddrs"])
                    && element.namespace.as_deref() == Some(WS_DISCOVERY_NS)
                {
                    xaddrs.extend(value.split_whitespace().map(str::to_string));
                }
            }
            Ok((_, Event::End(_))) => {
                stack.pop();
            }
            Ok((_, Event::Eof)) | Err(_) => break,
            _ => {}
        }
    }
    if !valid_envelope
        || !saw_probe_matches
        || action != PROBE_MATCHES_ACTION
        || relates_to != expected_message_id
    {
        return Vec::new();
    }

    let mut hosts = BTreeMap::new();
    for address in xaddrs {
        let Ok(url) = reqwest::Url::parse(&address) else {
            continue;
        };
        if !matches!(url.scheme(), "http" | "https")
            || !url.username().is_empty()
            || url.password().is_some()
            || url.fragment().is_some()
        {
            continue;
        }
        let Some(host) = url.host_str() else {
            continue;
        };
        let host = host.trim_matches(['[', ']']).to_string();
        if host.is_empty()
            || host
                .parse::<IpAddr>()
                .is_ok_and(|ip| ip.is_loopback() || ip.is_unspecified() || ip.is_multicast())
        {
            continue;
        }
        hosts
            .entry(host.to_ascii_lowercase())
            .or_insert(DiscoveredServer {
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
          xmlns:a="http://schemas.xmlsoap.org/ws/2004/08/addressing"
          xmlns:d="http://schemas.xmlsoap.org/ws/2005/04/discovery">
          <s:Header>
            <a:Action>http://schemas.xmlsoap.org/ws/2005/04/discovery/ProbeMatches</a:Action>
            <a:RelatesTo>urn:uuid:probe</a:RelatesTo>
          </s:Header>
          <s:Body><d:ProbeMatches><d:ProbeMatch>
            <d:Types>wsdp:Device</d:Types>
            <d:XAddrs>http://192.0.2.10:5357/abc https://server.local/wsd</d:XAddrs>
          </d:ProbeMatch></d:ProbeMatches></s:Body>
        </s:Envelope>"#;
        let servers = parse_probe_response(xml, "urn:uuid:probe");
        assert_eq!(servers.len(), 2);
        assert!(servers.iter().any(|server| server.host == "192.0.2.10"));
        assert!(servers.iter().all(|server| server.port == 445));
    }

    #[test]
    fn ignores_malformed_xml_and_urls() {
        assert!(parse_probe_response(b"not xml", "urn:uuid:probe").is_empty());
        let xml = br#"<XAddrs>not-a-url</XAddrs>"#;
        assert!(parse_probe_response(xml, "urn:uuid:probe").is_empty());
    }

    #[test]
    fn ignores_probe_matches_with_wrong_action_or_outside_body() {
        let wrong_action = br#"<s:Envelope xmlns:s="http://www.w3.org/2003/05/soap-envelope"
          xmlns:a="http://schemas.xmlsoap.org/ws/2004/08/addressing"
          xmlns:d="http://schemas.xmlsoap.org/ws/2005/04/discovery">
          <s:Header><a:Action>urn:not-discovery</a:Action>
            <a:RelatesTo>urn:uuid:probe</a:RelatesTo></s:Header>
          <s:Body><d:ProbeMatches><d:ProbeMatch>
            <d:XAddrs>http://192.0.2.10:5357/abc</d:XAddrs>
          </d:ProbeMatch></d:ProbeMatches></s:Body>
        </s:Envelope>"#;
        assert!(parse_probe_response(wrong_action, "urn:uuid:probe").is_empty());

        let unrelated = br#"<s:Envelope xmlns:s="http://www.w3.org/2003/05/soap-envelope"
          xmlns:a="http://schemas.xmlsoap.org/ws/2004/08/addressing"
          xmlns:d="http://schemas.xmlsoap.org/ws/2005/04/discovery">
          <s:Header>
            <a:Action>http://schemas.xmlsoap.org/ws/2005/04/discovery/ProbeMatches</a:Action>
            <a:RelatesTo>urn:uuid:probe</a:RelatesTo>
          </s:Header>
          <s:Body><XAddrs>http://192.0.2.10:5357/abc</XAddrs></s:Body>
        </s:Envelope>"#;
        assert!(parse_probe_response(unrelated, "urn:uuid:probe").is_empty());
        let valid = br#"<s:Envelope xmlns:s="http://www.w3.org/2003/05/soap-envelope"
          xmlns:a="http://schemas.xmlsoap.org/ws/2004/08/addressing"
          xmlns:d="http://schemas.xmlsoap.org/ws/2005/04/discovery">
          <s:Header>
            <a:Action>http://schemas.xmlsoap.org/ws/2005/04/discovery/ProbeMatches</a:Action>
            <a:RelatesTo>urn:uuid:stale</a:RelatesTo>
          </s:Header>
          <s:Body><d:ProbeMatches><d:ProbeMatch>
            <d:XAddrs>http://192.0.2.10:5357/abc</d:XAddrs>
          </d:ProbeMatch></d:ProbeMatches></s:Body>
        </s:Envelope>"#;
        assert!(parse_probe_response(valid, "urn:uuid:expected").is_empty());
    }

    #[test]
    fn merges_verified_sources_by_normalized_host_port_with_stable_order() {
        let servers = vec![
            server("nas-b", "nas-b", 445, "TCP/445"),
            server("nas-a", "nas-a", 445, "WS-Discovery"),
            server("nas-b", "NAS-B", 445, "WS-Discovery"),
            server("nas-c", "nas-c", 1445, "TCP/445"),
        ];
        let merged = merge_discovered(servers);
        assert_eq!(
            merged
                .iter()
                .map(|server| (server.host.as_str(), server.port))
                .collect::<Vec<_>>(),
            vec![("nas-a", 445), ("nas-b", 445), ("nas-c", 1445)]
        );
        assert_eq!(merged[1].name, "NAS-B");
        assert_eq!(merged[1].discovery_source, "WS-Discovery");
    }

    fn server(host: &str, name: &str, port: u16, source: &str) -> DiscoveredServer {
        DiscoveredServer {
            name: name.to_string(),
            host: host.to_string(),
            port,
            protocol: "smb".to_string(),
            discovery_source: source.to_string(),
        }
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
