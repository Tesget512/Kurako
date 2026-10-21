/// This file is a part of media_kit (https://github.com/media-kit/media-kit).
///
/// Copyright © 2021 & onwards, Hitesh Kumar Saini <saini123hitesh@gmail.com>.
/// All rights reserved.
/// Use of this source code is governed by MIT license that can be found in the LICENSE file.
// ignore_for_file: non_constant_identifier_names
import 'dart:async';
import 'dart:ui' show PointerDeviceKind;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:media_kit_video/media_kit_video_controls/src/controls/extensions/duration.dart';
import 'package:media_kit_video/media_kit_video_controls/src/controls/methods/video_state.dart';
import 'package:media_kit_video/media_kit_video_controls/src/controls/widgets/video_controls_theme_data_injector.dart';
import 'package:screen_brightness_platform_interface/screen_brightness_platform_interface.dart';
import 'package:volume_controller/volume_controller.dart';

/// {@template material_video_controls}
///
/// [Video] controls which use Material design.
///
/// {@endtemplate}
Widget MaterialVideoControls(VideoState state) {
  return const VideoControlsThemeDataInjector(
    child: _MaterialVideoControls(),
  );
}

/// [MaterialVideoControlsThemeData] available in this [context].
MaterialVideoControlsThemeData _theme(BuildContext context) =>
    FullscreenInheritedWidget.maybeOf(context) == null
        ? MaterialVideoControlsTheme.maybeOf(context)?.normal ??
            kDefaultMaterialVideoControlsThemeData
        : MaterialVideoControlsTheme.maybeOf(context)?.fullscreen ??
            kDefaultMaterialVideoControlsThemeDataFullscreen;

/// Default [MaterialVideoControlsThemeData].
const kDefaultMaterialVideoControlsThemeData = MaterialVideoControlsThemeData();

/// Default [MaterialVideoControlsThemeData] for fullscreen.
const kDefaultMaterialVideoControlsThemeDataFullscreen =
    MaterialVideoControlsThemeData(
  displaySeekBar: true,
  automaticallyImplySkipNextButton: true,
  automaticallyImplySkipPreviousButton: true,
  volumeGesture: true,
  brightnessGesture: true,
  seekGesture: true,
  gesturesEnabledWhileControlsVisible: true,
  seekOnDoubleTap: true,
  seekOnDoubleTapEnabledWhileControlsVisible: true,
  visibleOnMount: false,
  speedUpOnLongPress: false,
  speedUpFactor: 2.0,
  verticalGestureSensitivity: 100,
  horizontalGestureSensitivity: 1000,
  backdropColor: Color(0x66000000),
  padding: null,
  controlsHoverDuration: Duration(seconds: 3),
  controlsTransitionDuration: Duration(milliseconds: 300),
  bufferingIndicatorBuilder: null,
  volumeIndicatorBuilder: null,
  brightnessIndicatorBuilder: null,
  seekIndicatorBuilder: null,
  speedUpIndicatorBuilder: null,
  primaryButtonBar: [
    Spacer(flex: 2),
    MaterialSkipPreviousButton(),
    Spacer(),
    MaterialPlayOrPauseButton(iconSize: 56.0),
    Spacer(),
    MaterialSkipNextButton(),
    Spacer(flex: 2),
  ],
  topButtonBar: [],
  topButtonBarMargin: EdgeInsets.symmetric(
    horizontal: 16.0,
  ),
  bottomButtonBar: [
    MaterialPositionIndicator(),
    Spacer(),
    MaterialFullscreenButton(),
  ],
  bottomButtonBarMargin: EdgeInsets.only(
    left: 16.0,
    right: 8.0,
    bottom: 42.0,
  ),
  buttonBarHeight: 56.0,
  buttonBarButtonSize: 24.0,
  buttonBarButtonColor: Color(0xFFFFFFFF),
  seekBarMargin: EdgeInsets.only(
    left: 16.0,
    right: 16.0,
    bottom: 42.0,
  ),
  seekBarHeight: 2.4,
  seekBarContainerHeight: 36.0,
  seekBarColor: Color(0x3DFFFFFF),
  seekBarPositionColor: Color(0xFFFF0000),
  seekBarBufferColor: Color(0x3DFFFFFF),
  seekBarThumbSize: 12.8,
  seekBarThumbColor: Color(0xFFFF0000),
  seekBarAlignment: Alignment.bottomCenter,
  shiftSubtitlesOnControlsVisibilityChange: false,
);

/// Applies one vertical-drag sample to the level captured at drag start.
///
/// Dragging up (a negative `deltaDy`) raises the level. Deriving each frame from
/// the start value and the total displacement keeps the value stable: the old
/// code accumulated onto the *live* value, so a late platform echo could pull
/// the next frame in the wrong direction and make the level jitter.
double resolveVerticalGestureValue({
  required double startValue,
  required double totalDeltaDy,
  required double sensitivity,
}) {
  if (sensitivity <= 0) return startValue.clamp(0.0, 1.0);
  return (startValue - totalDeltaDy / sensitivity).clamp(0.0, 1.0);
}

enum MaterialVerticalGestureKind { brightness, volume }

/// Resolves which OSD a vertical gesture should show.
///
/// The OSD widget stays mounted while `AnimatedOpacity` fades it out, and by
/// then both indicator flags are already cleared. Deriving the kind from those
/// flags alone would repaint the OSD as the *other* indicator during that fade
/// — a finished volume adjustment briefly flashing the brightness UI — so the
/// last used kind is remembered and reused until a new gesture replaces it.
MaterialVerticalGestureKind resolveVerticalGestureKind({
  required bool dragging,
  required MaterialVerticalGestureKind? activeKind,
  required bool volumeIndicator,
  required bool brightnessIndicator,
  required MaterialVerticalGestureKind? lastKind,
}) {
  if (dragging) {
    return activeKind ?? lastKind ?? MaterialVerticalGestureKind.volume;
  }
  if (volumeIndicator) return MaterialVerticalGestureKind.volume;
  if (brightnessIndicator) return MaterialVerticalGestureKind.brightness;
  return lastKind ?? MaterialVerticalGestureKind.volume;
}

class MaterialVerticalGestureIndicatorData {
  final MaterialVerticalGestureKind kind;
  final double value;

  /// Position in the complete controls root, not the inset gesture detector.
  final Offset? position;
  final bool isDragging;
  const MaterialVerticalGestureIndicatorData(
      {required this.kind,
      required this.value,
      required this.position,
      required this.isDragging});
}

/// {@template material_video_controls_theme_data}
///
/// Theming related data for [MaterialVideoControls]. These values are used to theme the descendant [MaterialVideoControls].
///
/// {@endtemplate}
class MaterialVideoControlsThemeData {
  // BEHAVIOR

  /// Whether to display seek bar.
  final bool displaySeekBar;

  /// Whether a skip next button should be displayed if there are more than one videos in the playlist.
  final bool automaticallyImplySkipNextButton;

  /// Whether a skip previous button should be displayed if there are more than one videos in the playlist.
  final bool automaticallyImplySkipPreviousButton;

  /// Whether to modify volume on vertical drag gesture on the right side of the screen.
  final bool volumeGesture;

  /// Whether to modify screen brightness on vertical drag gesture on the left side of the screen.
  final bool brightnessGesture;

  /// Whether to seek on horizontal drag gesture.
  final bool seekGesture;

  /// Whether to allow gesture controls to work while controls are visible.
  /// NOTE: This option is ignored when gestures are false.
  final bool gesturesEnabledWhileControlsVisible;

  /// Disables every built-in touch control and gesture while the embedding
  /// application displays its own unlock affordance.  This is intentionally a
  /// controls-theme option rather than an [IgnorePointer] around [Video], so
  /// the video surface keeps rendering normally and the host can place an
  /// unlock button above it.
  final bool controlsLocked;

  /// Hide controls as soon as a hover-capable pointer leaves the full video.
  final bool hideControlsOnMouseExit;

  /// Hide the desktop cursor together with idle controls.
  final bool hideMouseOnControlsRemoval;

  /// Extra host shortcuts which remain active while touch controls are locked.
  final Map<ShortcutActivator, VoidCallback>? keyboardShortcuts;

  /// Host action for a mouse double-click on the video surface.
  final VoidCallback? onMouseDoubleTap;

  /// Host action for a secondary click on otherwise unhandled video surface.
  final VoidCallback? onSecondaryTap;

  /// Whether to enable double tap to seek on left or right side of the screen.
  final bool seekOnDoubleTap;

  /// Whether to allow double tap to seek on left or right side of the screen to work while controls are visible.
  /// NOTE: This option is ignored when [seekOnDoubleTap] is false.
  final bool seekOnDoubleTapEnabledWhileControlsVisible;

  /// `seekOnDoubleTapLayoutTapsRatios` defines the width proportions for the interactive areas
  /// responsible for seek actions (backward seek, instant tap, forward seek) when a double tap
  /// occurs on the video widget. This property divides the video widget into three segments
  /// horizontally. Each integer in the list represents the relative width of each segment.
  /// By default, the value `[1, 1, 1]` means that the video widget is equally divided into three
  /// segments: the left segment for backward seek, the middle segment for instant tap (usually show and hide controls),
  /// and the right segment for forward seek. Adjusting these values changes the width of the interactive areas
  /// for each double tap action.
  final List<int> seekOnDoubleTapLayoutTapsRatios;

  /// `seekOnDoubleTapLayoutWidgetRatios` defines the width proportions for the visual indicators or
  /// widgets that appear during the double tap actions (backward seek, instant tap, forward seek).
  /// Similar to `seekOnDoubleTapLayoutTapsRatios`, it divides the area where these indicators are
  /// displayed into three segments. Each integer in the list represents the relative width of each
  /// segment where the corresponding indicators will be shown. The default `[1, 1, 1]` equally divides
  /// the space for each indicator. Modifying these values can change the layout of the seek indicators,
  /// giving more or less space to each one based on the specified ratios.
  final List<int> seekOnDoubleTapLayoutWidgetRatios;

  /// Duration of seek on double tap backward.
  final Duration seekOnDoubleTapBackwardDuration;

  /// Duration of seek on double tap forward.
  final Duration seekOnDoubleTapForwardDuration;

  /// Whether the controls are initially visible.
  final bool visibleOnMount;

  /// Whether to speed up on long press.
  final bool speedUpOnLongPress;

  /// Factor to speed up on long press.
  final double speedUpFactor;

  /// Gesture sensitivity on vertical drag gestures, the higher the value is the less sensitive the gesture.
  final double verticalGestureSensitivity;

  /// Gesture sensitivity on horizontal drag gestures, the higher the value is the less sensitive the gesture.
  final double horizontalGestureSensitivity;

  /// Color of backdrop that comes up when controls are visible.
  final Color? backdropColor;

  /// The start color for the top/bottom readability shades.
  ///
  /// The gradients are painted directly by the root controls stack, therefore
  /// they always share its visibility animation and physical viewport.
  final Color? edgeShadeColor;

  /// Host overlay sharing the built-in controls visibility and fade.
  final WidgetBuilder? controlsOverlayBuilder;

  /// Full-size, non-interactive overlay with root-relative gesture coordinates.
  final Widget Function(BuildContext, MaterialVerticalGestureIndicatorData)?
      verticalGestureIndicatorBuilder;

  // GENERIC

  /// Padding around the controls.
  ///
  /// * Default: `EdgeInsets.zero`
  /// * FullScreen: `MediaQuery.of(context).padding`
  ///
  /// NOTE: In fullscreen, this will be safe area (set [padding] to [EdgeInsets.zero] to disable safe area)
  final EdgeInsets? padding;

  /// [Duration] after which the controls will be hidden when there is no mouse movement.
  final Duration controlsHoverDuration;

  /// [Duration] for which the controls will be animated when shown or hidden.
  final Duration controlsTransitionDuration;

  /// Builder for the buffering indicator.
  final Widget Function(BuildContext)? bufferingIndicatorBuilder;

  /// Custom builder for volume indicator.
  final Widget Function(BuildContext, double)? volumeIndicatorBuilder;

  /// Custom builder for brightness indicator.
  final Widget Function(BuildContext, double)? brightnessIndicatorBuilder;

  /// Custom builder for seek indicator.
  final Widget Function(BuildContext, Duration)? seekIndicatorBuilder;

  /// Custom builder for seek indicator.
  final Widget Function(BuildContext, double)? speedUpIndicatorBuilder;

  // BUTTON BAR

  /// Buttons to be displayed in the primary button bar.
  final List<Widget> primaryButtonBar;

  /// Buttons to be displayed in the top button bar.
  final List<Widget> topButtonBar;

  /// Margin around the top button bar.
  final EdgeInsets topButtonBarMargin;

  /// Buttons to be displayed in the bottom button bar.
  final List<Widget> bottomButtonBar;

  /// Margin around the button bar.
  final EdgeInsets bottomButtonBarMargin;

  /// Height of the button bar.
  final double buttonBarHeight;

  /// Size of the button bar buttons.
  final double buttonBarButtonSize;

  /// Color of the button bar buttons.
  final Color buttonBarButtonColor;

  // SEEK BAR

  /// Margin around the seek bar.
  final EdgeInsets seekBarMargin;

  /// Height of the seek bar.
  final double seekBarHeight;

  /// Height of the seek bar [Container].
  final double seekBarContainerHeight;

  /// [Color] of the seek bar.
  final Color seekBarColor;

  /// [Color] of the playback position section in the seek bar.
  final Color seekBarPositionColor;

  /// [Color] of the playback buffer section in the seek bar.
  final Color seekBarBufferColor;

  /// Size of the seek bar thumb.
  final double seekBarThumbSize;

  /// [Color] of the seek bar thumb.
  final Color seekBarThumbColor;

  /// [Alignment] of seek bar inside the seek bar container.
  final Alignment seekBarAlignment;

  // SUBTITLE

  /// Whether to shift the subtitles upwards when the controls are visible.
  final bool shiftSubtitlesOnControlsVisibilityChange;

  /// {@macro material_video_controls_theme_data}
  const MaterialVideoControlsThemeData({
    this.displaySeekBar = true,
    this.automaticallyImplySkipNextButton = true,
    this.automaticallyImplySkipPreviousButton = true,
    this.volumeGesture = false,
    this.brightnessGesture = false,
    this.seekGesture = false,
    this.gesturesEnabledWhileControlsVisible = true,
    this.controlsLocked = false,
    this.hideControlsOnMouseExit = false,
    this.hideMouseOnControlsRemoval = false,
    this.keyboardShortcuts,
    this.onMouseDoubleTap,
    this.onSecondaryTap,
    this.seekOnDoubleTap = false,
    this.seekOnDoubleTapEnabledWhileControlsVisible = true,
    this.seekOnDoubleTapLayoutTapsRatios = const [1, 1, 1],
    this.seekOnDoubleTapLayoutWidgetRatios = const [1, 1, 1],
    this.seekOnDoubleTapBackwardDuration = const Duration(seconds: 10),
    this.seekOnDoubleTapForwardDuration = const Duration(seconds: 10),
    this.visibleOnMount = false,
    this.speedUpOnLongPress = false,
    this.speedUpFactor = 2.0,
    this.verticalGestureSensitivity = 100,
    this.horizontalGestureSensitivity = 1000,
    this.backdropColor = const Color(0x66000000),
    this.edgeShadeColor,
    this.padding,
    this.controlsHoverDuration = const Duration(seconds: 3),
    this.controlsTransitionDuration = const Duration(milliseconds: 300),
    this.controlsOverlayBuilder,
    this.verticalGestureIndicatorBuilder,
    this.bufferingIndicatorBuilder,
    this.volumeIndicatorBuilder,
    this.brightnessIndicatorBuilder,
    this.seekIndicatorBuilder,
    this.speedUpIndicatorBuilder,
    this.primaryButtonBar = const [
      Spacer(flex: 2),
      MaterialSkipPreviousButton(),
      Spacer(),
      MaterialPlayOrPauseButton(iconSize: 48.0),
      Spacer(),
      MaterialSkipNextButton(),
      Spacer(flex: 2),
    ],
    this.topButtonBar = const [],
    this.topButtonBarMargin = const EdgeInsets.symmetric(horizontal: 16.0),
    this.bottomButtonBar = const [
      MaterialPositionIndicator(),
      Spacer(),
      MaterialFullscreenButton(),
    ],
    this.bottomButtonBarMargin = const EdgeInsets.only(left: 16.0, right: 8.0),
    this.buttonBarHeight = 56.0,
    this.buttonBarButtonSize = 24.0,
    this.buttonBarButtonColor = const Color(0xFFFFFFFF),
    this.seekBarMargin = EdgeInsets.zero,
    this.seekBarHeight = 2.4,
    this.seekBarContainerHeight = 36.0,
    this.seekBarColor = const Color(0x3DFFFFFF),
    this.seekBarPositionColor = const Color(0xFFFF0000),
    this.seekBarBufferColor = const Color(0x3DFFFFFF),
    this.seekBarThumbSize = 12.8,
    this.seekBarThumbColor = const Color(0xFFFF0000),
    this.seekBarAlignment = Alignment.bottomCenter,
    this.shiftSubtitlesOnControlsVisibilityChange = false,
  });

  /// Creates a copy of this [MaterialVideoControlsThemeData] with the given fields replaced by the non-null parameter values.
  MaterialVideoControlsThemeData copyWith({
    bool? displaySeekBar,
    bool? automaticallyImplySkipNextButton,
    bool? automaticallyImplySkipPreviousButton,
    bool? volumeGesture,
    bool? brightnessGesture,
    bool? seekGesture,
    bool? gesturesEnabledWhileControlsVisible,
    bool? controlsLocked,
    bool? hideControlsOnMouseExit,
    bool? hideMouseOnControlsRemoval,
    Map<ShortcutActivator, VoidCallback>? keyboardShortcuts,
    VoidCallback? onMouseDoubleTap,
    VoidCallback? onSecondaryTap,
    bool? seekOnDoubleTap,
    bool? seekOnDoubleTapEnabledWhileControlsVisible,
    List<int>? seekOnDoubleTapLayoutTapsRatios,
    List<int>? seekOnDoubleTapLayoutWidgetRatios,
    Duration? seekOnDoubleTapBackwardDuration,
    Duration? seekOnDoubleTapForwardDuration,
    bool? visibleOnMount,
    bool? speedUpOnLongPress,
    double? speedUpFactor,
    double? verticalGestureSensitivity,
    double? horizontalGestureSensitivity,
    Color? backdropColor,
    Color? edgeShadeColor,
    Duration? controlsHoverDuration,
    Duration? controlsTransitionDuration,
    WidgetBuilder? controlsOverlayBuilder,
    Widget Function(BuildContext, MaterialVerticalGestureIndicatorData)?
        verticalGestureIndicatorBuilder,
    Widget Function(BuildContext)? bufferingIndicatorBuilder,
    Widget Function(BuildContext, double)? volumeIndicatorBuilder,
    Widget Function(BuildContext, double)? brightnessIndicatorBuilder,
    Widget Function(BuildContext, Duration)? seekIndicatorBuilder,
    Widget Function(BuildContext, double)? speedUpIndicatorBuilder,
    List<Widget>? primaryButtonBar,
    List<Widget>? topButtonBar,
    EdgeInsets? topButtonBarMargin,
    List<Widget>? bottomButtonBar,
    EdgeInsets? bottomButtonBarMargin,
    double? buttonBarHeight,
    double? buttonBarButtonSize,
    Color? buttonBarButtonColor,
    EdgeInsets? seekBarMargin,
    double? seekBarHeight,
    double? seekBarContainerHeight,
    Color? seekBarColor,
    Color? seekBarPositionColor,
    Color? seekBarBufferColor,
    double? seekBarThumbSize,
    Color? seekBarThumbColor,
    Alignment? seekBarAlignment,
    bool? shiftSubtitlesOnControlsVisibilityChange,
  }) {
    return MaterialVideoControlsThemeData(
      displaySeekBar: displaySeekBar ?? this.displaySeekBar,
      automaticallyImplySkipNextButton: automaticallyImplySkipNextButton ??
          this.automaticallyImplySkipNextButton,
      automaticallyImplySkipPreviousButton:
          automaticallyImplySkipPreviousButton ??
              this.automaticallyImplySkipPreviousButton,
      volumeGesture: volumeGesture ?? this.volumeGesture,
      brightnessGesture: brightnessGesture ?? this.brightnessGesture,
      seekGesture: seekGesture ?? this.seekGesture,
      gesturesEnabledWhileControlsVisible:
          gesturesEnabledWhileControlsVisible ??
              this.gesturesEnabledWhileControlsVisible,
      controlsLocked: controlsLocked ?? this.controlsLocked,
      hideControlsOnMouseExit:
          hideControlsOnMouseExit ?? this.hideControlsOnMouseExit,
      hideMouseOnControlsRemoval:
          hideMouseOnControlsRemoval ?? this.hideMouseOnControlsRemoval,
      keyboardShortcuts: keyboardShortcuts ?? this.keyboardShortcuts,
      onMouseDoubleTap: onMouseDoubleTap ?? this.onMouseDoubleTap,
      onSecondaryTap: onSecondaryTap ?? this.onSecondaryTap,
      seekOnDoubleTap: seekOnDoubleTap ?? this.seekOnDoubleTap,
      seekOnDoubleTapEnabledWhileControlsVisible:
          seekOnDoubleTapEnabledWhileControlsVisible ??
              this.seekOnDoubleTapEnabledWhileControlsVisible,
      seekOnDoubleTapLayoutTapsRatios: seekOnDoubleTapLayoutTapsRatios ??
          this.seekOnDoubleTapLayoutTapsRatios,
      seekOnDoubleTapLayoutWidgetRatios: seekOnDoubleTapLayoutWidgetRatios ??
          this.seekOnDoubleTapLayoutWidgetRatios,
      seekOnDoubleTapBackwardDuration: seekOnDoubleTapBackwardDuration ??
          this.seekOnDoubleTapBackwardDuration,
      seekOnDoubleTapForwardDuration:
          seekOnDoubleTapForwardDuration ?? this.seekOnDoubleTapForwardDuration,
      visibleOnMount: visibleOnMount ?? this.visibleOnMount,
      speedUpOnLongPress: speedUpOnLongPress ?? this.speedUpOnLongPress,
      speedUpFactor: speedUpFactor ?? this.speedUpFactor,
      verticalGestureSensitivity:
          verticalGestureSensitivity ?? this.verticalGestureSensitivity,
      horizontalGestureSensitivity:
          horizontalGestureSensitivity ?? this.horizontalGestureSensitivity,
      backdropColor: backdropColor ?? this.backdropColor,
      edgeShadeColor: edgeShadeColor ?? this.edgeShadeColor,
      controlsHoverDuration:
          controlsHoverDuration ?? this.controlsHoverDuration,
      controlsTransitionDuration:
          controlsTransitionDuration ?? this.controlsTransitionDuration,
      controlsOverlayBuilder:
          controlsOverlayBuilder ?? this.controlsOverlayBuilder,
      verticalGestureIndicatorBuilder: verticalGestureIndicatorBuilder ??
          this.verticalGestureIndicatorBuilder,
      bufferingIndicatorBuilder:
          bufferingIndicatorBuilder ?? this.bufferingIndicatorBuilder,
      volumeIndicatorBuilder:
          volumeIndicatorBuilder ?? this.volumeIndicatorBuilder,
      brightnessIndicatorBuilder:
          brightnessIndicatorBuilder ?? this.brightnessIndicatorBuilder,
      seekIndicatorBuilder: seekIndicatorBuilder ?? this.seekIndicatorBuilder,
      speedUpIndicatorBuilder:
          speedUpIndicatorBuilder ?? this.speedUpIndicatorBuilder,
      primaryButtonBar: primaryButtonBar ?? this.primaryButtonBar,
      topButtonBar: topButtonBar ?? this.topButtonBar,
      topButtonBarMargin: topButtonBarMargin ?? this.topButtonBarMargin,
      bottomButtonBar: bottomButtonBar ?? this.bottomButtonBar,
      bottomButtonBarMargin:
          bottomButtonBarMargin ?? this.bottomButtonBarMargin,
      buttonBarHeight: buttonBarHeight ?? this.buttonBarHeight,
      buttonBarButtonSize: buttonBarButtonSize ?? this.buttonBarButtonSize,
      buttonBarButtonColor: buttonBarButtonColor ?? this.buttonBarButtonColor,
      seekBarMargin: seekBarMargin ?? this.seekBarMargin,
      seekBarHeight: seekBarHeight ?? this.seekBarHeight,
      seekBarContainerHeight:
          seekBarContainerHeight ?? this.seekBarContainerHeight,
      seekBarColor: seekBarColor ?? this.seekBarColor,
      seekBarPositionColor: seekBarPositionColor ?? this.seekBarPositionColor,
      seekBarBufferColor: seekBarBufferColor ?? this.seekBarBufferColor,
      seekBarThumbSize: seekBarThumbSize ?? this.seekBarThumbSize,
      seekBarThumbColor: seekBarThumbColor ?? this.seekBarThumbColor,
      seekBarAlignment: seekBarAlignment ?? this.seekBarAlignment,
      shiftSubtitlesOnControlsVisibilityChange:
          shiftSubtitlesOnControlsVisibilityChange ??
              this.shiftSubtitlesOnControlsVisibilityChange,
    );
  }
}

/// {@template material_video_controls_theme}
///
/// Inherited widget which provides [MaterialVideoControlsThemeData] to descendant widgets.
///
/// {@endtemplate}
class MaterialVideoControlsTheme extends InheritedWidget {
  final MaterialVideoControlsThemeData normal;
  final MaterialVideoControlsThemeData fullscreen;
  const MaterialVideoControlsTheme({
    super.key,
    required this.normal,
    required this.fullscreen,
    required super.child,
  });

  static MaterialVideoControlsTheme? maybeOf(BuildContext context) {
    return context
        .dependOnInheritedWidgetOfExactType<MaterialVideoControlsTheme>();
  }

  static MaterialVideoControlsTheme of(BuildContext context) {
    final MaterialVideoControlsTheme? result = maybeOf(context);
    assert(
      result != null,
      'No [MaterialVideoControlsTheme] found in [context]',
    );
    return result!;
  }

  @override
  bool updateShouldNotify(MaterialVideoControlsTheme oldWidget) =>
      !identical(normal, oldWidget.normal) ||
      !identical(fullscreen, oldWidget.fullscreen);
}

/// {@macro material_video_controls}
class _MaterialVideoControls extends StatefulWidget {
  const _MaterialVideoControls();

  @override
  State<_MaterialVideoControls> createState() => _MaterialVideoControlsState();
}

/// {@macro material_video_controls}
class _MaterialVideoControlsState extends State<_MaterialVideoControls> {
  late bool mount = _theme(context).visibleOnMount;
  late bool visible = _theme(context).visibleOnMount;
  Timer? _timer;

  final GlobalKey _controlsRootKey = GlobalKey();
  MaterialVerticalGestureKind? _verticalKind;

  /// The most recent vertical gesture kind. The indicator widget keeps fading
  /// out after its flag clears, so the kind must not fall back to a default
  /// while that fade is still running (a volume gesture would otherwise
  /// repaint as the brightness indicator for the last frames).
  MaterialVerticalGestureKind? _lastVerticalKind;
  Offset? _verticalPosition;
  bool _verticalDragging = false;

  /// Level when the drag began; every update is computed from this rather than
  /// from the previous frame, so platform echoes cannot skew the result.
  double _verticalStartValue = 0.0;

  /// Sum of `delta.dy` since the drag began (negative = finger moved up).
  double _verticalDeltaTotal = 0.0;

  Offset? _rootPosition(Offset global) {
    final box = _controlsRootKey.currentContext?.findRenderObject();
    return box is RenderBox ? box.globalToLocal(global) : null;
  }

  void _endVerticalGesture() {
    if (!_verticalDragging) return;
    setState(() {
      _verticalDragging = false;
      _lastVerticalKind = _verticalKind;
      if (_verticalKind == MaterialVerticalGestureKind.volume) {
        _volumeIndicator = true;
      } else {
        _brightnessIndicator = true;
      }
    });
    if (_verticalKind == MaterialVerticalGestureKind.volume) {
      _volumeTimer?.cancel();
      _volumeTimer = Timer(const Duration(milliseconds: 800), () {
        setState(() => _volumeIndicator = false);
      });
    } else {
      _brightnessTimer?.cancel();
      _brightnessTimer = Timer(const Duration(milliseconds: 800), () {
        setState(() => _brightnessIndicator = false);
      });
    }
  }

  double _brightnessValue = 0.0;
  bool _brightnessIndicator = false;
  Timer? _brightnessTimer;
  Timer? _brightnessInterceptTimer;
  bool _brightnessInterceptEventStream = false;
  bool _brightnessWriteInProgress = false;
  double? _pendingBrightnessValue;
  double _currentRate = 1.0;
  double _volumeValue = 0.0;
  bool _volumeIndicator = false;
  Timer? _volumeTimer;
  Timer? _volumeInterceptTimer;
  // The default event stream in package:volume_controller is buggy.
  bool _volumeInterceptEventStream = false;

  Offset _dragInitialDelta =
      Offset.zero; // Initial position for horizontal drag
  int swipeDuration = 0; // Duration to seek in video
  bool showSwipeDuration = false; // Whether to show the seek duration overlay

  bool _speedUpIndicator = false;
  late /* private */ var playlist = controller(context).player.state.playlist;
  late bool buffering = controller(context).player.state.buffering;
  final VolumeController _volumeController = VolumeController.instance;

  bool _mountSeekBackwardButton = false;
  bool _mountSeekForwardButton = false;
  bool _hideSeekBackwardButton = false;
  bool _hideSeekForwardButton = false;
  Timer? _timerSeekBackwardButton;
  Timer? _timerSeekForwardButton;
  int _seekPreviewGeneration = 0;
  int _horizontalSeekGeneration = 0;
  Duration? _horizontalDragStartPosition;
  Duration? _horizontalDragTarget;

  final ValueNotifier<Duration> _seekBarDeltaValueNotifier =
      ValueNotifier<Duration>(Duration.zero);
  final ValueNotifier<Duration?> _seekBarPositionPreviewValueNotifier =
      ValueNotifier<Duration?>(null);

  final List<StreamSubscription> subscriptions = [];

  /// The screen-brightness change subscription — kept out of [subscriptions]
  /// because it is created from an async microtask that may complete after
  /// dispose() has already iterated that list.
  StreamSubscription<double>? _brightnessSubscription;

  double get subtitleVerticalShiftOffset =>
      (_theme(context).padding?.bottom ?? 0.0) +
      (_theme(context).bottomButtonBarMargin.vertical) +
      (_theme(context).bottomButtonBar.isNotEmpty
          ? _theme(context).buttonBarHeight
          : 0.0);
  Offset? _tapPosition;
  bool _doubleTapWasMouse = false;
  PointerDeviceKind? _activePointerKind;
  bool _horizontalDragWasMouse = false;
  bool _horizontalDragControlsWereVisible = false;

  void _handleDoubleTapDown(TapDownDetails details) {
    setState(() {
      _tapPosition = details.localPosition;
      _doubleTapWasMouse = details.kind == PointerDeviceKind.mouse;
    });
  }

  /// Make the compact touch-style controls behave naturally with a mouse too:
  /// moving a pointer reveals the bars while taps keep their desktop meaning.
  void showControls() {
    if (!visible) {
      setState(() {
        mount = true;
        visible = true;
      });
      shiftSubtitle();
    }
    _scheduleControlsHide();
  }

  void _scheduleControlsHide() {
    _timer?.cancel();
    _timer = Timer(_theme(context).controlsHoverDuration, hideControls);
  }

  void hideControls() {
    _timer?.cancel();
    if (!visible) return;
    setState(() {
      visible = false;
    });
    unshiftSubtitle();
  }

  void _handleLongPress() {
    if (_activePointerKind == PointerDeviceKind.mouse) return;
    setState(() {
      _speedUpIndicator = true;
    });
    _currentRate = controller(context).player.state.rate;
    controller(context).player.setRate(_theme(context).speedUpFactor);
  }

  void _handleLongPressEnd(LongPressEndDetails details) {
    if (!_speedUpIndicator) return;
    setState(() {
      _speedUpIndicator = false;
    });
    controller(context).player.setRate(_currentRate);
  }

  @override
  void setState(VoidCallback fn) {
    if (mounted) {
      super.setState(fn);
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_theme(context).controlsLocked) {
      _verticalDragging = false;
      _verticalPosition = null;
      _brightnessIndicator = false;
      _volumeIndicator = false;
    }
    if (subscriptions.isEmpty) {
      subscriptions.addAll(
        [
          controller(context).player.stream.playlist.listen(
            (event) {
              setState(() {
                playlist = event;
              });
            },
          ),
          controller(context).player.stream.buffering.listen(
            (event) {
              setState(() {
                buffering = event;
              });
            },
          ),
        ],
      );

      if (_theme(context).visibleOnMount) {
        _scheduleControlsHide();
      }
    }
  }

  @override
  void dispose() {
    for (final subscription in subscriptions) {
      subscription.cancel();
    }
    // --------------------------------------------------
    // package:volume_controller
    _volumeController.removeListener();
    // --------------------------------------------------
    // package:screen_brightness
    _brightnessSubscription?.cancel();
    Future.microtask(() async {
      try {
        await ScreenBrightnessPlatform.instance
            .resetApplicationScreenBrightness();
      } catch (_) {}
    });
    // --------------------------------------------------
    _timer?.cancel();
    _volumeTimer?.cancel();
    _volumeInterceptTimer?.cancel();
    _brightnessTimer?.cancel();
    _brightnessInterceptTimer?.cancel();
    _timerSeekBackwardButton?.cancel();
    _timerSeekForwardButton?.cancel();
    _seekBarDeltaValueNotifier.dispose();
    _seekBarPositionPreviewValueNotifier.dispose();
    super.dispose();
  }

  void shiftSubtitle() {
    if (_theme(context).shiftSubtitlesOnControlsVisibilityChange) {
      state(context).setSubtitleViewPadding(
        state(context).widget.subtitleViewConfiguration.padding +
            EdgeInsets.fromLTRB(
              0.0,
              0.0,
              0.0,
              subtitleVerticalShiftOffset,
            ),
      );
    }
  }

  void unshiftSubtitle() {
    if (_theme(context).shiftSubtitlesOnControlsVisibilityChange) {
      state(context).setSubtitleViewPadding(
        state(context).widget.subtitleViewConfiguration.padding,
      );
    }
  }

  void onTap() {
    if (!visible) {
      showControls();
    } else {
      hideControls();
    }
  }

  void onDoubleTapSeekBackward() {
    setState(() {
      _mountSeekBackwardButton = true;
    });
  }

  void onDoubleTapSeekForward() {
    setState(() {
      _mountSeekForwardButton = true;
    });
  }

  /// Shared keyboard behavior for iPad/Android hardware keyboards and desktop
  /// PCs. It is intentionally attached to the same controls implementation as
  /// touch, so switching input devices never switches the player's UI model.
  KeyEventResult _handleKeyEvent(FocusNode _, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    final player = controller(context).player;
    final position = player.state.position;
    final duration = player.state.duration;

    Duration clampPosition(Duration value) {
      if (value < Duration.zero) return Duration.zero;
      if (duration > Duration.zero && value > duration) return duration;
      return value;
    }

    final key = event.logicalKey;
    if (key == LogicalKeyboardKey.space ||
        key == LogicalKeyboardKey.mediaPlayPause) {
      player.playOrPause();
    } else if (key == LogicalKeyboardKey.arrowLeft ||
        key == LogicalKeyboardKey.keyJ) {
      player.seek(clampPosition(position - const Duration(seconds: 5)));
    } else if (key == LogicalKeyboardKey.arrowRight ||
        key == LogicalKeyboardKey.keyL) {
      player.seek(clampPosition(position + const Duration(seconds: 5)));
    } else if (key == LogicalKeyboardKey.arrowUp) {
      player.setVolume((player.state.volume + 5.0).clamp(0.0, 100.0));
    } else if (key == LogicalKeyboardKey.arrowDown) {
      player.setVolume((player.state.volume - 5.0).clamp(0.0, 100.0));
    } else {
      return KeyEventResult.ignored;
    }
    showControls();
    return KeyEventResult.handled;
  }

  void onHorizontalDragStart() {
    final position = controller(context).player.state.position;
    _horizontalSeekGeneration++;
    _horizontalDragStartPosition = position;
    _horizontalDragTarget = position;
    _dragInitialDelta = Offset.zero;
    _seekBarDeltaValueNotifier.value = Duration.zero;
  }

  void onHorizontalDragUpdate(DragUpdateDetails details) {
    if (_dragInitialDelta == Offset.zero) {
      _dragInitialDelta = details.localPosition;
      return;
    }

    final diff = _dragInitialDelta.dx - details.localPosition.dx;
    final duration = controller(context).player.state.duration;
    if (duration <= Duration.zero) return;
    final start = _horizontalDragStartPosition ??
        controller(context).player.state.position;

    final milliseconds = -(diff *
            duration.inMilliseconds /
            _theme(context).horizontalGestureSensitivity)
        .round();
    final target = (start + Duration(milliseconds: milliseconds)).clamp(
      Duration.zero,
      duration,
    );

    setState(() {
      _horizontalDragTarget = target;
      swipeDuration = (target - start).inSeconds;
      showSwipeDuration = true;
      _seekBarPositionPreviewValueNotifier.value = target;
    });
  }

  Future<void> onHorizontalDragEnd() async {
    final player = controller(context).player;
    final start = _horizontalDragStartPosition;
    final target = _horizontalDragTarget;
    final generation = ++_horizontalSeekGeneration;

    setState(() {
      _dragInitialDelta = Offset.zero;
      _horizontalDragStartPosition = null;
      _horizontalDragTarget = null;
      swipeDuration = 0;
      showSwipeDuration = false;
    });

    if (start == null || target == null || target == start) {
      if (generation == _horizontalSeekGeneration) {
        _seekBarPositionPreviewValueNotifier.value = null;
      }
      return;
    }

    final applied = Completer<void>();
    void accept(Duration position) {
      if ((position - target).abs() <= const Duration(milliseconds: 750) &&
          !applied.isCompleted) {
        applied.complete();
      }
    }

    final subscription = player.stream.position.listen(accept);
    try {
      await player.seek(target);
      accept(player.state.position);
      await applied.future.timeout(
        const Duration(seconds: 4),
        onTimeout: () {},
      );
    } catch (_) {
      // A failed seek is reported by the player's normal error channel. The
      // preview still has to be released so the bar can resume live updates.
    } finally {
      await subscription.cancel();
      if (generation == _horizontalSeekGeneration) {
        _seekBarPositionPreviewValueNotifier.value = null;
      }
    }
  }

  void onHorizontalDragCancel() {
    _horizontalDragWasMouse = false;
    _horizontalSeekGeneration++;
    setState(() {
      _dragInitialDelta = Offset.zero;
      _horizontalDragStartPosition = null;
      _horizontalDragTarget = null;
      swipeDuration = 0;
      showSwipeDuration = false;
      _seekBarDeltaValueNotifier.value = Duration.zero;
      _seekBarPositionPreviewValueNotifier.value = null;
    });
  }

  bool _isInSegment(double localX, int segmentIndex) {
    // Local variable with the list of ratios
    List<int> segmentRatios = _theme(context).seekOnDoubleTapLayoutTapsRatios;

    int totalRatios = segmentRatios.reduce((a, b) => a + b);

    double segmentWidthMultiplier = widgetWidth(context) / totalRatios;
    double start = 0;
    double end;

    for (int i = 0; i < segmentRatios.length; i++) {
      end = start + (segmentWidthMultiplier * segmentRatios[i]);

      // Check if the current index matches the segmentIndex and if localX falls within it
      if (i == segmentIndex && localX >= start && localX <= end) {
        return true;
      }

      // Set the start of the next segment
      start = end;
    }

    // If localX does not fall within the specified segment
    return false;
  }

  bool _isInRightSegment(double localX) {
    return _isInSegment(localX, 2);
  }

  bool _isInLeftSegment(double localX) {
    return _isInSegment(localX, 0);
  }

  @override
  void initState() {
    super.initState();
    // --------------------------------------------------
    // package:volume_controller
    Future.microtask(() async {
      try {
        _volumeController.showSystemUI = false;
        _volumeValue = await _volumeController.getVolume();
        // The awaits above can outlive this State: never register a listener
        // on the already-disposed instance (dispose's removeListener would
        // have run before this microtask got here).
        if (!mounted) return;
        var firstVolumeEvent = true;
        _volumeController.addListener((value) {
          // Some platforms replay the current system volume immediately when
          // a listener is attached. It is initialization, not a user action,
          // so do not flash the volume OSD as soon as the player opens. If the
          // first event already differs (e.g. a hardware key was pressed while
          // awaiting getVolume), it remains a real change and is shown.
          if (firstVolumeEvent) {
            firstVolumeEvent = false;
            if ((value - _volumeValue).abs() < 0.0001) return;
          }
          if (mounted && !_volumeInterceptEventStream) {
            setState(() {
              _volumeValue = value;
              _verticalPosition = null;
              _volumeIndicator = true;
              _lastVerticalKind = MaterialVerticalGestureKind.volume;
            });
            _volumeTimer?.cancel();
            _volumeTimer = Timer(const Duration(milliseconds: 800), () {
              if (mounted) {
                setState(() => _volumeIndicator = false);
              }
            });
          }
        });
      } catch (_) {}
    });
    // --------------------------------------------------
    // --------------------------------------------------
    // package:screen_brightness
    Future.microtask(() async {
      try {
        // Every platform plugin defaults to animating a brightness write over
        // about a second (iOS queues ~100 stepped operations). A gesture emits
        // a new target every frame, so each write cancelled the previous
        // animation and the screen only settled once the finger stopped.
        // Writing the value directly is what makes dragging feel immediate.
        await ScreenBrightnessPlatform.instance.setAnimate(false);
      } catch (_) {}
      try {
        _brightnessValue = await ScreenBrightnessPlatform.instance.application;
        if (!mounted) return;
        _brightnessSubscription = ScreenBrightnessPlatform
            .instance.onApplicationScreenBrightnessChanged
            .listen((value) {
          if (mounted && !_brightnessInterceptEventStream) {
            setState(() {
              _brightnessValue = value;
            });
          }
        });
      } catch (_) {}
    });
    // --------------------------------------------------
  }

  Future<void> setVolume(double value) async {
    // --------------------------------------------------
    // package:volume_controller
    final target = value.clamp(0.0, 1.0).toDouble();
    setState(() {
      _volumeValue = target;
      _volumeIndicator = true;
      _lastVerticalKind = MaterialVerticalGestureKind.volume;
      _volumeInterceptEventStream = true;
    });
    _volumeInterceptTimer?.cancel();
    _volumeInterceptTimer = Timer(const Duration(milliseconds: 120), () {
      _volumeInterceptEventStream = false;
    });
    _volumeTimer?.cancel();
    _volumeTimer = Timer(const Duration(milliseconds: 800), () {
      if (mounted) {
        setState(() => _volumeIndicator = false);
      }
    });
    try {
      await _volumeController.setVolume(target);
    } catch (_) {}
    // --------------------------------------------------
  }

  Future<void> setBrightness(double value) async {
    // --------------------------------------------------
    // package:screen_brightness
    final target = value.clamp(0.0, 1.0).toDouble();
    setState(() {
      _brightnessValue = target;
      _brightnessIndicator = true;
      _lastVerticalKind = MaterialVerticalGestureKind.brightness;
      _brightnessInterceptEventStream = true;
    });
    _brightnessInterceptTimer?.cancel();
    _brightnessTimer?.cancel();
    _brightnessTimer = Timer(const Duration(milliseconds: 800), () {
      if (mounted) {
        setState(() => _brightnessIndicator = false);
      }
    });
    _pendingBrightnessValue = target;
    if (_brightnessWriteInProgress) return;

    _brightnessWriteInProgress = true;
    try {
      // Keep at most one native call in flight and replace queued samples with
      // the newest target, so a slow platform channel cannot build up a stale
      // backlog while the finger keeps moving.
      while (_pendingBrightnessValue != null) {
        final pending = _pendingBrightnessValue!;
        _pendingBrightnessValue = null;
        try {
          await ScreenBrightnessPlatform.instance
              .setApplicationScreenBrightness(pending);
        } catch (_) {}
      }
    } finally {
      _brightnessWriteInProgress = false;
      if (!mounted) {
        _brightnessInterceptEventStream = false;
      } else {
        // A platform event can arrive just after the Future completes. Ignore
        // that echo briefly so an older native value cannot replace the latest
        // value already displayed by Flutter.
        _brightnessInterceptTimer = Timer(
          const Duration(milliseconds: 160),
          () {
            _brightnessInterceptEventStream = false;
          },
        );
      }
    }
    // --------------------------------------------------
  }

  /// Builds the brightness/volume OSD. See [resolveVerticalGestureKind] for
  /// why the last kind is remembered across the fade-out.
  Widget _buildVerticalGestureIndicator(BuildContext context) {
    final kind = resolveVerticalGestureKind(
      dragging: _verticalDragging,
      activeKind: _verticalKind,
      volumeIndicator: _volumeIndicator,
      brightnessIndicator: _brightnessIndicator,
      lastKind: _lastVerticalKind,
    );
    return _theme(context).verticalGestureIndicatorBuilder!(
      context,
      MaterialVerticalGestureIndicatorData(
        kind: kind,
        value: kind == MaterialVerticalGestureKind.volume
            ? _volumeValue
            : _brightnessValue,
        position: _verticalPosition,
        isDragging: _verticalDragging,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final controlsLocked = _theme(context).controlsLocked;
    var seekOnDoubleTapEnabledWhileControlsAreVisible =
        (_theme(context).seekOnDoubleTap &&
            _theme(context).seekOnDoubleTapEnabledWhileControlsVisible);
    assert(_theme(context).seekOnDoubleTapLayoutTapsRatios.length == 3,
        "The number of seekOnDoubleTapLayoutTapsRatios must be 3, i.e. [1, 1, 1]");
    assert(_theme(context).seekOnDoubleTapLayoutWidgetRatios.length == 3,
        "The number of seekOnDoubleTapLayoutWidgetRatios must be 3, i.e. [1, 1, 1]");
    return Theme(
      data: Theme.of(context).copyWith(
        focusColor: const Color(0x00000000),
        hoverColor: const Color(0x00000000),
        splashColor: const Color(0x00000000),
        highlightColor: const Color(0x00000000),
      ),

      /// Add [Directionality] to ltr to avoid wrong animation of sides.
      child: Directionality(
        textDirection: TextDirection.ltr,
        child: MouseRegion(
          cursor: _theme(context).hideMouseOnControlsRemoval &&
                  !controlsLocked &&
                  !visible
              ? SystemMouseCursors.none
              : MouseCursor.defer,
          onEnter: controlsLocked ? null : (_) => showControls(),
          onHover: controlsLocked ? null : (_) => showControls(),
          onExit: controlsLocked || !_theme(context).hideControlsOnMouseExit
              ? null
              : (_) => hideControls(),
          child: CallbackShortcuts(
            bindings: _theme(context).keyboardShortcuts ??
                const <ShortcutActivator, VoidCallback>{},
            child: Focus(
              focusNode: videoViewParametersNotifier(context).value.focusNode,
              autofocus: true,
              onKeyEvent: controlsLocked ? null : _handleKeyEvent,
              child: Material(
                elevation: 0.0,
                borderOnForeground: false,
                animationDuration: Duration.zero,
                color: const Color(0x00000000),
                shadowColor: const Color(0x00000000),
                surfaceTintColor: const Color(0x00000000),
                child: Stack(
                  key: _controlsRootKey,
                  clipBehavior: Clip.none,
                  alignment: Alignment.center,
                  children: [
                    // Controls:
                    AnimatedOpacity(
                      curve: Curves.easeInOut,
                      opacity: visible && !controlsLocked ? 1.0 : 0.0,
                      duration: controlsLocked
                          ? Duration.zero
                          : _theme(context).controlsTransitionDuration,
                      onEnd: () {
                        setState(() {
                          if (!visible) {
                            mount = false;
                          }
                        });
                      },
                      child: Stack(
                        clipBehavior: Clip.none,
                        alignment: Alignment.center,
                        children: [
                          Positioned.fill(
                            child: Container(
                              color: _theme(context).backdropColor,
                            ),
                          ),
                          // These two gradients intentionally live in the same
                          // root stack as AnimatedOpacity.  A bar-local gradient
                          // is clipped by its layout width and may not meet the
                          // physical top/bottom screen boundaries.
                          if (_theme(context).edgeShadeColor != null)
                            Positioned.fill(
                              child: IgnorePointer(
                                child: Stack(
                                  fit: StackFit.expand,
                                  children: [
                                    Align(
                                      alignment: Alignment.topCenter,
                                      child: FractionallySizedBox(
                                        widthFactor: 1.0,
                                        heightFactor: 0.22,
                                        child: DecoratedBox(
                                          decoration: BoxDecoration(
                                            gradient: LinearGradient(
                                              begin: Alignment.topCenter,
                                              end: Alignment.bottomCenter,
                                              colors: [
                                                _theme(context).edgeShadeColor!,
                                                Color.lerp(
                                                  _theme(context)
                                                      .edgeShadeColor!,
                                                  Colors.transparent,
                                                  0.62,
                                                )!,
                                                Colors.transparent,
                                              ],
                                            ),
                                          ),
                                        ),
                                      ),
                                    ),
                                    Align(
                                      alignment: Alignment.bottomCenter,
                                      child: FractionallySizedBox(
                                        widthFactor: 1.0,
                                        heightFactor: 0.26,
                                        child: DecoratedBox(
                                          decoration: BoxDecoration(
                                            gradient: LinearGradient(
                                              begin: Alignment.bottomCenter,
                                              end: Alignment.topCenter,
                                              colors: [
                                                _theme(context).edgeShadeColor!,
                                                Color.lerp(
                                                  _theme(context)
                                                      .edgeShadeColor!,
                                                  Colors.transparent,
                                                  0.62,
                                                )!,
                                                Colors.transparent,
                                              ],
                                            ),
                                          ),
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          // We are adding 16.0 boundary around the actual controls (which contain the vertical drag gesture detectors).
                          // This will make the hit-test on edges (e.g. swiping to: show status-bar, show navigation-bar, go back in navigation) not activate the swipe gesture annoyingly.
                          Positioned.fill(
                            left: 16.0,
                            top: 16.0,
                            right: 16.0,
                            bottom: 16.0 + subtitleVerticalShiftOffset,
                            child: Listener(
                              onPointerDown: controlsLocked
                                  ? null
                                  : (event) => _activePointerKind = event.kind,
                              onPointerUp: (_) => _activePointerKind = null,
                              onPointerCancel: (_) => _activePointerKind = null,
                              child: GestureDetector(
                                // Let Flutter disambiguate a single tap from a
                                // double tap. The old PointerDown listener showed
                                // controls before the second tap arrived, making
                                // every quick-seek non-immersive.
                                onTap: controlsLocked ? null : onTap,
                                onSecondaryTap: controlsLocked
                                    ? null
                                    : _theme(context).onSecondaryTap,
                                onDoubleTapDown: controlsLocked
                                    ? null
                                    : _handleDoubleTapDown,
                                onLongPress: !controlsLocked &&
                                        _theme(context).speedUpOnLongPress
                                    ? _handleLongPress
                                    : null,
                                onLongPressEnd: !controlsLocked &&
                                        _theme(context).speedUpOnLongPress
                                    ? _handleLongPressEnd
                                    : null,
                                onDoubleTap: controlsLocked
                                    ? null
                                    : () {
                                        if (_tapPosition == null) {
                                          return;
                                        }
                                        if (_doubleTapWasMouse) {
                                          _theme(context)
                                              .onMouseDoubleTap
                                              ?.call();
                                          return;
                                        }
                                        // Touch uses outer quarters for seek and the
                                        // central half for play/pause.
                                        if (_isInRightSegment(
                                            _tapPosition!.dx)) {
                                          if ((!mount &&
                                                  _theme(context)
                                                      .seekOnDoubleTap) ||
                                              seekOnDoubleTapEnabledWhileControlsAreVisible) {
                                            onDoubleTapSeekForward();
                                          }
                                        } else if (_isInLeftSegment(
                                            _tapPosition!.dx)) {
                                          if ((!mount &&
                                                  _theme(context)
                                                      .seekOnDoubleTap) ||
                                              seekOnDoubleTapEnabledWhileControlsAreVisible) {
                                            onDoubleTapSeekBackward();
                                          }
                                        } else {
                                          controller(context)
                                              .player
                                              .playOrPause();
                                        }
                                      },
                                onHorizontalDragUpdate: controlsLocked
                                    ? null
                                    : (details) {
                                        if (details.kind ==
                                            PointerDeviceKind.mouse) {
                                          return;
                                        }
                                        if ((!mount &&
                                                _theme(context).seekGesture) ||
                                            (_theme(context).seekGesture &&
                                                _theme(context)
                                                    .gesturesEnabledWhileControlsVisible)) {
                                          onHorizontalDragUpdate(details);
                                        }
                                      },
                                onHorizontalDragStart: controlsLocked
                                    ? null
                                    : (details) {
                                        _horizontalDragWasMouse =
                                            details.kind ==
                                                PointerDeviceKind.mouse;
                                        _horizontalDragControlsWereVisible =
                                            !_horizontalDragWasMouse && visible;
                                        if (!_horizontalDragWasMouse) {
                                          // A touch drag now owns the shared seek
                                          // preview; stale double-tap timers must
                                          // not clear it mid-gesture.
                                          _seekPreviewGeneration++;
                                          onHorizontalDragStart();
                                        }
                                        if (_horizontalDragControlsWereVisible) {
                                          _timer?.cancel();
                                        }
                                      },
                                onHorizontalDragEnd: controlsLocked
                                    ? null
                                    : (_) {
                                        final ignored = _horizontalDragWasMouse;
                                        _horizontalDragWasMouse = false;
                                        if (ignored) return;
                                        unawaited(onHorizontalDragEnd());
                                        if (_horizontalDragControlsWereVisible &&
                                            visible) {
                                          _scheduleControlsHide();
                                        }
                                        _horizontalDragControlsWereVisible =
                                            false;
                                      },
                                onHorizontalDragCancel: controlsLocked
                                    ? null
                                    : () {
                                        onHorizontalDragCancel();
                                        if (_horizontalDragControlsWereVisible &&
                                            visible) {
                                          _scheduleControlsHide();
                                        }
                                        _horizontalDragControlsWereVisible =
                                            false;
                                      },
                                onVerticalDragStart: controlsLocked
                                    ? null
                                    : (details) {
                                        if (details.kind ==
                                            PointerDeviceKind.mouse) {
                                          return;
                                        }
                                        final position = _rootPosition(
                                            details.globalPosition);
                                        final root = _controlsRootKey
                                            .currentContext
                                            ?.findRenderObject();
                                        final left = root is RenderBox &&
                                            position != null &&
                                            position.dx <= root.size.width / 2;
                                        final enabled = left
                                            ? _theme(context).brightnessGesture
                                            : _theme(context).volumeGesture;
                                        if (!enabled ||
                                            (mount &&
                                                !_theme(context)
                                                    .gesturesEnabledWhileControlsVisible)) {
                                          return;
                                        }
                                        setState(() {
                                          _verticalKind = left
                                              ? MaterialVerticalGestureKind
                                                  .brightness
                                              : MaterialVerticalGestureKind
                                                  .volume;
                                          _lastVerticalKind = _verticalKind;
                                          // The indicator stays where the drag
                                          // started; following the finger made
                                          // the level readout slide out from
                                          // under it.
                                          _verticalPosition = position;
                                          _verticalDragging = true;
                                          _verticalDeltaTotal = 0.0;
                                          _verticalStartValue = left
                                              ? _brightnessValue
                                              : _volumeValue;
                                          if (left) {
                                            _volumeIndicator = false;
                                            _volumeTimer?.cancel();
                                          } else {
                                            _brightnessIndicator = false;
                                            _brightnessTimer?.cancel();
                                          }
                                        });
                                      },
                                onVerticalDragEnd: (_) => _endVerticalGesture(),
                                onVerticalDragCancel: _endVerticalGesture,
                                onVerticalDragUpdate: controlsLocked
                                    ? null
                                    : (e) {
                                        if (e.kind == PointerDeviceKind.mouse) {
                                          return;
                                        }
                                        if (!_verticalDragging) return;
                                        _verticalDeltaTotal += e.delta.dy;
                                        final sensitivity = _theme(context)
                                            .verticalGestureSensitivity;
                                        final result =
                                            resolveVerticalGestureValue(
                                          startValue: _verticalStartValue,
                                          totalDeltaDy: _verticalDeltaTotal,
                                          sensitivity: sensitivity,
                                        );
                                        if (_verticalKind ==
                                            MaterialVerticalGestureKind
                                                .brightness) {
                                          // Left side of screen swiped
                                          if ((!mount &&
                                                  _theme(context)
                                                      .brightnessGesture) ||
                                              (_theme(context)
                                                      .brightnessGesture &&
                                                  _theme(context)
                                                      .gesturesEnabledWhileControlsVisible)) {
                                            setBrightness(result);
                                          }
                                        } else {
                                          // Right side of screen swiped
                                          if ((!mount &&
                                                  _theme(context)
                                                      .volumeGesture) ||
                                              (_theme(context).volumeGesture &&
                                                  _theme(context)
                                                      .gesturesEnabledWhileControlsVisible)) {
                                            setVolume(result);
                                          }
                                        }
                                      },
                                child: Container(
                                  color: const Color(0x00000000),
                                ),
                              ),
                            ),
                          ),
                          if (mount && !controlsLocked)
                            Padding(
                              padding: _theme(context).padding ??
                                  (
                                      // Add padding in fullscreen!
                                      isFullscreen(context)
                                          ? MediaQuery.of(context).padding
                                          : EdgeInsets.zero),
                              child: Column(
                                mainAxisSize: MainAxisSize.min,
                                mainAxisAlignment: MainAxisAlignment.start,
                                crossAxisAlignment: CrossAxisAlignment.end,
                                children: [
                                  Container(
                                    height: _theme(context).buttonBarHeight,
                                    margin: _theme(context).topButtonBarMargin,
                                    child: Row(
                                      mainAxisSize: MainAxisSize.max,
                                      mainAxisAlignment:
                                          MainAxisAlignment.start,
                                      crossAxisAlignment:
                                          CrossAxisAlignment.center,
                                      children: _theme(context).topButtonBar,
                                    ),
                                  ),
                                  // Only display [primaryButtonBar] if [buffering] is false.
                                  Expanded(
                                    child: AnimatedOpacity(
                                      curve: Curves.easeInOut,
                                      opacity: buffering ? 0.0 : 1.0,
                                      duration: _theme(context)
                                          .controlsTransitionDuration,
                                      child: Center(
                                        child: Row(
                                          mainAxisSize: MainAxisSize.min,
                                          mainAxisAlignment:
                                              MainAxisAlignment.center,
                                          crossAxisAlignment:
                                              CrossAxisAlignment.center,
                                          children:
                                              _theme(context).primaryButtonBar,
                                        ),
                                      ),
                                    ),
                                  ),
                                  Stack(
                                    alignment: Alignment.bottomCenter,
                                    children: [
                                      if (_theme(context).displaySeekBar)
                                        MaterialSeekBar(
                                          delta: _seekBarDeltaValueNotifier,
                                          previewPosition:
                                              _seekBarPositionPreviewValueNotifier,
                                          onSeekStart: () {
                                            _timer?.cancel();
                                          },
                                          onSeekEnd: () {
                                            _timer = Timer(
                                              _theme(context)
                                                  .controlsHoverDuration,
                                              () {
                                                if (mounted) {
                                                  setState(() {
                                                    visible = false;
                                                  });
                                                  unshiftSubtitle();
                                                }
                                              },
                                            );
                                          },
                                        ),
                                      Container(
                                        height: _theme(context).buttonBarHeight,
                                        margin: _theme(context)
                                            .bottomButtonBarMargin,
                                        child: Row(
                                          mainAxisSize: MainAxisSize.max,
                                          mainAxisAlignment:
                                              MainAxisAlignment.start,
                                          crossAxisAlignment:
                                              CrossAxisAlignment.center,
                                          children:
                                              _theme(context).bottomButtonBar,
                                        ),
                                      ),
                                    ],
                                  ),
                                ],
                              ),
                            ),
                          if (mount &&
                              !controlsLocked &&
                              _theme(context).controlsOverlayBuilder != null)
                            Positioned.fill(
                                child: IgnorePointer(
                                    ignoring: !visible,
                                    child: _theme(context)
                                        .controlsOverlayBuilder!(context))),
                        ],
                      ),
                    ),
                    // Double-Tap Seek Seek-Bar:
                    if (!mount && !controlsLocked)
                      if (_mountSeekBackwardButton ||
                          _mountSeekForwardButton ||
                          showSwipeDuration)
                        Column(
                          children: [
                            const Spacer(),
                            Stack(
                              alignment: Alignment.bottomCenter,
                              children: [
                                if (_theme(context).displaySeekBar)
                                  MaterialSeekBar(
                                    delta: _seekBarDeltaValueNotifier,
                                    previewPosition:
                                        _seekBarPositionPreviewValueNotifier,
                                  ),
                                Container(
                                  height: _theme(context).buttonBarHeight,
                                  margin: _theme(context).bottomButtonBarMargin,
                                ),
                              ],
                            ),
                          ],
                        ),
                    // Buffering Indicator.
                    IgnorePointer(
                      child: Padding(
                        padding: _theme(context).padding ??
                            (
                                // Add padding in fullscreen!
                                isFullscreen(context)
                                    ? MediaQuery.of(context).padding
                                    : EdgeInsets.zero),
                        child: Column(
                          children: [
                            Container(
                              height: _theme(context).buttonBarHeight,
                              margin: _theme(context).topButtonBarMargin,
                            ),
                            Expanded(
                              child: Center(
                                child: TweenAnimationBuilder<double>(
                                  tween: Tween<double>(
                                    begin: 0.0,
                                    end: buffering ? 1.0 : 0.0,
                                  ),
                                  duration: _theme(context)
                                      .controlsTransitionDuration,
                                  builder: (context, value, child) {
                                    // Only mount the buffering indicator if the opacity is greater than 0.0.
                                    // This has been done to prevent redundant resource usage in [CircularProgressIndicator].
                                    if (value > 0.0) {
                                      return Opacity(
                                        opacity: value,
                                        child: _theme(context)
                                                .bufferingIndicatorBuilder
                                                ?.call(context) ??
                                            child!,
                                      );
                                    }
                                    return const SizedBox.shrink();
                                  },
                                  child: const CircularProgressIndicator(
                                    color: Color(0xFFFFFFFF),
                                  ),
                                ),
                              ),
                            ),
                            Container(
                              height: _theme(context).buttonBarHeight,
                              margin: _theme(context).bottomButtonBarMargin,
                            ),
                          ],
                        ),
                      ),
                    ),
                    if (_theme(context).verticalGestureIndicatorBuilder != null)
                      Positioned.fill(
                          child: IgnorePointer(
                              child: AnimatedOpacity(
                        opacity: !controlsLocked &&
                                (_verticalDragging ||
                                    _brightnessIndicator ||
                                    _volumeIndicator)
                            ? 1
                            : 0,
                        duration: _theme(context).controlsTransitionDuration,
                        child: _buildVerticalGestureIndicator(context),
                      ))),
                    // Volume Indicator.
                    if (_theme(context).verticalGestureIndicatorBuilder == null)
                      IgnorePointer(
                        child: AnimatedOpacity(
                          curve: Curves.easeInOut,
                          opacity: (!mount ||
                                      _theme(context)
                                          .gesturesEnabledWhileControlsVisible) &&
                                  _volumeIndicator
                              ? 1.0
                              : 0.0,
                          duration: _theme(context).controlsTransitionDuration,
                          child: _theme(context)
                                  .volumeIndicatorBuilder
                                  ?.call(context, _volumeValue) ??
                              Container(
                                alignment: Alignment.center,
                                decoration: BoxDecoration(
                                  color: const Color(0x88000000),
                                  borderRadius: BorderRadius.circular(64.0),
                                ),
                                height: 52.0,
                                width: 108.0,
                                child: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  mainAxisAlignment: MainAxisAlignment.center,
                                  crossAxisAlignment: CrossAxisAlignment.center,
                                  children: [
                                    Container(
                                      height: 52.0,
                                      width: 42.0,
                                      alignment: Alignment.centerRight,
                                      child: Icon(
                                        _volumeValue == 0.0
                                            ? Icons.volume_off
                                            : _volumeValue < 0.5
                                                ? Icons.volume_down
                                                : Icons.volume_up,
                                        color: const Color(0xFFFFFFFF),
                                        size: 24.0,
                                      ),
                                    ),
                                    const SizedBox(width: 8.0),
                                    Expanded(
                                      child: Text(
                                        '${(_volumeValue * 100.0).round()}%',
                                        textAlign: TextAlign.center,
                                        style: const TextStyle(
                                          fontSize: 14.0,
                                          color: Color(0xFFFFFFFF),
                                        ),
                                      ),
                                    ),
                                    const SizedBox(width: 16.0),
                                  ],
                                ),
                              ),
                        ),
                      ),
                    // Brightness Indicator.
                    if (_theme(context).verticalGestureIndicatorBuilder == null)
                      IgnorePointer(
                        child: AnimatedOpacity(
                          curve: Curves.easeInOut,
                          opacity: (!mount ||
                                      _theme(context)
                                          .gesturesEnabledWhileControlsVisible) &&
                                  _brightnessIndicator
                              ? 1.0
                              : 0.0,
                          duration: _theme(context).controlsTransitionDuration,
                          child: _theme(context)
                                  .brightnessIndicatorBuilder
                                  ?.call(context, _brightnessValue) ??
                              Container(
                                alignment: Alignment.center,
                                decoration: BoxDecoration(
                                  color: const Color(0x88000000),
                                  borderRadius: BorderRadius.circular(64.0),
                                ),
                                height: 52.0,
                                width: 108.0,
                                child: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  mainAxisAlignment: MainAxisAlignment.center,
                                  crossAxisAlignment: CrossAxisAlignment.center,
                                  children: [
                                    Container(
                                      height: 52.0,
                                      width: 42.0,
                                      alignment: Alignment.centerRight,
                                      child: Icon(
                                        _brightnessValue < 1.0 / 3.0
                                            ? Icons.brightness_low
                                            : _brightnessValue < 2.0 / 3.0
                                                ? Icons.brightness_medium
                                                : Icons.brightness_high,
                                        color: const Color(0xFFFFFFFF),
                                        size: 24.0,
                                      ),
                                    ),
                                    const SizedBox(width: 8.0),
                                    Expanded(
                                      child: Text(
                                        '${(_brightnessValue * 100.0).round()}%',
                                        textAlign: TextAlign.center,
                                        style: const TextStyle(
                                          fontSize: 14.0,
                                          color: Color(0xFFFFFFFF),
                                        ),
                                      ),
                                    ),
                                    const SizedBox(width: 16.0),
                                  ],
                                ),
                              ),
                        ),
                      ),
                    // Speedup Indicator.
                    IgnorePointer(
                      child: Padding(
                        padding: _theme(context).padding ??
                            (
                                // Add padding in fullscreen!
                                isFullscreen(context)
                                    ? MediaQuery.of(context).padding
                                    : EdgeInsets.zero),
                        child: Column(
                          children: [
                            Container(
                              height: _theme(context).buttonBarHeight,
                              margin: _theme(context).topButtonBarMargin,
                            ),
                            Expanded(
                              child: AnimatedOpacity(
                                duration:
                                    _theme(context).controlsTransitionDuration,
                                opacity: _speedUpIndicator ? 1 : 0,
                                child: _theme(context)
                                        .speedUpIndicatorBuilder
                                        ?.call(context,
                                            _theme(context).speedUpFactor) ??
                                    Container(
                                      alignment: Alignment.topCenter,
                                      child: Container(
                                        margin: const EdgeInsets.all(16.0),
                                        alignment: Alignment.center,
                                        decoration: BoxDecoration(
                                          color: const Color(0x88000000),
                                          borderRadius:
                                              BorderRadius.circular(64.0),
                                        ),
                                        height: 48.0,
                                        width: 108.0,
                                        child: Row(
                                          mainAxisSize: MainAxisSize.min,
                                          mainAxisAlignment:
                                              MainAxisAlignment.center,
                                          crossAxisAlignment:
                                              CrossAxisAlignment.center,
                                          children: [
                                            const SizedBox(width: 16.0),
                                            Expanded(
                                              child: Text(
                                                '${_theme(context).speedUpFactor.toStringAsFixed(1)}x',
                                                textAlign: TextAlign.center,
                                                style: const TextStyle(
                                                  fontSize: 14.0,
                                                  color: Color(0xFFFFFFFF),
                                                ),
                                              ),
                                            ),
                                            Container(
                                              height: 48.0,
                                              width: 48.0 - 16.0,
                                              alignment: Alignment.centerRight,
                                              child: const Icon(
                                                Icons.fast_forward,
                                                color: Color(0xFFFFFFFF),
                                                size: 24.0,
                                              ),
                                            ),
                                            const SizedBox(width: 16.0),
                                          ],
                                        ),
                                      ),
                                    ),
                              ),
                            ),
                            Container(
                              height: _theme(context).buttonBarHeight,
                              margin: _theme(context).bottomButtonBarMargin,
                            ),
                          ],
                        ),
                      ),
                    ),
                    // Seek Indicator.
                    IgnorePointer(
                      child: AnimatedOpacity(
                        duration: _theme(context).controlsTransitionDuration,
                        opacity: showSwipeDuration ? 1 : 0,
                        child: _theme(context).seekIndicatorBuilder?.call(
                                context, Duration(seconds: swipeDuration)) ??
                            Container(
                              alignment: Alignment.center,
                              decoration: BoxDecoration(
                                color: const Color(0x88000000),
                                borderRadius: BorderRadius.circular(64.0),
                              ),
                              height: 52.0,
                              width: 108.0,
                              child: Text(
                                swipeDuration > 0
                                    ? "+ ${Duration(seconds: swipeDuration).label()}"
                                    : "- ${Duration(seconds: swipeDuration).label()}",
                                textAlign: TextAlign.center,
                                style: const TextStyle(
                                  fontSize: 14.0,
                                  color: Color(0xFFFFFFFF),
                                ),
                              ),
                            ),
                      ),
                    ),

                    // Double-Tap Seek Button(s):
                    if (!mount || seekOnDoubleTapEnabledWhileControlsAreVisible)
                      if (_mountSeekBackwardButton || _mountSeekForwardButton)
                        Positioned.fill(
                          child: Row(
                            children: [
                              Expanded(
                                flex: _theme(context)
                                    .seekOnDoubleTapLayoutWidgetRatios[0],
                                child: _mountSeekBackwardButton
                                    ? AnimatedOpacity(
                                        opacity:
                                            _hideSeekBackwardButton ? 0 : 1.0,
                                        duration:
                                            const Duration(milliseconds: 200),
                                        child: _BackwardSeekIndicator(
                                          duration: _theme(context)
                                              .seekOnDoubleTapBackwardDuration,
                                          onChanged: (value) {
                                            _seekBarDeltaValueNotifier.value =
                                                -value;
                                          },
                                          onSubmitted: (value) {
                                            _timerSeekBackwardButton?.cancel();
                                            final previewGeneration =
                                                ++_seekPreviewGeneration;
                                            _timerSeekBackwardButton = Timer(
                                              const Duration(milliseconds: 200),
                                              () {
                                                setState(() {
                                                  _hideSeekBackwardButton =
                                                      false;
                                                  _mountSeekBackwardButton =
                                                      false;
                                                  if (_seekPreviewGeneration ==
                                                      previewGeneration) {
                                                    _seekBarDeltaValueNotifier
                                                        .value = Duration.zero;
                                                  }
                                                });
                                              },
                                            );

                                            setState(() {
                                              _hideSeekBackwardButton = true;
                                            });
                                            var result = controller(context)
                                                    .player
                                                    .state
                                                    .position -
                                                value;
                                            result = result.clamp(
                                              Duration.zero,
                                              controller(context)
                                                  .player
                                                  .state
                                                  .duration,
                                            );
                                            controller(context)
                                                .player
                                                .seek(result);
                                          },
                                        ),
                                      )
                                    : const SizedBox(),
                              ),
                              //Area in the middle where the double-tap seek buttons are ignored in
                              if (_theme(context)
                                      .seekOnDoubleTapLayoutWidgetRatios[1] >
                                  0)
                                Spacer(
                                  flex: _theme(context)
                                      .seekOnDoubleTapLayoutWidgetRatios[1],
                                ),
                              Expanded(
                                flex: _theme(context)
                                    .seekOnDoubleTapLayoutWidgetRatios[2],
                                child: _mountSeekForwardButton
                                    ? AnimatedOpacity(
                                        opacity:
                                            _hideSeekForwardButton ? 0 : 1.0,
                                        duration:
                                            const Duration(milliseconds: 200),
                                        child: _ForwardSeekIndicator(
                                          duration: _theme(context)
                                              .seekOnDoubleTapForwardDuration,
                                          onChanged: (value) {
                                            _seekBarDeltaValueNotifier.value =
                                                value;
                                          },
                                          onSubmitted: (value) {
                                            _timerSeekForwardButton?.cancel();
                                            final previewGeneration =
                                                ++_seekPreviewGeneration;
                                            _timerSeekForwardButton = Timer(
                                                const Duration(
                                                    milliseconds: 200), () {
                                              if (_hideSeekForwardButton) {
                                                setState(() {
                                                  _hideSeekForwardButton =
                                                      false;
                                                  _mountSeekForwardButton =
                                                      false;
                                                  if (_seekPreviewGeneration ==
                                                      previewGeneration) {
                                                    _seekBarDeltaValueNotifier
                                                        .value = Duration.zero;
                                                  }
                                                });
                                              }
                                            });
                                            setState(() {
                                              _hideSeekForwardButton = true;
                                            });

                                            var result = controller(context)
                                                    .player
                                                    .state
                                                    .position +
                                                value;
                                            result = result.clamp(
                                              Duration.zero,
                                              controller(context)
                                                  .player
                                                  .state
                                                  .duration,
                                            );
                                            controller(context)
                                                .player
                                                .seek(result);
                                          },
                                        ),
                                      )
                                    : const SizedBox(),
                              ),
                            ],
                          ),
                        ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  double widgetWidth(BuildContext context) =>
      (context.findRenderObject() as RenderBox).paintBounds.width;
}

// SEEK BAR

/// Material design seek bar.
class MaterialSeekBar extends StatefulWidget {
  final ValueNotifier<Duration>? delta;
  final ValueNotifier<Duration?>? previewPosition;
  final VoidCallback? onSeekStart;
  final VoidCallback? onSeekEnd;

  const MaterialSeekBar({
    super.key,
    this.delta,
    this.previewPosition,
    this.onSeekStart,
    this.onSeekEnd,
  });

  @override
  MaterialSeekBarState createState() => MaterialSeekBarState();
}

class MaterialSeekBarState extends State<MaterialSeekBar> {
  bool tapped = false;
  double slider = 0.0;

  late bool playing = controller(context).player.state.playing;
  late Duration position = controller(context).player.state.position;
  late Duration duration = controller(context).player.state.duration;
  late Duration buffer = controller(context).player.state.buffer;

  final List<StreamSubscription> subscriptions = [];

  @override
  void setState(VoidCallback fn) {
    if (mounted) {
      super.setState(fn);
    }
  }

  void listener() {
    setState(() {
      position = _presentedPosition(controller(context).player.state.position);
    });
  }

  Duration _presentedPosition(Duration base) {
    final absolutePreview = widget.previewPosition?.value;
    if (absolutePreview != null) {
      if (absolutePreview < Duration.zero) return Duration.zero;
      if (duration > Duration.zero && absolutePreview > duration) {
        return duration;
      }
      return absolutePreview;
    }
    return _previewPosition(base);
  }

  Duration _previewPosition(Duration base) {
    final candidate = base + (widget.delta?.value ?? Duration.zero);
    if (candidate < Duration.zero) return Duration.zero;
    if (duration > Duration.zero && candidate > duration) return duration;
    return candidate;
  }

  @override
  void initState() {
    super.initState();
    widget.delta?.addListener(listener);
    widget.previewPosition?.addListener(listener);
  }

  @override
  void didUpdateWidget(covariant MaterialSeekBar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.delta != widget.delta) {
      oldWidget.delta?.removeListener(listener);
      widget.delta?.addListener(listener);
      listener();
    }
    if (oldWidget.previewPosition != widget.previewPosition) {
      oldWidget.previewPosition?.removeListener(listener);
      widget.previewPosition?.addListener(listener);
      listener();
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (subscriptions.isEmpty) {
      subscriptions.addAll(
        [
          controller(context).player.stream.playing.listen((event) {
            setState(() {
              playing = event;
            });
          }),
          controller(context).player.stream.completed.listen((event) {
            setState(() {
              position = _presentedPosition(Duration.zero);
            });
          }),
          controller(context).player.stream.position.listen((event) {
            setState(() {
              if (!tapped) {
                position = _presentedPosition(event);
              }
            });
          }),
          controller(context).player.stream.duration.listen((event) {
            setState(() {
              duration = event;
              position = _presentedPosition(
                controller(context).player.state.position,
              );
            });
          }),
          controller(context).player.stream.buffer.listen((event) {
            setState(() {
              buffer = event;
            });
          }),
        ],
      );
    }
  }

  @override
  void dispose() {
    widget.delta?.removeListener(listener);
    widget.previewPosition?.removeListener(listener);
    for (final subscription in subscriptions) {
      subscription.cancel();
    }
    super.dispose();
  }

  void onPointerMove(PointerMoveEvent e, BoxConstraints constraints) {
    final percent = e.localPosition.dx / constraints.maxWidth;
    setState(() {
      tapped = true;
      slider = percent.clamp(0.0, 1.0);
    });
    controller(context).player.seek(duration * slider);
  }

  void onPointerDown() {
    widget.onSeekStart?.call();
    setState(() {
      tapped = true;
    });
  }

  Future<void> onPointerUp() async {
    final target = duration * slider;
    final player = controller(context).player;
    setState(() {
      position = target;
    });
    final applied = Completer<void>();
    void accept(Duration current) {
      if ((current - target).abs() <= const Duration(milliseconds: 750) &&
          !applied.isCompleted) {
        applied.complete();
      }
    }

    final subscription = player.stream.position.listen(accept);
    try {
      await player.seek(target);
      accept(player.state.position);
      await applied.future.timeout(
        const Duration(seconds: 4),
        onTimeout: () {},
      );
    } catch (_) {
      // The player surfaces seek failures separately; always restore live UI.
    } finally {
      await subscription.cancel();
      setState(() {
        // Keep ignoring stale position events until the final seek is accepted.
        tapped = false;
        position = target;
      });
      widget.onSeekEnd?.call();
    }
  }

  void onPanStart(DragStartDetails e, BoxConstraints constraints) {
    final percent = e.localPosition.dx / constraints.maxWidth;
    setState(() {
      tapped = true;
      slider = percent.clamp(0.0, 1.0);
    });
  }

  void onPanDown(DragDownDetails e, BoxConstraints constraints) {
    final percent = e.localPosition.dx / constraints.maxWidth;
    setState(() {
      tapped = true;
      slider = percent.clamp(0.0, 1.0);
    });
  }

  void onPanUpdate(DragUpdateDetails e, BoxConstraints constraints) {
    final percent = e.localPosition.dx / constraints.maxWidth;
    setState(() {
      tapped = true;
      slider = percent.clamp(0.0, 1.0);
    });
  }

  /// Returns the current playback position in percentage.
  double get positionPercent {
    if (position == Duration.zero || duration == Duration.zero) {
      return 0.0;
    } else {
      final value = position.inMilliseconds / duration.inMilliseconds;
      return value.clamp(0.0, 1.0);
    }
  }

  /// Returns the current playback buffer position in percentage.
  double get bufferPercent {
    if (buffer == Duration.zero || duration == Duration.zero) {
      return 0.0;
    } else {
      final value = buffer.inMilliseconds / duration.inMilliseconds;
      return value.clamp(0.0, 1.0);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      clipBehavior: Clip.none,
      margin: _theme(context).seekBarMargin,
      child: LayoutBuilder(
        builder: (context, constraints) => MouseRegion(
          cursor: SystemMouseCursors.click,
          child: GestureDetector(
            onHorizontalDragUpdate: (_) {},
            onPanStart: (e) => onPanStart(e, constraints),
            onPanDown: (e) => onPanDown(e, constraints),
            onPanUpdate: (e) => onPanUpdate(e, constraints),
            child: Listener(
              onPointerMove: (e) => onPointerMove(e, constraints),
              onPointerDown: (e) => onPointerDown(),
              onPointerUp: (e) => unawaited(onPointerUp()),
              child: Container(
                color: Colors.transparent,
                width: constraints.maxWidth,
                alignment: _theme(context).seekBarAlignment,
                height: _theme(context).seekBarContainerHeight,
                child: Stack(
                  clipBehavior: Clip.none,
                  alignment: Alignment.bottomCenter,
                  children: [
                    Container(
                      width: constraints.maxWidth,
                      height: _theme(context).seekBarHeight,
                      alignment: Alignment.bottomLeft,
                      color: _theme(context).seekBarColor,
                      child: Stack(
                        clipBehavior: Clip.none,
                        alignment: Alignment.bottomLeft,
                        children: [
                          Container(
                            width: constraints.maxWidth * bufferPercent,
                            color: _theme(context).seekBarBufferColor,
                          ),
                          Container(
                            width: tapped
                                ? constraints.maxWidth * slider
                                : constraints.maxWidth * positionPercent,
                            color: _theme(context).seekBarPositionColor,
                          ),
                        ],
                      ),
                    ),
                    Positioned(
                      left: tapped
                          ? (constraints.maxWidth -
                                  _theme(context).seekBarThumbSize / 2) *
                              slider
                          : (constraints.maxWidth -
                                  _theme(context).seekBarThumbSize / 2) *
                              positionPercent,
                      bottom: -1.0 * _theme(context).seekBarThumbSize / 2 +
                          _theme(context).seekBarHeight / 2,
                      child: Container(
                        width: _theme(context).seekBarThumbSize,
                        height: _theme(context).seekBarThumbSize,
                        decoration: BoxDecoration(
                          color: _theme(context).seekBarThumbColor,
                          borderRadius: BorderRadius.circular(
                            _theme(context).seekBarThumbSize / 2,
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

// BUTTON: PLAY/PAUSE

/// A material design play/pause button.
class MaterialPlayOrPauseButton extends StatefulWidget {
  /// Overriden icon size for [MaterialSkipPreviousButton].
  final double? iconSize;

  /// Overriden icon color for [MaterialSkipPreviousButton].
  final Color? iconColor;

  const MaterialPlayOrPauseButton({
    super.key,
    this.iconSize,
    this.iconColor,
  });

  @override
  MaterialPlayOrPauseButtonState createState() =>
      MaterialPlayOrPauseButtonState();
}

class MaterialPlayOrPauseButtonState extends State<MaterialPlayOrPauseButton>
    with SingleTickerProviderStateMixin {
  late final animation = AnimationController(
    vsync: this,
    value: controller(context).player.state.playing ? 1 : 0,
    duration: const Duration(milliseconds: 200),
  );

  StreamSubscription<bool>? subscription;

  @override
  void setState(VoidCallback fn) {
    if (mounted) {
      super.setState(fn);
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    subscription ??= controller(context).player.stream.playing.listen((event) {
      if (event) {
        animation.forward();
      } else {
        animation.reverse();
      }
    });
  }

  @override
  void dispose() {
    animation.dispose();
    subscription?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return IconButton(
      onPressed: controller(context).player.playOrPause,
      iconSize: widget.iconSize ?? _theme(context).buttonBarButtonSize,
      color: widget.iconColor ?? _theme(context).buttonBarButtonColor,
      icon: IgnorePointer(
        child: AnimatedIcon(
          progress: animation,
          icon: AnimatedIcons.play_pause,
          size: widget.iconSize ?? _theme(context).buttonBarButtonSize,
          color: widget.iconColor ?? _theme(context).buttonBarButtonColor,
        ),
      ),
    );
  }
}

// BUTTON: SKIP NEXT

/// Material design skip next button.
class MaterialSkipNextButton extends StatelessWidget {
  /// Icon for [MaterialSkipNextButton].
  final Widget? icon;

  /// Overriden icon size for [MaterialSkipNextButton].
  final double? iconSize;

  /// Overriden icon color for [MaterialSkipNextButton].
  final Color? iconColor;

  const MaterialSkipNextButton({
    super.key,
    this.icon,
    this.iconSize,
    this.iconColor,
  });

  @override
  Widget build(BuildContext context) {
    if (!_theme(context).automaticallyImplySkipNextButton ||
        (controller(context).player.state.playlist.medias.length > 1 &&
            _theme(context).automaticallyImplySkipNextButton)) {
      return IconButton(
        onPressed: controller(context).player.next,
        icon: icon ?? const Icon(Icons.skip_next),
        iconSize: iconSize ?? _theme(context).buttonBarButtonSize,
        color: iconColor ?? _theme(context).buttonBarButtonColor,
      );
    }
    return const SizedBox.shrink();
  }
}

// BUTTON: SKIP PREVIOUS

/// Material design skip previous button.
class MaterialSkipPreviousButton extends StatelessWidget {
  /// Icon for [MaterialSkipPreviousButton].
  final Widget? icon;

  /// Overriden icon size for [MaterialSkipPreviousButton].
  final double? iconSize;

  /// Overriden icon color for [MaterialSkipPreviousButton].
  final Color? iconColor;

  const MaterialSkipPreviousButton({
    super.key,
    this.icon,
    this.iconSize,
    this.iconColor,
  });

  @override
  Widget build(BuildContext context) {
    if (!_theme(context).automaticallyImplySkipPreviousButton ||
        (controller(context).player.state.playlist.medias.length > 1 &&
            _theme(context).automaticallyImplySkipPreviousButton)) {
      return IconButton(
        onPressed: controller(context).player.previous,
        icon: icon ?? const Icon(Icons.skip_previous),
        iconSize: iconSize ?? _theme(context).buttonBarButtonSize,
        color: iconColor ?? _theme(context).buttonBarButtonColor,
      );
    }
    return const SizedBox.shrink();
  }
}

// BUTTON: FULL SCREEN

/// Material design fullscreen button.
class MaterialFullscreenButton extends StatelessWidget {
  /// Icon for [MaterialFullscreenButton].
  final Widget? icon;

  /// Overriden icon size for [MaterialFullscreenButton].
  final double? iconSize;

  /// Overriden icon color for [MaterialFullscreenButton].
  final Color? iconColor;

  const MaterialFullscreenButton({
    super.key,
    this.icon,
    this.iconSize,
    this.iconColor,
  });

  @override
  Widget build(BuildContext context) {
    return IconButton(
      onPressed: () => toggleFullscreen(context),
      icon: icon ??
          (isFullscreen(context)
              ? const Icon(Icons.fullscreen_exit)
              : const Icon(Icons.fullscreen)),
      iconSize: iconSize ?? _theme(context).buttonBarButtonSize,
      color: iconColor ?? _theme(context).buttonBarButtonColor,
    );
  }
}

// BUTTON: CUSTOM

/// Material design custom button.
class MaterialCustomButton extends StatelessWidget {
  /// Icon for [MaterialCustomButton].
  final Widget? icon;

  /// Icon size for [MaterialCustomButton].
  final double? iconSize;

  /// Icon color for [MaterialCustomButton].
  final Color? iconColor;

  /// The callback that is called when the button is tapped or otherwise activated.
  final VoidCallback onPressed;

  const MaterialCustomButton({
    super.key,
    this.icon,
    this.iconSize,
    this.iconColor,
    required this.onPressed,
  });

  @override
  Widget build(BuildContext context) {
    return IconButton(
      onPressed: onPressed,
      style: IconButton.styleFrom(shape: const StadiumBorder()),
      icon: icon ?? const Icon(Icons.settings),
      padding: EdgeInsets.zero,
      iconSize: iconSize ?? _theme(context).buttonBarButtonSize,
      color: iconColor ?? _theme(context).buttonBarButtonColor,
    );
  }
}

// POSITION INDICATOR

/// Material design position indicator.
class MaterialPositionIndicator extends StatefulWidget {
  /// Overriden [TextStyle] for the [MaterialPositionIndicator].
  final TextStyle? style;
  const MaterialPositionIndicator({super.key, this.style});

  @override
  MaterialPositionIndicatorState createState() =>
      MaterialPositionIndicatorState();
}

class MaterialPositionIndicatorState extends State<MaterialPositionIndicator> {
  late Duration position = controller(context).player.state.position;
  late Duration duration = controller(context).player.state.duration;

  final List<StreamSubscription> subscriptions = [];

  @override
  void setState(VoidCallback fn) {
    if (mounted) {
      super.setState(fn);
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (subscriptions.isEmpty) {
      subscriptions.addAll(
        [
          controller(context).player.stream.position.listen((event) {
            setState(() {
              position = event;
            });
          }),
          controller(context).player.stream.duration.listen((event) {
            setState(() {
              duration = event;
            });
          }),
        ],
      );
    }
  }

  @override
  void dispose() {
    for (final subscription in subscriptions) {
      subscription.cancel();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Text(
      '${position.label(reference: duration)} / ${duration.label(reference: duration)}',
      style: widget.style ??
          TextStyle(
            height: 1.0,
            fontSize: 12.0,
            color: _theme(context).buttonBarButtonColor,
          ),
    );
  }
}

class _BackwardSeekIndicator extends StatefulWidget {
  final Duration duration;
  final void Function(Duration) onChanged;
  final void Function(Duration) onSubmitted;
  const _BackwardSeekIndicator({
    required this.duration,
    required this.onChanged,
    required this.onSubmitted,
  });

  @override
  State<_BackwardSeekIndicator> createState() => _BackwardSeekIndicatorState();
}

class _BackwardSeekIndicatorState extends State<_BackwardSeekIndicator> {
  late Duration value = widget.duration;

  Timer? timer;

  @override
  void setState(VoidCallback fn) {
    if (mounted) {
      super.setState(fn);
    }
  }

  @override
  void initState() {
    super.initState();
    timer = Timer(const Duration(milliseconds: 400), () {
      widget.onSubmitted.call(value);
    });
  }

  void increment() {
    timer?.cancel();
    timer = Timer(const Duration(milliseconds: 400), () {
      widget.onSubmitted.call(value);
    });
    widget.onChanged.call(value);
    setState(() {
      value += const Duration(seconds: 10);
    });
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          colors: [
            Color(0x88767676),
            Color(0x00767676),
          ],
          begin: Alignment.centerLeft,
          end: Alignment.centerRight,
        ),
      ),
      child: InkWell(
        splashColor: const Color(0x44767676),
        onTap: increment,
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              const Icon(
                Icons.fast_rewind,
                size: 24.0,
                color: Color(0xFFFFFFFF),
              ),
              const SizedBox(height: 8.0),
              Text(
                '${value.inSeconds} seconds',
                style: const TextStyle(
                  fontSize: 12.0,
                  color: Color(0xFFFFFFFF),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ForwardSeekIndicator extends StatefulWidget {
  final Duration duration;
  final void Function(Duration) onChanged;
  final void Function(Duration) onSubmitted;
  const _ForwardSeekIndicator({
    required this.duration,
    required this.onChanged,
    required this.onSubmitted,
  });

  @override
  State<_ForwardSeekIndicator> createState() => _ForwardSeekIndicatorState();
}

class _ForwardSeekIndicatorState extends State<_ForwardSeekIndicator> {
  late Duration value = widget.duration;

  Timer? timer;

  @override
  void setState(VoidCallback fn) {
    if (mounted) {
      super.setState(fn);
    }
  }

  @override
  void initState() {
    super.initState();
    timer = Timer(const Duration(milliseconds: 400), () {
      widget.onSubmitted.call(value);
    });
  }

  void increment() {
    timer?.cancel();
    timer = Timer(const Duration(milliseconds: 400), () {
      widget.onSubmitted.call(value);
    });
    widget.onChanged.call(value);
    setState(() {
      value += const Duration(seconds: 10);
    });
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          colors: [
            Color(0x00767676),
            Color(0x88767676),
          ],
          begin: Alignment.centerLeft,
          end: Alignment.centerRight,
        ),
      ),
      child: InkWell(
        splashColor: const Color(0x44767676),
        onTap: increment,
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              const Icon(
                Icons.fast_forward,
                size: 24.0,
                color: Color(0xFFFFFFFF),
              ),
              const SizedBox(height: 8.0),
              Text(
                '${value.inSeconds} seconds',
                style: const TextStyle(
                  fontSize: 12.0,
                  color: Color(0xFFFFFFFF),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
