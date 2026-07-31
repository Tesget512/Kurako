import 'package:flutter/material.dart';

/// Horizontal page inset shared by phone, tablet, and desktop layouts.
double adaptiveContentInset(BuildContext context) {
  final width = MediaQuery.sizeOf(context).width;
  if (width >= 1200) return 32;
  if (width >= 600) return 24;
  return 16;
}
