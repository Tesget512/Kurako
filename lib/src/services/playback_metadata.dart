/// libmpv may expose `1`, `1000`, NaN or another placeholder when a container
/// has no reliable per-track bitrate. Values below 8 kbps are not useful for
/// Kurako's video library and are treated as unknown instead of being rendered
/// as a misleading `1 kbps`.
bool isReliableMediaBitrate(num? bitsPerSecond) {
  if (bitsPerSecond == null) return false;
  final value = bitsPerSecond.toDouble();
  return value.isFinite && value >= 8000;
}

double? firstReliableMediaBitrate(Iterable<num?> candidates) {
  for (final candidate in candidates) {
    if (isReliableMediaBitrate(candidate)) return candidate!.toDouble();
  }
  return null;
}

String formatMediaBitrate(num? bitsPerSecond) {
  if (!isReliableMediaBitrate(bitsPerSecond)) return '未知';
  final value = bitsPerSecond!.toDouble();
  if (value >= 1000 * 1000) {
    final mbps = value / (1000 * 1000);
    return '${mbps >= 10 ? mbps.toStringAsFixed(1) : mbps.toStringAsFixed(2)} Mbps';
  }
  return '${(value / 1000).round()} kbps';
}

String? nonEmptyMediaProperty(String? value) {
  final normalized = value?.trim();
  return normalized == null || normalized.isEmpty ? null : normalized;
}
