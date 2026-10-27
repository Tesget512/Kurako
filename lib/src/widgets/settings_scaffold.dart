import 'package:material_ui/material_ui.dart';

import 'scroll_reveal_app_bar.dart';
import 'window_caption.dart';
import '../ui/settings_pane_scope.dart';

class SettingsScaffold extends StatefulWidget {
  const SettingsScaffold({
    super.key,
    required this.title,
    required this.body,
    this.embedded = false,
    this.actions = const [],
  });
  final String title;
  final Widget body;
  final bool embedded;
  final List<Widget> actions;

  @override
  State<SettingsScaffold> createState() => _SettingsScaffoldState();
}

class _SettingsScaffoldState extends State<SettingsScaffold> {
  final _reveal = ScrollRevealController(leadingGap: 20);

  @override
  void dispose() {
    _reveal.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final embedded = widget.embedded || SettingsPaneScope.of(context);
    return Scaffold(
      extendBodyBehindAppBar: true,
      appBar: ScrollRevealAppBar(
        controller: _reveal,
        rounded: !embedded,
        title: embedded
            ? Text(widget.title)
            : WindowDragArea(child: Text(widget.title)),
        flexibleSpace: embedded
            ? null
            : const WindowDragArea(child: SizedBox.expand()),
        automaticallyImplyLeading:
            !embedded ||
            (SettingsPaneScope.of(context) && Navigator.of(context).canPop()),
        actions: [...widget.actions, if (!embedded) const WindowButtons()],
      ),
      body: Padding(
        padding: embedded
            ? const EdgeInsets.symmetric(horizontal: 8)
            : EdgeInsets.zero,
        child: ScrollRevealListener(controller: _reveal, child: widget.body),
      ),
    );
  }
}
