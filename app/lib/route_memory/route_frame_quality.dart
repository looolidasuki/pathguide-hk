import 'dart:ui' as ui;
import 'dart:math' as math;

import 'route_observation_source.dart';

/// Engineering screen for unusable exposure/low detail, not a sharpness guarantee.
class RouteFrameQuality {
  static Future<bool> usable(RouteKeyframe frame) async {
    final scale = math.min(1.0, 64 / math.max(frame.width, frame.height));
    final codec = await ui.instantiateImageCodec(
      frame.bytes,
      targetWidth: math.max(1, (frame.width * scale).round()),
      targetHeight: math.max(1, (frame.height * scale).round()),
    );
    try {
      final image = (await codec.getNextFrame()).image;
      try {
        final bytes = await image.toByteData(
          format: ui.ImageByteFormat.rawRgba,
        );
        if (bytes == null) return false;
        final w = image.width, h = image.height;
        double total = 0, gradient = 0;
        int luminance(int x, int y) {
          final i = (y * w + x) * 4;
          return (bytes.getUint8(i) * 3 +
                  bytes.getUint8(i + 1) * 6 +
                  bytes.getUint8(i + 2)) ~/
              10;
        }

        for (var y = 0; y < h; y++) {
          for (var x = 0; x < w; x++) {
            final v = luminance(x, y);
            total += v;
            if (x > 0) gradient += (v - luminance(x - 1, y)).abs();
            if (y > 0) gradient += (v - luminance(x, y - 1)).abs();
          }
        }
        final mean = total / (w * h), energy = gradient / (2 * w * h - w - h);
        return mean >= 15 && mean <= 240 && energy >= 4;
      } finally {
        image.dispose();
      }
    } finally {
      codec.dispose();
    }
  }
}
