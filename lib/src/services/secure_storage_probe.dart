import 'dart:io';

import 'package:flutter/material.dart';

import 'bangumi_credentials.dart';

/// Dev-only storage-link probe: `--dart-define=KURAKO_SECURE_STORAGE_PROBE=true`.
/// Writes, reads back and deletes one synthetic value through the exact
/// store the PAT login uses, so the platform chain (Keychain entitlement,
/// Keystore, DPAPI, libsecret) is verified on a real build without touching
/// any real credential.
const kSecureStorageProbeEnabled = bool.fromEnvironment(
  'KURAKO_SECURE_STORAGE_PROBE',
  defaultValue: false,
);

final secureStorageProbeResult = ValueNotifier<String?>(null);

void launchSecureStorageProbe() {
  Future<void>.delayed(const Duration(milliseconds: 400), () async {
    final store = SecureStorageBangumiCredentialStore();
    const probeKeyNote = 'probe-value';
    String verdict;
    try {
      await store.writePersonalToken(probeKeyNote);
      final readBack = await store.readPersonalToken();
      await store.deletePersonalToken();
      final afterDelete = await store.readPersonalToken();
      verdict = readBack == probeKeyNote && (afterDelete == null || afterDelete.isEmpty)
          ? 'PASS (write/read/delete round trip ok)'
          : 'FAIL (read back: ${readBack == probeKeyNote ? "ok" : "mismatch"}, '
                'after delete: ${afterDelete == null ? "null" : "still present"})';
    } catch (error) {
      var code = '';
      final match = RegExp(
        r'PlatformException\(([^,\s]+)',
      ).firstMatch(error.toString());
      code = match?.group(1) ?? '';
      verdict = 'FAIL (exception${code.isEmpty ? '' : ' code $code'})';
      // Never log the error object itself; its message may quote store paths.
      debugPrint('SecureStorageProbe: failed with code $code');
    }
    secureStorageProbeResult.value = verdict;
    debugPrint('SecureStorageProbe: $verdict');
    final out = Platform.environment['KURAKO_SECURE_STORAGE_PROBE_OUT'];
    if (out != null && out.isNotEmpty) {
      try {
        File(out).writeAsStringSync('SecureStorageProbe: $verdict\n');
      } catch (_) {}
    }
  });
}

/// Dev-only banner mirroring the probe verdict on screen.
class SecureStorageProbeBanner extends StatelessWidget {
  const SecureStorageProbeBanner({super.key});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<String?>(
      valueListenable: secureStorageProbeResult,
      builder: (context, verdict, _) {
        if (verdict == null) {
          return const ColoredBox(
            color: Colors.black54,
            child: Padding(
              padding: EdgeInsets.all(6),
              child: Text(
                'Secure storage probe: running…',
                style: TextStyle(color: Colors.white, fontSize: 11),
              ),
            ),
          );
        }
        final ok = verdict.startsWith('PASS');
        return ColoredBox(
          color: ok ? Colors.green.shade700 : Colors.red.shade700,
          child: Padding(
            padding: const EdgeInsets.all(6),
            child: Text(
              'Secure storage probe: $verdict',
              style: const TextStyle(color: Colors.white, fontSize: 11),
            ),
          ),
        );
      },
    );
  }
}
