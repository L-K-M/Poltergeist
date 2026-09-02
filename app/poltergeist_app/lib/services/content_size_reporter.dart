import 'package:flutter/material.dart';

typedef ContentSizeScheduler = void Function(VoidCallback callback);

void _scheduleAfterFrame(VoidCallback callback) {
  WidgetsBinding.instance.addPostFrameCallback((_) => callback());
}

final class ContentSizeReporter extends StatefulWidget {
  const ContentSizeReporter({
    required this.child,
    required this.onSize,
    this.scheduleAfterFrame = _scheduleAfterFrame,
    super.key,
  });

  final Widget child;
  final ValueChanged<Size> onSize;
  final ContentSizeScheduler scheduleAfterFrame;

  @override
  State<ContentSizeReporter> createState() => _ContentSizeReporterState();
}

final class _ContentSizeReporterState extends State<ContentSizeReporter> {
  Size? _lastReportedSize;
  Size? _pendingSize;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        if (constraints.hasBoundedWidth && constraints.hasBoundedHeight) {
          final size = Size(constraints.maxWidth, constraints.maxHeight);
          _scheduleReport(size);
        }

        return widget.child;
      },
    );
  }

  void _scheduleReport(Size size) {
    if (size == _pendingSize) return;
    if (size == _lastReportedSize && _pendingSize == null) return;

    // Supersede transient constraints so only the settled size is reported.
    _pendingSize = size;
    widget.scheduleAfterFrame(() {
      if (!mounted || _pendingSize != size) return;

      _pendingSize = null;
      if (size == _lastReportedSize) return;

      _lastReportedSize = size;
      widget.onSize(size);
    });
  }
}
