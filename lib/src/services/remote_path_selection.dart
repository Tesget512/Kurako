Set<String> compactSelectedRemotePaths(Iterable<String> paths) {
  final sorted =
      paths
          .map((path) => path.trim().replaceAll(RegExp(r'^/+|/+$'), ''))
          .toSet()
          .toList()
        ..sort((a, b) {
          final depth = a.split('/').length.compareTo(b.split('/').length);
          return depth != 0 ? depth : a.compareTo(b);
        });
  final out = <String>{};
  for (final path in sorted) {
    if (out.any((parent) => parent.isEmpty || path.startsWith('$parent/'))) {
      continue;
    }
    out.add(path);
  }
  return out;
}
