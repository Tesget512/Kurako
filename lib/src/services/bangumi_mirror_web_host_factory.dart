import 'package:flutter/foundation.dart';

import 'bangumi_mirror_web_host.dart';
import 'flutter_inappwebview_mirror_host.dart';
import 'linux_mirror_web_host.dart';

MirrorWebHostFactory defaultBangumiMirrorWebHostFactory() {
  if (defaultTargetPlatform == TargetPlatform.linux) {
    return LinuxMirrorWebHost.create;
  }
  return FlutterInAppWebViewMirrorHost.create;
}
