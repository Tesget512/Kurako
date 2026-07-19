import 'package:flutter/material.dart';

import 'pages/home_page.dart';

class AnimeBdApp extends StatelessWidget {
  const AnimeBdApp({super.key});

  ThemeData _theme(Brightness brightness) {
    const seed = Color(0xFF6750A4);
    return ThemeData(
      useMaterial3: true,
      colorScheme: ColorScheme.fromSeed(seedColor: seed, brightness: brightness),
      // Bundled LXGW WenKai Screen: consistent, screen-tuned CJK rendering
      // instead of the system fallback chain.
      fontFamily: 'LXGWWenKaiGBScreen',
      fontFamilyFallback: const ['Microsoft YaHei UI', 'Segoe UI'],
    );
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: '动画仓库',
      debugShowCheckedModeBanner: false,
      theme: _theme(Brightness.light),
      darkTheme: _theme(Brightness.dark),
      themeMode: ThemeMode.system,
      home: const HomePage(),
    );
  }
}
