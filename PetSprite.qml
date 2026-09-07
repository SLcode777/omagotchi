import QtQuick
import QtQuick.Effects

// One animated 1-bit sprite: the two frames (a/b) of `anim` for `form`,
// tinted live with the theme's colors. If an animation's frames are not in
// assets/sprites/ yet, it falls back (to `fallbackAnim`, then to the form's
// idle, which always exists) — so sprites can land in the repo gradually
// without ever breaking a view.
Item {
  id: root

  property string form: "egg"
  property string anim: "idle"
  // What to try when `anim`'s frames are missing (e.g. "walk" for a climb).
  property string fallbackAnim: "idle"
  property int frameMs: 500
  property bool playing: true
  property color tint: "white"
  property bool mirrored: false

  property int frame: 0
  readonly property var animationCatalog: ({
    "egg": ["idle"],
    "baby": ["idle", "eat", "sleep"],
    "child": ["idle", "eat", "sleep", "walk", "climb"],
    "teen_neat": ["idle", "eat", "sleep", "walk", "climb"],
    "teen_scruffy": ["idle", "eat", "sleep", "walk", "climb"],
    "adult_ok": ["idle", "eat", "sleep", "walk", "climb"],
    "adult_ace": ["idle", "eat", "sleep", "walk", "climb"],
    "adult_gremlin": ["idle", "eat", "sleep", "walk", "climb"]
  })
  // Resolve before assigning Image.source. Loading a known-missing URL first
  // floods the shell journal every time a transient state changes.
  property string resolvedAnim: "idle"

  function animationExists(form, anim) {
    const animations = animationCatalog[form]
    return animations !== undefined && animations.indexOf(anim) !== -1
  }

  function resolveAnimation(requested, fallback) {
    if (animationExists(form, requested)) return requested
    if (animationExists(form, fallback)) return fallback
    return "idle"
  }

  function restart() {
    resolvedAnim = resolveAnimation(anim, fallbackAnim)
    frame = 0
  }

  Component.onCompleted: restart()
  onAnimChanged: restart()
  onFallbackAnimChanged: restart()
  onFormChanged: restart()

  Image {
    id: image
    anchors.fill: parent
    source: Qt.resolvedUrl("assets/sprites/" + root.form + "_" + root.resolvedAnim
      + "_" + (root.frame === 0 ? "a" : "b") + ".png")
    // Nearest-neighbour scaling keeps the pixels crisp.
    smooth: false
    mipmap: false
    fillMode: Image.PreserveAspectFit
    mirror: root.mirrored
    visible: false
  }

  MultiEffect {
    anchors.fill: image
    source: image
    colorization: 1
    colorizationColor: root.tint
  }

  Timer {
    interval: root.frameMs
    running: root.playing && root.visible
    repeat: true
    onTriggered: root.frame = root.frame === 0 ? 1 : 0
  }
}
