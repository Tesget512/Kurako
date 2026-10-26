import 'package:flutter/foundation.dart';
import 'package:media_kit_video/media_kit_video.dart';

/// mpv performs codec/profile/driver probing when opening each video.
/// These are platform candidates, not a claim that every GPU supports them.
Map<String, String> decoderChoices(TargetPlatform platform) => {
  'auto': '自动选择（推荐）',
  'sw': '软件解码（FFmpeg）',
  if (platform == TargetPlatform.macOS || platform == TargetPlatform.iOS) ...{
    'videotoolbox': 'VideoToolbox',
    'videotoolbox-copy': 'VideoToolbox（复制回传）',
  },
  if (platform == TargetPlatform.windows) ...{
    'd3d11va': 'D3D11VA',
    'd3d11va-copy': 'D3D11VA（复制回传）',
    'dxva2-copy': 'DXVA2（复制回传）',
    'nvdec-copy': 'NVIDIA NVDEC（复制回传）',
  },
  if (platform == TargetPlatform.linux) ...{
    'vaapi-copy': 'VA-API（复制回传）',
    'nvdec-copy': 'NVIDIA NVDEC（复制回传）',
    'vdpau-copy': 'VDPAU（复制回传）',
  },
  if (platform == TargetPlatform.android) ...{
    'mediacodec': 'MediaCodec',
    'mediacodec-copy': 'MediaCodec（复制回传）',
  },
};

bool validDecoderPreference(Object value) =>
    value is String &&
    (value == 'hw' ||
        TargetPlatform.values.any((p) => decoderChoices(p).containsKey(value)));

String effectiveDecoder(String value, TargetPlatform platform) =>
    decoderChoices(platform).containsKey(value) ? value : 'auto';

VideoControllerConfiguration decoderConfiguration(
  String value,
  TargetPlatform platform,
) {
  final selected = effectiveDecoder(value, platform);
  final linux = platform == TargetPlatform.linux;
  return VideoControllerConfiguration(
    enableHardwareAcceleration: !linux && selected != 'sw',
    hwdec: selected == 'sw'
        ? 'no'
        : selected != 'auto'
        ? selected
        : linux
        ? 'auto-copy'
        // Preserve media_kit's Android emulator detection for automatic mode.
        : platform == TargetPlatform.android
        ? null
        : 'auto-safe',
  );
}
