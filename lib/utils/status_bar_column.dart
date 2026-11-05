import 'dart:io' show Platform;

import 'package:flutter/widgets.dart';

/// iPhone Duo's inner display keeps the status bar in a column on the right edge, which
/// iOS reports as a right inset with no matching left one.
abstract final class StatusBarColumn {
  /// Window sizes the column was seen at. Hiding the status bar (the video page can) may
  /// take the inset away while the window, and so the layout for it, stays the same.
  static final Set<Size> _sizes = {};

  static bool atEnd(EdgeInsets viewPadding, Size size) {
    if (!Platform.isIOS) return false;
    if (viewPadding.right > viewPadding.left + 20) {
      _sizes.add(size);
      return true;
    }
    return _sizes.contains(size);
  }
}
