import 'package:flutter/widgets.dart';

/// Shared visual mark used for the app launcher and in-app icon slots.
class BrandIcon extends StatelessWidget {
  const BrandIcon({this.size = 20, this.opacity = 1, super.key});

  static const assetPath = 'assets/icon.png';

  final double size;
  final double opacity;

  @override
  Widget build(BuildContext context) {
    final image = Image.asset(
      assetPath,
      width: size,
      height: size,
      fit: BoxFit.contain,
      filterQuality: FilterQuality.high,
      excludeFromSemantics: true,
    );
    return opacity == 1 ? image : Opacity(opacity: opacity, child: image);
  }
}
