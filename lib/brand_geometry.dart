// The FoxyVPN mark: a fox head drawn as a shield (two ears, a chin point).
// Pure Dart, no Flutter imports, so the icon generator in tool/ can use it too.
// Coordinates are normalised to a 1 x 1 square.

/// Outline of the mark, clockwise from the left ear tip.
const foxMarkOutline = <(double, double)>[
  (0.17, 0.12), // left ear tip
  (0.39, 0.31), // left ear inner notch
  (0.61, 0.31), // right ear inner notch
  (0.83, 0.12), // right ear tip
  (0.86, 0.50), // right cheek
  (0.50, 0.90), // chin
  (0.14, 0.50), // left cheek
];

/// The "eye line": a short horizontal cut through the face, giving it a visor look.
const foxMarkVisor = ((0.33, 0.52), (0.67, 0.52));

/// Corner rounding of the outline, as a fraction of the mark size.
const foxMarkCornerRadius = 0.035;

/// Brand colours (ARGB).
const brandAccent = 0xFF3DDC97; // "protected" mint
const brandBackground = 0xFF0A0C0F; // near-black, slightly cool
