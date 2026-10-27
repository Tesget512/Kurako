import 'dart:io' show Platform;

import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

/// UIKit interface orientation as reported by the iOS bridge.
enum IosInterfaceOrientation {
  portrait,
  portraitUpsideDown,
  landscapeLeft,
  landscapeRight,
  unknown;

  static IosInterfaceOrientation parse(Object? value) => switch (value) {
    'portrait' => portrait,
    'portraitUpsideDown' => portraitUpsideDown,
    'landscapeLeft' => landscapeLeft,
    'landscapeRight' => landscapeRight,
    _ => unknown,
  };
}

/// iOS reports equal left/right safe-area insets in landscape although the
/// notch or Dynamic Island sits on one side only. Keep the inset on that side
/// and drop the mirrored one. UIKit `landscapeLeft` means the home side is on
/// the left, so the sensor housing is on the right (and vice versa).
@visibleForTesting
EdgeInsets notchOnlyHorizontalInsets(
  EdgeInsets insets,
  IosInterfaceOrientation orientation,
) => switch (orientation) {
  IosInterfaceOrientation.landscapeLeft => insets.copyWith(left: 0),
  IosInterfaceOrientation.landscapeRight => insets.copyWith(right: 0),
  _ => insets,
};

/// Rewrites MediaQuery padding/viewPadding below it on iOS. Other platforms
/// already receive asymmetric cutout insets from the system.
class NotchSafeArea extends StatefulWidget {
  const NotchSafeArea({
    super.key,
    required this.child,
    this.enabled,
    this.channel = const MethodChannel('kurako/ios'),
  });

  final Widget child;

  /// Defaults to `Platform.isIOS`.
  final bool? enabled;
  final MethodChannel channel;

  @override
  State<NotchSafeArea> createState() => _NotchSafeAreaState();
}

class _NotchSafeAreaState extends State<NotchSafeArea>
    with WidgetsBindingObserver {
  var _orientation = IosInterfaceOrientation.unknown;

  bool get _enabled => widget.enabled ?? Platform.isIOS;

  @override
  void initState() {
    super.initState();
    if (!_enabled) return;
    WidgetsBinding.instance.addObserver(this);
    widget.channel.setMethodCallHandler((call) async {
      if (call.method == 'interfaceOrientationChanged') {
        _apply(call.arguments);
      }
      return null;
    });
    _query();
  }

  // Size changes cover portrait <-> landscape; the native notification
  // covers the 180-degree landscape flip.
  @override
  void didChangeMetrics() => _query();

  Future<void> _query() async {
    try {
      _apply(await widget.channel.invokeMethod<String>('interfaceOrientation'));
    } catch (_) {
      // Older native shells: keep the system insets unchanged.
    }
  }

  void _apply(Object? value) {
    final next = IosInterfaceOrientation.parse(value);
    if (!mounted || next == _orientation) return;
    setState(() => _orientation = next);
  }

  @override
  void dispose() {
    if (_enabled) {
      WidgetsBinding.instance.removeObserver(this);
      widget.channel.setMethodCallHandler(null);
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!_enabled) return widget.child;
    final mq = MediaQuery.of(context);
    if (mq.size.width <= mq.size.height) return widget.child;
    return MediaQuery(
      data: mq.copyWith(
        padding: notchOnlyHorizontalInsets(mq.padding, _orientation),
        viewPadding: notchOnlyHorizontalInsets(mq.viewPadding, _orientation),
      ),
      child: widget.child,
    );
  }
}
