import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:nsd/nsd.dart' as nsd;

import '../rust/api.dart' as rust;

class SmbServerCandidate {
  final String name;
  final String host;
  final int port;
  final String source;

  const SmbServerCandidate({
    required this.name,
    required this.host,
    required this.port,
    required this.source,
  });

  String get address => port == 445 ? host : '$host:$port';
}

class WebDavServerCandidate {
  final String name;
  final String url;
  final String source;

  const WebDavServerCandidate({
    required this.name,
    required this.url,
    required this.source,
  });
}

/// Combine standards-based SMB DNS-SD with Windows WS-Discovery. Both are
/// bounded broadcasts; this deliberately does not probe every address in a
/// subnet or authenticate to any result.
Future<List<SmbServerCandidate>> discoverSmbServers() async {
  final results = await Future.wait([_discoverDnsSd(), _discoverWindowsWsd()]);
  final byAddress = <String, SmbServerCandidate>{};
  for (final group in results) {
    for (final server in group) {
      final key = server.address.toLowerCase();
      final existing = byAddress[key];
      if (existing == null || existing.name == existing.host) {
        byAddress[key] = server;
      }
    }
  }
  final out = byAddress.values.toList();
  out.sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
  return out;
}

Future<List<SmbServerCandidate>> _discoverDnsSd() async {
  nsd.Discovery? discovery;
  try {
    discovery = await nsd.startDiscovery(
      '_smb._tcp',
      ipLookupType: nsd.IpLookupType.any,
    );
    await Future<void>.delayed(const Duration(milliseconds: 2800));
    return discovery.services
        .map((service) {
          final resolved = service.addresses?.where((address) {
            return !address.isLoopback && !address.isLinkLocal;
          }).firstOrNull;
          final host = (resolved?.address ?? service.host ?? '')
              .replaceAll(RegExp(r'\.$'), '')
              .trim();
          if (host.isEmpty) return null;
          return SmbServerCandidate(
            name: (service.name ?? host).trim(),
            host: host,
            port: service.port ?? 445,
            source: 'Bonjour / mDNS',
          );
        })
        .whereType<SmbServerCandidate>()
        .toList();
  } catch (_) {
    return const [];
  } finally {
    if (discovery != null) {
      try {
        await nsd.stopDiscovery(discovery);
      } catch (_) {}
    }
  }
}

Future<List<SmbServerCandidate>> _discoverWindowsWsd() async {
  // Unsigned/self-signed iOS distributions cannot rely on the multicast
  // entitlement required by raw WS-Discovery. Bonjour remains available via
  // nsd, and the SMB wizard always keeps manual host entry as a fallback.
  if (Platform.isIOS) return const [];
  try {
    final servers = await rust.discoverWindowsFileServers();
    return servers
        .map(
          (server) => SmbServerCandidate(
            name: server.name,
            host: server.host,
            port: server.port,
            source: server.discoverySource,
          ),
        )
        .toList();
  } catch (_) {
    return const [];
  }
}

Future<List<WebDavServerCandidate>> discoverWebDavServers() async {
  final groups = await Future.wait([
    _discoverWebDavType('_webdav._tcp', secure: false),
    _discoverWebDavType('_webdavs._tcp', secure: true),
  ]);
  final byUrl = <String, WebDavServerCandidate>{};
  for (final candidate in groups.expand((group) => group)) {
    byUrl[candidate.url.toLowerCase()] = candidate;
  }
  final out = byUrl.values.toList()
    ..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
  return out;
}

Future<List<WebDavServerCandidate>> _discoverWebDavType(
  String serviceType, {
  required bool secure,
}) async {
  nsd.Discovery? discovery;
  try {
    discovery = await nsd.startDiscovery(
      serviceType,
      ipLookupType: nsd.IpLookupType.any,
    );
    await Future<void>.delayed(const Duration(milliseconds: 2800));
    final out = <WebDavServerCandidate>[];
    for (final service in discovery.services) {
      final host = (service.host ?? '').replaceAll(RegExp(r'\.$'), '').trim();
      final fallbackAddress = service.addresses
          ?.where((address) => !address.isLoopback && !address.isLinkLocal)
          .firstOrNull
          ?.address;
      final target = host.isNotEmpty ? host : fallbackAddress;
      if (target == null || target.isEmpty) continue;
      var path = '/';
      final pathBytes = service.txt?['path'];
      if (pathBytes != null) {
        try {
          final decoded = utf8.decode(pathBytes).trim();
          if (decoded.startsWith('/')) path = decoded;
        } catch (_) {}
      }
      if (!path.endsWith('/')) path = '$path/';
      final scheme = secure ? 'https' : 'http';
      final defaultPort = secure ? 443 : 80;
      final url = Uri(
        scheme: scheme,
        host: target,
        port: service.port == null || service.port == defaultPort
            ? null
            : service.port,
        path: path,
      ).toString();
      out.add(
        WebDavServerCandidate(
          name: (service.name ?? target).trim(),
          url: url,
          source: secure ? 'Bonjour / WebDAVS' : 'Bonjour / WebDAV',
        ),
      );
    }
    return out;
  } catch (_) {
    return const [];
  } finally {
    if (discovery != null) {
      try {
        await nsd.stopDiscovery(discovery);
      } catch (_) {}
    }
  }
}
