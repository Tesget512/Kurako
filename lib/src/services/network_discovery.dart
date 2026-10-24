import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
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

const _androidNetworkChannel = MethodChannel('kurako/android/network');

/// Combine verified SMB DNS-SD with verified Windows/NAS candidates. Discovery
/// never authenticates or changes the active SMB session; Rust only performs
/// the anonymous SMB2 NEGOTIATE needed to reject unrelated port-445 services.
Future<List<SmbServerCandidate>> discoverSmbServers() async {
  return _withAndroidMulticastLock(() async {
    final results = await Future.wait([
      _discoverDnsSd(),
      _discoverWindowsAndNasHosts(),
    ]);
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
  });
}

Future<T> _withAndroidMulticastLock<T>(Future<T> Function() action) async {
  var acquired = false;
  if (Platform.isAndroid) {
    try {
      await _androidNetworkChannel.invokeMethod<void>('acquireMulticastLock');
      acquired = true;
    } catch (_) {
      // TCP/445 discovery still works when a device vendor denies the lock.
    }
  }
  try {
    return await action();
  } finally {
    if (acquired) {
      try {
        await _androidNetworkChannel.invokeMethod<void>('releaseMulticastLock');
      } catch (_) {}
    }
  }
}

Future<List<SmbServerCandidate>> _discoverDnsSd() async {
  nsd.Discovery? discovery;
  try {
    discovery = await nsd.startDiscovery(
      '_smb._tcp',
      ipLookupType: nsd.IpLookupType.any,
    );
    await Future<void>.delayed(const Duration(milliseconds: 2800));
    final candidates = discovery.services
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
    final verified = await Future.wait(
      candidates.map((server) async {
        try {
          final ok = await rust.verifySmbServer(
            host: server.host,
            port: server.port,
          );
          return ok ? server : null;
        } catch (_) {
          return null;
        }
      }),
    );
    return verified.whereType<SmbServerCandidate>().toList();
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

Future<List<SmbServerCandidate>> _discoverWindowsAndNasHosts() async {
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
