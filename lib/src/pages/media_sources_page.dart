import 'package:material_ui/material_ui.dart';

import '../ui/page_components.dart';
import '../widgets/media_source_manager.dart';
import '../widgets/settings_scaffold.dart';

/// Media source management: the anime folders (local / SMB / WebDAV) that
/// feed the library.
class MediaSourcesPage extends StatelessWidget {
  const MediaSourcesPage({super.key, this.embedded = false});

  final bool embedded;

  @override
  Widget build(BuildContext context) => SettingsScaffold(
    title: '媒体来源',
    embedded: embedded,
    body: const KurakoPageList(maxWidth: 840, children: [MediaSourceManager()]),
  );
}
