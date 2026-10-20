/// Live transfer speed from a byte counter that is read about once a second.
/// Per-second deltas are smoothed with an exponential moving average.
class SpeedMeter {
  SpeedMeter({this.alpha = 0.35});

  /// Weight of the newest sample (0..1).
  final double alpha;

  double _up = 0;
  double _down = 0;
  int? _lastUp;
  int? _lastDown;
  DateTime? _lastTime;

  /// Smoothed bytes per second; 0 until two samples were taken.
  double get upBytesPerSec => _up;
  double get downBytesPerSec => _down;

  /// Forgets everything: speeds go to 0 and the next sample is a new baseline.
  void reset() {
    _up = 0;
    _down = 0;
    _lastUp = null;
    _lastDown = null;
    _lastTime = null;
  }

  /// Takes the counters at time [now]. Returns true if a speed changed.
  /// A counter that went backwards (new session, reset) counts as no traffic
  /// for that direction in this interval and becomes the new baseline.
  bool sample(int up, int down, DateTime now) {
    final lastUp = _lastUp;
    final lastDown = _lastDown;
    final lastTime = _lastTime;
    _lastUp = up;
    _lastDown = down;
    _lastTime = now;
    if (lastUp == null || lastDown == null || lastTime == null) return false;
    final seconds = now.difference(lastTime).inMicroseconds / 1e6;
    if (seconds <= 0) return false; // clock did not advance (or went back)
    final rawUp = up >= lastUp ? (up - lastUp) / seconds : 0.0;
    final rawDown = down >= lastDown ? (down - lastDown) / seconds : 0.0;
    // Below half a byte per second the average is shown as 0 instead of
    // decaying forever.
    double smooth(double raw, double old) {
      final v = alpha * raw + (1 - alpha) * old;
      return v < 0.5 ? 0 : v;
    }

    final newUp = smooth(rawUp, _up);
    final newDown = smooth(rawDown, _down);
    final changed = newUp != _up || newDown != _down;
    _up = newUp;
    _down = newDown;
    return changed;
  }
}
