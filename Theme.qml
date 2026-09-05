import QtQuick
import qs.Commons

// The player's palette, derived from the active Omarchy theme
// (theme/colors.toml) so switching themes repaints the plugin along with the
// rest of the shell.
//
// One thing stays fixed: the panel is dark. The artwork runs edge to edge on
// it and the record is a black disc with white grooves, so a light theme's
// background would leave the disc floating on paper and every groove
// invisible. A theme background that is already dark is used as it is, hue and
// all; a light one is rebuilt at the same hue with the lightness pinned down,
// which keeps a light theme recognisable without lighting up the panel.
//
// Everything above the base -- rows, borders, sliders, secondary text -- is
// mixed out of `base` and `ink` rather than fixed as a grey, so the whole
// panel picks up the theme's tint in one move.
QtObject {
  id: theme

  function luma(c) {
    return 0.299 * c.r + 0.587 * c.g + 0.114 * c.b
  }

  function blend(a, b, t) {
    return Qt.rgba(a.r + (b.r - a.r) * t, a.g + (b.g - a.g) * t, a.b + (b.b - a.b) * t, 1)
  }

  function withAlpha(c, a) {
    return Qt.rgba(c.r, c.g, c.b, a)
  }

  // The same hue at a chosen lightness. Achromatic colours report a hue of -1,
  // which Qt.hsla will not take, and a strongly saturated background turns
  // garish once it is this dark -- hence the saturation ceiling.
  function relight(c, lightness, maxSaturation) {
    return Qt.hsla(Math.max(0, c.hslHue), Math.min(c.hslSaturation, maxSaturation), lightness, 1)
  }

  // A step between the base and the text colour. One knob for every raised
  // surface in the panel, so they stay in order no matter the theme.
  function step(t) {
    return blend(theme.base, theme.ink, t)
  }

  readonly property color base: luma(Color.background) > 0.2 ? relight(Color.background, 0.07, 0.35) : Color.background
  // Text has to survive the base being forced dark: a light theme's foreground
  // is nearly black, so it is flipped rather than used straight.
  readonly property color ink: luma(Color.foreground) > 0.55 ? Color.foreground : relight(Color.foreground, 0.96, 0.2)

  readonly property color card: step(0.045)
  readonly property color hover: step(0.07)
  readonly property color raised: step(0.08)
  readonly property color selected: step(0.10)
  readonly property color line: step(0.15)
  readonly property color track: step(0.29)

  readonly property color muted: blend(ink, base, 0.35)
  readonly property color dim: blend(ink, base, 0.58)

  // Scrims: the search overlay is the panel itself dimmed down, the sheet
  // behind the playlist picker goes a shade under it so the card on top reads
  // as lifted off the panel.
  readonly property color scrim: withAlpha(base, 0.84)
  readonly property color sheetScrim: withAlpha(blend(base, "#000000", 0.25), 0.8)

  // The bar is not the panel. It keeps whatever surface the theme gives it,
  // light or dark, and the widget has to sit inside that -- a forced-dark pill
  // under a light bar would be a dark block with the bar's dark text on it. So
  // the bar surfaces step off the bar's own background, away from it in
  // whichever direction there is room.
  readonly property color barBase: Color.bar.background
  readonly property color barStep: luma(barBase) > 0.5 ? "#000000" : "#ffffff"
  readonly property color barPill: blend(barBase, barStep, 0.07)
  readonly property color barLine: blend(barBase, barStep, 0.16)
  readonly property color barArtFill: blend(barBase, barStep, 0.13)

  // The accent and the urgent colour get a lightness floor rather than the
  // luminance test used above. Above, the question is "is this theme light or
  // dark", which is perceptual; here the base is already a fixed deep dark, so
  // lightness alone predicts whether the colour will read on it -- and it does
  // not penalise blue accents the way luminance does. Without the floor a
  // theme accenting in a dark blue leaves the track on air and the progress
  // fill barely visible.
  readonly property color accent: Color.accent.hslLightness > 0.45 ? Color.accent : relight(Color.accent, 0.55, 1)
  // Text drawn on top of the accent (the search selection). The accent can be
  // light or dark depending on the theme, so the contrast colour is derived
  // from its luminance rather than fixed -- fixing it would put white text on
  // a light accent.
  readonly property color onAccent: luma(accent) > 0.6 ? relight(base, 0.06, 0.35) : relight(ink, 0.98, 0.1)

  // Errors and the destructive hover states, from the theme's urgent colour,
  // lifted the same way. Reds sit low on the lightness scale to begin with, so
  // this one lifts more often than the accent does.
  readonly property color danger: Color.urgent.hslLightness > 0.55 ? Color.urgent : relight(Color.urgent, 0.66, 0.85)
}
