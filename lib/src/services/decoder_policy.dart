import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:media_kit_video/media_kit_video.dart';

/// mpv performs codec/profile/driver probing when opening each video.
/// These are platform candidates, not a claim that every GPU supports them.
Map<String, String> decoderChoices(TargetPlatform platform) => {
  'auto': '自动选择（推荐）',
  'auto-safe': '自动（安全白名单）',
  'auto-copy': '自动（复制回传）',
  'sw': '软件解码（FFmpeg）',
  if (platform == TargetPlatform.macOS || platform == TargetPlatform.iOS) ...{
    'videotoolbox': 'VideoToolbox',
    'videotoolbox-copy': 'VideoToolbox（复制回传）',
  },
  if (platform == TargetPlatform.windows) ...{
    'd3d11va': 'D3D11VA',
    'd3d11va-copy': 'D3D11VA（复制回传）',
    'dxva2': 'DXVA2',
    'dxva2-copy': 'DXVA2（复制回传）',
    'nvdec': 'NVIDIA NVDEC',
    'nvdec-copy': 'NVIDIA NVDEC（复制回传）',
    'cuda': 'NVIDIA CUDA',
    'cuda-copy': 'NVIDIA CUDA（复制回传）',
  },
  if (platform == TargetPlatform.linux) ...{
    'vaapi': 'VA-API',
    'vaapi-copy': 'VA-API（复制回传）',
    'nvdec': 'NVIDIA NVDEC',
    'nvdec-copy': 'NVIDIA NVDEC（复制回传）',
    'vdpau': 'VDPAU',
    'vdpau-copy': 'VDPAU（复制回传）',
    'drm': 'DRM',
    'drm-copy': 'DRM（复制回传）',
  },
  if (platform == TargetPlatform.android) ...{
    'mediacodec': 'MediaCodec',
    'mediacodec-copy': 'MediaCodec（复制回传）',
  },
};

const _vendorDecoderEntries = <String, String>{
  'nvdec': 'NVIDIA NVDEC',
  'nvdec-copy': 'NVIDIA NVDEC（复制回传）',
  'cuda': 'NVIDIA CUDA',
  'cuda-copy': 'NVIDIA CUDA（复制回传）',
  'vdpau': 'VDPAU',
  'vdpau-copy': 'VDPAU（复制回传）',
};

String? normalizeRuntimeDecoder(String? value) {
  final normalized = value?.trim().toLowerCase();
  if (normalized == null || normalized.isEmpty) return null;
  final first = normalized.split(',').first.trim();
  return first.isEmpty ? null : first;
}

/// Static choices are the complete platform vocabulary used for validation.
/// The UI uses [availableDecoderChoices] so vendor-only backends do not appear
/// on machines where mpv has never selected them.
Map<String, String> availableDecoderChoices(
  TargetPlatform platform, {
  required String? runtimeHwdec,
}) {
  final runtime = normalizeRuntimeDecoder(runtimeHwdec);
  final runtimeFamily = switch (runtime) {
    final value? when value.startsWith('nvdec') => 'nvidia',
    final value? when value.startsWith('cuda') => 'nvidia',
    final value? when value.startsWith('vdpau') => 'vdpau',
    _ => null,
  };
  final result = <String, String>{
    for (final entry in decoderChoices(platform).entries)
      if (!_vendorDecoderEntries.containsKey(entry.key)) entry.key: entry.value,
  };
  if (runtimeFamily == 'nvidia') {
    for (final entry in const {
      'nvdec': 'NVIDIA NVDEC',
      'nvdec-copy': 'NVIDIA NVDEC（复制回传）',
      'cuda': 'NVIDIA CUDA',
      'cuda-copy': 'NVIDIA CUDA（复制回传）',
    }.entries) {
      if (decoderChoices(platform).containsKey(entry.key)) {
        result[entry.key] = entry.value;
      }
    }
    if (platform == TargetPlatform.linux) {
      result.remove('vaapi');
      result.remove('vaapi-copy');
      result.remove('drm');
      result.remove('drm-copy');
    }
  } else if (runtimeFamily == 'vdpau' &&
      decoderChoices(platform).containsKey('vdpau')) {
    result['vdpau'] = 'VDPAU';
    result['vdpau-copy'] = 'VDPAU（复制回传）';
    result.remove('vaapi');
    result.remove('vaapi-copy');
  }
  return result;
}

const decoderRuntimeNames = <String, String>{
  'videotoolbox': 'VideoToolbox',
  'videotoolbox-copy': 'VideoToolbox（复制回传）',
  'd3d11va': 'D3D11VA',
  'd3d11va-copy': 'D3D11VA（复制回传）',
  'dxva2': 'DXVA2',
  'dxva2-copy': 'DXVA2（复制回传）',
  'nvdec': 'NVIDIA NVDEC',
  'nvdec-copy': 'NVIDIA NVDEC（复制回传）',
  'cuda': 'NVIDIA CUDA',
  'cuda-copy': 'NVIDIA CUDA（复制回传）',
  'vaapi': 'VA-API',
  'vaapi-copy': 'VA-API（复制回传）',
  'vdpau': 'VDPAU',
  'vdpau-copy': 'VDPAU（复制回传）',
  'drm': 'DRM',
  'drm-copy': 'DRM（复制回传）',
  'mediacodec': 'MediaCodec',
  'mediacodec-copy': 'MediaCodec（复制回传）',
};

bool isAutomaticDecoder(String value) =>
    value == 'auto' || value == 'auto-safe' || value == 'auto-copy';

String? decoderRuntimeLabel(String? value) {
  final normalized = value?.trim();
  if (normalized == null || normalized.isEmpty) return null;
  if (normalized == 'no') return '软件解码';
  return decoderRuntimeNames[normalized] ?? normalized;
}

String decoderSelectionSummary(
  String value,
  TargetPlatform platform, {
  required String? runtimeHwdec,
}) {
  final selected = effectiveDecoder(value, platform);
  if (selected == 'sw') return '软件解码（FFmpeg）';
  if (!isAutomaticDecoder(selected)) {
    return decoderChoices(platform)[selected] ?? selected;
  }
  final runtime = decoderRuntimeLabel(runtimeHwdec);
  return runtime == null ? '自动：尚未播放视频' : '自动：「$runtime」';
}

String decoderPlatformLabel(TargetPlatform platform) => switch (platform) {
  TargetPlatform.macOS => 'macOS',
  TargetPlatform.iOS => 'iOS / iPadOS',
  TargetPlatform.windows => 'Windows',
  TargetPlatform.linux => 'Linux',
  TargetPlatform.android => 'Android',
  TargetPlatform.fuchsia => 'Fuchsia',
};

TargetPlatform currentDecoderPlatform() {
  if (Platform.isAndroid) return TargetPlatform.android;
  if (Platform.isIOS) return TargetPlatform.iOS;
  if (Platform.isMacOS) return TargetPlatform.macOS;
  if (Platform.isWindows) return TargetPlatform.windows;
  if (Platform.isLinux) return TargetPlatform.linux;
  return TargetPlatform.fuchsia;
}

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
  final requiresCopyOutput = linux && selected != 'drm';
  final hwdec = switch (selected) {
    'sw' => 'no',
    'auto' =>
      requiresCopyOutput
          ? 'auto-copy'
          : platform == TargetPlatform.android
          ? null
          : 'auto-safe',
    'auto-safe' => requiresCopyOutput ? 'auto-copy' : 'auto-safe',
    'auto-copy' => 'auto-copy',
    _ =>
      linux && !selected.endsWith('-copy') && selected != 'drm'
          ? '$selected-copy'
          : selected,
  };
  return VideoControllerConfiguration(
    enableHardwareAcceleration: !linux && selected != 'sw',
    // Preserve media_kit's Android emulator detection for automatic mode.
    hwdec: hwdec,
  );
}
