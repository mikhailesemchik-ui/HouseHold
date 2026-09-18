import 'package:flutter/material.dart';

// Warm cream ground — the base tone behind everything, matched to read as
// luminous/soft rather than gray or muddy.
const _kBackgroundBase = Color(0xFFF7F4EC);

// Soft sage green, used only as a low-alpha radial falloff (never painted at
// full opacity) so the two corner blobs stay atmospheric, not mint-heavy.
const _kBackgroundBlob = Color(0xFFBFDCC0);

/// The app's single ambient background: a warm cream base with two soft,
/// static sage-green blobs in the top-left and bottom-right corners.
///
/// Wired exactly once, at the shell root (see `app_router.dart`) — never
/// per-screen. Deliberately static (no animation) and built from plain
/// gradient decorations rather than `BackdropFilter`/`ImageFilter.blur`: the
/// soft edge comes from the gradient's own alpha falloff, which is as cheap
/// to paint as a solid fill. Real blur stays reserved for the nav bar and
/// the Shopping composer, per the visual-pivot plan.
class AppBackground extends StatelessWidget {
  const AppBackground({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Stack(
      fit: StackFit.expand,
      children: [
        const ColoredBox(color: _kBackgroundBase),
        // Sized well past a corner "circle" on a real (tall, ~2340px) phone
        // viewport — on-device Phase 0 review found the first, smaller pass
        // left most of the screen a flat, plain sheet with tint only right
        // at the very top/bottom edges. Enlarged so the soft falloff reaches
        // meaningfully into the middle third, while alpha stays low enough
        // to keep the center neutral for content.
        const Positioned(
          top: -220,
          left: -200,
          width: 680,
          height: 680,
          child: _SoftBlob(),
        ),
        const Positioned(
          bottom: -260,
          right: -220,
          width: 740,
          height: 740,
          child: _SoftBlob(),
        ),
        child,
      ],
    );
  }
}

class _SoftBlob extends StatelessWidget {
  const _SoftBlob();

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        gradient: RadialGradient(
          colors: [
            _kBackgroundBlob.withValues(alpha: 0.38),
            _kBackgroundBlob.withValues(alpha: 0.0),
          ],
        ),
      ),
    );
  }
}
