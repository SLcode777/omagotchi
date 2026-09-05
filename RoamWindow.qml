import QtQuick
import QtQuick.Effects
import QtQuick.Shapes
import Quickshell
import Quickshell.Wayland
import Quickshell.Hyprland
import qs.Commons

// The pet's playground: a transparent full-screen overlay where it wanders the
// bottom edge, climbs up the sides of windows whose top border leaves enough
// headroom, walks along their tops, and hops back down. Everything is
// click-through except the pet itself (mask), so the desktop stays usable.
//
// Window geometry comes from the Hyprland IPC via Quickshell — no shell
// commands. Coordinates are used as-is, which is correct at monitor scale 1;
// fractional scaling support is a known TODO.
PanelWindow {
  id: root

  required property var petService

  // The output named by the roamScreen setting, if it is currently connected.
  readonly property string preferredScreenName: {
    var name = petService && petService.settings ? petService.settings.roamScreen : ""
    return typeof name === "string" ? name : ""
  }

  // The playground, by priority: the screen pinned by the roamScreen setting,
  // else the screen Go play / Come home was clicked on, else the largest one.
  // Largest-only sent the pet to whichever monitor has the most pixels, which
  // on a mixed desk is often not the one being worked on — it looked like
  // "Go play" did nothing at all.
  screen: {
    var screens = Quickshell.screens
    var i
    if (preferredScreenName !== "") {
      for (i = 0; i < screens.length; i++)
        if (screens[i].name === preferredScreenName) return screens[i]
      // Named screen unplugged: fall through rather than leave the pet homeless.
    }
    var clicked = petService ? petService.requestedScreenName : ""
    if (clicked !== "") {
      for (i = 0; i < screens.length; i++)
        if (screens[i].name === clicked) return screens[i]
    }
    var best = null
    for (i = 0; i < screens.length; i++) {
      if (!best || screens[i].width * screens[i].height > best.width * best.height)
        best = screens[i]
    }
    return best
  }

  anchors {
    left: true
    right: true
    top: true
    bottom: true
  }
  color: "transparent"
  exclusionMode: ExclusionMode.Ignore
  WlrLayershell.layer: WlrLayer.Top
  WlrLayershell.namespace: "omagotchi"
  // Click-through everywhere except the pet — except mid-press, where the
  // whole window catches input: on an empty workspace Hyprland drops the
  // implicit grab on layer surfaces, so a cursor outrunning the sprite would
  // leave the input region and freeze the drag midair.
  mask: Region { item: grabArea.pressed ? root.contentItem : sprite }

  readonly property int petScale: {
    var value = petService && petService.settings
      ? Number(petService.settings.roamScale) : 3
    return value >= 2 && value <= 6 ? Math.round(value) : 3
  }
  readonly property int spriteSize: 16 * petScale
  // Headroom above a platform so the pet never pokes off-screen.
  readonly property int headroom: spriteSize + 12

  readonly property var hyprMonitor: Hyprland.monitorFor(root.screen)

  // The bar's reserved strip, so the floor sits above a bottom bar.
  readonly property real floorY: {
    var ipc = hyprMonitor ? hyprMonitor.lastIpcObject : null
    var reservedBottom = ipc && ipc.reserved && ipc.reserved.length > 3
      ? Number(ipc.reserved[3]) : 0
    return height - reservedBottom
  }

  // --- world model -----------------------------------------------------------

  // Walkable surfaces: window tops as {x1, x2, y, address}. The floor is the
  // implicit surface with address "".
  property var platforms: []
  // Current support: null = floor, else a platform object out of `platforms`.
  property var support: null

  // Platforms contributed by other plugins (petService.externalPlatforms),
  // narrowed to this screen. Geometry is range-checked later in
  // rebuildPlatforms — the layer surface has no real height yet the first
  // time this evaluates.
  readonly property var externalPlatforms: {
    var svc = petService
    var src = svc && svc.externalPlatforms ? svc.externalPlatforms : []
    var name = screen ? screen.name : ""
    var out = []
    for (var i = 0; i < src.length; i++) {
      var p = src[i]
      if (!p || !isFinite(p.x1) || !isFinite(p.x2) || !isFinite(p.y) || p.x2 <= p.x1) continue
      if (p.screen && name && p.screen !== name) continue
      out.push({ x1: Number(p.x1), x2: Number(p.x2), y: Number(p.y),
                 kind: p.kind || "surface",
                 address: "ext:" + String(p.id !== undefined ? p.id : i) })
    }
    return out
  }
  onExternalPlatformsChanged: refreshDebounce.restart()

  function rebuildPlatforms() {
    if (!hyprMonitor) { platforms = []; validateSupport(); return }
    var ws = hyprMonitor.activeWorkspace ? hyprMonitor.activeWorkspace.id : -1
    var list = []
    var toplevels = Hyprland.toplevels.values
    for (var i = 0; i < toplevels.length; i++) {
      var toplevel = toplevels[i]
      var ipc = toplevel.lastIpcObject
      if (!ipc || !ipc.at || !ipc.size) continue
      if (!toplevel.workspace || toplevel.workspace.id !== ws) continue
      if (ipc.hidden === true || ipc.mapped === false) continue
      if (ipc.fullscreen) continue
      var y = ipc.at[1] - hyprMonitor.y
      var x1 = ipc.at[0] - hyprMonitor.x
      var x2 = x1 + ipc.size[0]
      // Keep only tops the pet can stand on without leaving the screen, and
      // that are actually above the floor.
      if (y < root.headroom || y > root.floorY - 10) continue
      x1 = Math.max(0, x1)
      x2 = Math.min(root.width, x2)
      if (x2 - x1 < root.spriteSize * 2) continue
      list.push({ x1: x1, x2: x2, y: y, address: toplevel.address })
    }
    for (var t = 0; t < externalPlatforms.length; t++) {
      var ep = externalPlatforms[t]
      // Now that the surface has a real height, drop any contributed platform
      // that would sit off-screen or below the floor, and clamp it to width.
      if (ep.y < root.headroom || ep.y > root.floorY - 3) continue
      var ex1 = Math.max(0, ep.x1)
      var ex2 = Math.min(root.width, ep.x2)
      if (ex2 - ex1 < root.spriteSize) continue
      list.push({ x1: ex1, x2: ex2, y: ep.y, address: ep.address })
    }
    platforms = list
    validateSupport()
  }

  // The world changed under the pet's feet: follow the window it stands on
  // (windows are rideable!), or fall if it vanished or slid away.
  function validateSupport() {
    if (!support) return
    for (var i = 0; i < platforms.length; i++) {
      var p = platforms[i]
      if (p.address === support.address) {
        support = p
        if (action !== "climb" && action !== "fall") {
          petY = p.y
          if (petX < p.x1 || petX + spriteSize > p.x2) startFall()
        }
        return
      }
    }
    support = null
    if (action !== "fall") startFall()
  }

  // --- pet state -------------------------------------------------------------

  property real petX: 0
  property real petY: 0            // the pet's feet line
  property string action: "idle"   // idle | walk | climb | fall
  property real targetX: 0
  property real targetY: 0
  property var pendingClimb: null  // {wallX, platform} after the walk phase
  property bool facingLeft: false

  readonly property real walkSpeed: petScale * 22   // px/s
  readonly property real climbSpeed: petScale * 16
  readonly property real fallSpeed: petScale * 110

  function currentSurfaceBounds() {
    return support
      ? { x1: support.x1, x2: support.x2 }
      : { x1: 0, x2: root.width }
  }

  // Whether the (unchanged, vertical) exit beam comes down over a contributed
  // platform — e.g. a tree's foliage. When it does, the pet drops from up high
  // so the fall clears the crown and lands up on the platform, not beside it.
  function dropColumnOverExternal(feetX) {
    var c = feetX + spriteSize / 2
    for (var i = 0; i < externalPlatforms.length; i++) {
      var p = externalPlatforms[i]
      if (c >= p.x1 && c <= p.x2) return true
    }
    return false
  }

  // `reach` (optional) is how far the pet will travel toward the floor this
  // tick: a platform up to `reach` above `fromY` still counts, so a fast fall
  // snaps onto a thin platform instead of stepping straight past it in a tick
  // that started just too far away to catch it.
  function landingBelow(x, fromY, reach) {
    var best = { y: floorY, platform: null }
    var center = x + spriteSize / 2
    var lo = fromY + 1 - (reach || 0)
    for (var i = 0; i < platforms.length; i++) {
      var p = platforms[i]
      if (p.y > lo && p.y < best.y && center >= p.x1 && center <= p.x2)
        best = { y: p.y, platform: p }
    }
    return best
  }

  // Falls from higher than this fraction of the screen leave the pet seeing
  // stars for a few seconds.
  readonly property real stunFallFraction: 0.4
  property real fallStartY: 0
  // A deliberate jump (dropping out of the panel) lands on its feet, however
  // high it was — only accidents leave the pet seeing stars.
  property bool gentleFall: false

  // Tractor beam for panel trips: a translucent cone from the card's bottom
  // that carries the pet down (and, someday, back up). Origin is frozen at
  // handoff time; the cone's mouth follows the pet's feet.
  property bool beamActive: false
  property real beamX: 0
  property real beamTopY: 0

  function startFall() {
    pendingClimb = null
    if (action !== "fall") fallStartY = petY
    action = "fall"
  }

  // The way home: the beam reaches down from the card's bottom edge and
  // pulls the pet up, wherever it is. Without a usable anchor (panel on
  // another screen), it just pops home like before.
  function startReturn() {
    var svc = petService
    if (!svc) return
    if (!(svc.handoffX >= 0) || !screen || svc.handoffScreen !== screen.name) {
      finishReturn()
      return
    }
    pendingClimb = null
    support = null
    gentleFall = false
    beamX = Math.max(spriteSize / 2,
      Math.min(width - spriteSize / 2, svc.handoffX))
    beamTopY = svc.handoffY
    // The pet pops onto the beam's axis at floor level and rides straight
    // up — the beam stays perfectly vertical.
    petX = beamX - spriteSize / 2
    petY = Math.max(beamTopY + 1, floorY)
    beamActive = true
    action = "beamup"
  }

  function finishReturn() {
    var svc = petService
    beamActive = false
    action = "idle"
    if (svc) {
      svc.returnRequested = false
      svc.handoffX = -1
      svc.handoffY = -1
      svc.handoffScreen = ""
      svc.arrivedHome()
      svc.setRoamEnabled(false)
    }
  }

  Connections {
    target: root.petService
    function onReturnRequestedChanged() {
      if (!root.petService.returnRequested || !root.visible) return
      if (root.screen && root.petService.handoffScreen === root.screen.name) {
        root.startReturn()
        return
      }
      // A cross-screen Come home first moves the playground onto the panel's
      // screen, and that surface hop is asynchronous — wait for it to land
      // before anchoring the beam instead of popping home on the mismatch.
      returnWait.tries = 0
      returnWait.restart()
    }
  }

  Timer {
    id: returnWait
    interval: 100
    repeat: true
    property int tries: 0
    onTriggered: {
      var svc = root.petService
      if (!svc || !svc.returnRequested) { stop(); return }
      if (root.screen && svc.handoffScreen === root.screen.name) {
        stop()
        root.startReturn()
      } else if (++tries > 15) {
        // The playground never made it over: pop home like before.
        stop()
        root.finishReturn()
      }
    }
  }

  Timer {
    id: stunTimer
    interval: 3000
    onTriggered: if (root.action === "stunned") root.action = "idle"
  }

  function startWalkTo(x, climb) {
    var bounds = currentSurfaceBounds()
    targetX = Math.max(bounds.x1, Math.min(bounds.x2 - spriteSize, x))
    pendingClimb = climb || null
    facingLeft = targetX < petX
    action = "walk"
  }

  // Climbable walls from here: edges of platforms strictly above whose base
  // is reachable by walking on the current surface.
  function climbCandidates() {
    var bounds = currentSurfaceBounds()
    var found = []
    for (var i = 0; i < platforms.length; i++) {
      var p = platforms[i]
      if (support && p.address === support.address) continue
      if (p.y >= petY - spriteSize) continue
      if (p.x1 >= bounds.x1 && p.x1 <= bounds.x2 - spriteSize)
        found.push({ wallX: p.x1, platform: p })
      else if (p.x2 - spriteSize >= bounds.x1 && p.x2 <= bounds.x2)
        found.push({ wallX: p.x2 - spriteSize, platform: p })
    }
    return found
  }

  // --- physics ---------------------------------------------------------------

  Timer {
    id: physics
    interval: 40
    running: root.visible
    repeat: true
    onTriggered: {
      var dt = interval / 1000
      if (root.action === "walk") {
        var step = root.walkSpeed * dt
        if (Math.abs(root.targetX - root.petX) <= step) {
          root.petX = root.targetX
          if (root.pendingClimb) {
            root.targetY = root.pendingClimb.platform.y
            root.action = "climb"
          } else {
            root.action = "idle"
          }
        } else {
          root.petX += root.petX < root.targetX ? step : -step
        }
      } else if (root.action === "climb") {
        var rise = root.climbSpeed * dt
        if (root.petY - root.targetY <= rise) {
          root.petY = root.targetY
          root.support = root.pendingClimb ? root.pendingClimb.platform : root.support
          root.pendingClimb = null
          root.action = "idle"
        } else {
          root.petY -= rise
        }
      } else if (root.action === "beamup") {
        var pull = root.fallSpeed * dt
        if (root.petY - root.beamTopY <= pull) root.finishReturn()
        else root.petY -= pull
      } else if (root.action === "fall") {
        var drop = root.fallSpeed * dt
        var landing = root.landingBelow(root.petX, root.petY, drop)
        if (landing.y - root.petY <= drop) {
          root.petY = landing.y
          root.support = landing.platform
          if (!root.gentleFall
              && root.petY - root.fallStartY > root.height * root.stunFallFraction) {
            root.action = "stunned"
            stunTimer.restart()
            if (root.petService) root.petService.stunShock()
          } else {
            root.action = "idle"
          }
          root.gentleFall = false
          root.beamActive = false
        } else {
          root.petY += drop
        }
      }
    }
  }

  // --- the farewell walk -----------------------------------------------------
  // Phases: 0 get down to the floor and head for the nearest corner,
  // 1 arrived — say goodbye, 2 walk off the screen, then the service
  // hatches the next generation.
  property int leavingPhase: 0
  property real leavingCornerX: 0

  function advanceFarewell() {
    var svc = petService
    if (!svc || !svc.farewellPending) { leavingPhase = 0; return }
    if (action !== "idle") return
    if (leavingPhase === 0) {
      if (support) { startFall(); return }
      leavingCornerX = petX + spriteSize / 2 < width / 2 ? 0 : width - spriteSize
      leavingPhase = 1
      if (Math.abs(leavingCornerX - petX) > 1) startWalkTo(leavingCornerX, null)
    } else if (leavingPhase === 1) {
      leavingPhase = 2
      facingLeft = leavingCornerX > 0
      svc.playSound(svc.farewellSoundEvent())
      goodbyeTimer.restart()
    } else if (leavingPhase === 3) {
      leavingPhase = 0
      svc.sendOff()
    }
  }

  Timer {
    id: goodbyeTimer
    interval: 1800
    onTriggered: {
      if (root.leavingPhase !== 2) return
      root.leavingPhase = 3
      // Past the clamp on purpose: the target is just beyond the edge.
      root.targetX = root.leavingCornerX > 0 ? root.width + 4 : -root.spriteSize - 4
      root.facingLeft = root.leavingCornerX === 0
      root.pendingClimb = null
      root.action = "walk"
    }
  }

  Timer {
    interval: 200
    running: root.visible && !!root.petService && root.petService.farewellPending
    repeat: true
    onTriggered: root.advanceFarewell()
  }

  Connections {
    target: root.petService
    function onFarewellPendingChanged() {
      if (!root.petService.farewellPending) root.leavingPhase = 0
    }
  }

  // --- the wandering brain ---------------------------------------------------

  Timer {
    id: brain
    interval: 1500
    running: root.visible && root.action === "idle"
      && !(root.petService && (root.petService.sleeping || root.petService.farewellPending))
    repeat: true
    onTriggered: {
      interval = 2500 + Math.floor(Math.random() * 5000)
      var roll = Math.random()
      var climbs = root.climbCandidates()

      if (roll < 0.25 && climbs.length > 0) {
        var pick = climbs[Math.floor(Math.random() * climbs.length)]
        root.startWalkTo(pick.wallX, pick)
      } else if (roll < 0.40 && root.support) {
        // Hop off the current window.
        root.startFall()
      } else if (roll < 0.85) {
        var bounds = root.currentSurfaceBounds()
        var span = Math.max(0, bounds.x2 - bounds.x1 - root.spriteSize)
        root.startWalkTo(bounds.x1 + Math.random() * span, null)
      }
      // else: lazing around is also living.
    }
  }

  // --- keeping up with the compositor ---------------------------------------

  Connections {
    target: Hyprland
    function onRawEvent(event) {
      switch (event.name) {
      case "openwindow":
      case "closewindow":
      case "movewindow":
      case "movewindowv2":
      case "resizewindow":
      case "workspace":
      case "workspacev2":
      case "changefloatingmode":
      case "fullscreen":
      case "focusedmon":
        refreshDebounce.restart()
      }
    }
  }

  Timer {
    id: refreshDebounce
    interval: 250
    onTriggered: {
      Hyprland.refreshToplevels()
      rebuildDelay.restart()
    }
  }
  // lastIpcObject updates arrive shortly after the refresh request.
  Timer {
    id: rebuildDelay
    interval: 350
    onTriggered: root.rebuildPlatforms()
  }
  // Fallback sweep for anything the event filter misses.
  Timer {
    interval: 7000
    running: root.visible
    repeat: true
    onTriggered: refreshDebounce.restart()
  }

  function resetPosition() {
    support = null
    pendingClimb = null
    var svc = petService
    var w = width > 0 ? width : (screen ? screen.width : 0)
    if (svc && svc.returnRequested) {
      // Mid Come-home hop between screens: the freshly landed surface must
      // not mistake the pending handoff for an exit (beam-in) — stand by on
      // the floor and leave the handoff for the return sequence to consume.
      beamActive = false
      petX = Math.max(0, w / 2 - spriteSize / 2)
      petY = floorY
      action = "idle"
      refreshDebounce.restart()
      return
    }
    if (svc && svc.handoffX >= 0 && screen && svc.handoffScreen === screen.name) {
      // The pet just dropped out of its panel: continue that fall from right
      // under the card instead of teleporting to the floor. The beam itself is
      // unchanged — vertical, under the card — but when its column comes down
      // over a contributed platform the pet rides it up onto that (see below).
      rebuildPlatforms()
      petX = Math.max(0, Math.min(w - spriteSize, svc.handoffX - spriteSize / 2))
      // If the beam comes down over a contributed platform, start the fall up
      // high so it clears the top and lands on the platform; otherwise
      // continue the shorter fall from just under the card as before.
      petY = dropColumnOverExternal(petX)
        ? headroom
        : Math.max(headroom, Math.min(floorY > 0 ? floorY : svc.handoffY, svc.handoffY))
      beamX = petX + spriteSize / 2
      beamTopY = svc.handoffY
      beamActive = true
      gentleFall = true
      startFall()
    } else {
      beamActive = false
      petX = Math.max(0, w / 2 - spriteSize / 2)
      petY = floorY
      action = "idle"
    }
    if (svc) {
      svc.handoffX = -1
      svc.handoffY = -1
      svc.handoffScreen = ""
    }
    refreshDebounce.restart()
  }

  // The window can be born visible, so onVisibleChanged alone never fires;
  // and the real height only arrives once the surface is mapped, so the floor
  // glue keeps the pet grounded instead of hovering at y 0.
  Component.onCompleted: resetPosition()
  onVisibleChanged: { if (visible) resetPosition(); else leavingPhase = 0 }
  onFloorYChanged: {
    if (action === "idle" && !support && Math.abs(petY - floorY) > 1)
      petY = floorY
  }

  // --- the pet ---------------------------------------------------------------

  // The tractor beam: a soft cone widening from the card's bottom edge down
  // to the pet's feet, spaceship style. Purely visual — the click mask only
  // covers the sprite, so the beam stays click-through.
  Shape {
    id: beam
    anchors.fill: parent
    visible: opacity > 0.01
    // The fade target must stay constant while active: feeding an animated
    // value through the Behavior restarts it every frame and the fade
    // livelocks at 0. The shimmer lives in the gradient alpha instead.
    opacity: root.beamActive ? 1 : 0
    Behavior on opacity { NumberAnimation { duration: 300 } }
    preferredRendererType: Shape.CurveRenderer

    // A slow breathing shimmer while the beam is on.
    property real beamPulse: 1
    SequentialAnimation {
      running: root.beamActive
      loops: Animation.Infinite
      NumberAnimation { target: beam; property: "beamPulse"; to: 0.7; duration: 500 }
      NumberAnimation { target: beam; property: "beamPulse"; to: 1.0; duration: 500 }
      onStopped: beam.beamPulse = 1
    }

    ShapePath {
      strokeWidth: -1
      fillGradient: LinearGradient {
        x1: root.beamX; y1: root.beamTopY
        x2: root.beamX; y2: root.petY
        GradientStop { position: 0; color: Qt.alpha(Color.accent, 0.5 * beam.beamPulse) }
        GradientStop { position: 1; color: Qt.alpha(Color.accent, 0.08 * beam.beamPulse) }
      }
      startX: root.beamX - root.spriteSize * 0.3
      startY: root.beamTopY
      PathLine { x: root.beamX + root.spriteSize * 0.3; y: root.beamTopY }
      PathLine { x: root.beamX + root.spriteSize * 0.9; y: root.petY }
      PathLine { x: root.beamX - root.spriteSize * 0.9; y: root.petY }
    }
  }

  PetSprite {
    id: sprite
    width: root.spriteSize
    height: root.spriteSize
    x: root.petX
    y: root.petY - height
    // Dedicated climb frames are drawn upright (back to us, arms reaching);
    // only the walk-frame fallback needs the old -90° tilt.
    rotation: root.action === "climb" && sprite.resolvedAnim !== "climb" ? -90
      : (root.action === "held" ? 12 : 0)
    Behavior on rotation { NumberAnimation { duration: 150 } }

    readonly property bool asleep: root.petService && root.petService.sleeping
    form: root.petService.form
    anim: {
      if (asleep) return "sleep"
      switch (root.action) {
      case "walk":
      case "fall":
      case "held": return "walk" // held: legs kicking in protest
      case "climb": return "climb"
      case "stunned": return "stunned"
      default: return root.petService.transientAnim !== ""
        ? root.petService.transientAnim
        : root.petService.stateAnim
      }
    }
    // A climb without its dedicated sprite reuses the walk frames (rotated).
    fallbackAnim: root.action === "climb" ? "walk" : "idle"
    frameMs: asleep ? 1200 : (root.action === "idle" ? 500 : 220)
    tint: Color.foreground
    mirrored: root.facingLeft

    // Click = pet; press-and-move = pick it up by the scruff and carry it.
    // Once pressed, the Wayland implicit grab keeps pointer events coming to
    // this surface even when the cursor leaves the click mask, so the drag
    // survives crossing other windows.
    MouseArea {
      id: grabArea
      anchors.fill: parent
      // A stunned pet is too dizzy to be petted or picked up, and the
      // tractor beam's pull is irresistible.
      enabled: root.action !== "stunned" && root.action !== "beamup"
        && !(root.petService && root.petService.farewellPending)
      cursorShape: root.action === "held" ? Qt.ClosedHandCursor : Qt.PointingHandCursor

      property real grabDx: 0
      property real grabDy: 0
      property real pressGlobalX: 0
      property real pressGlobalY: 0
      property bool dragging: false

      onPressed: function(mouse) {
        var p = mapToItem(root.contentItem, mouse.x, mouse.y)
        pressGlobalX = p.x
        pressGlobalY = p.y
        grabDx = p.x - root.petX
        grabDy = p.y - (root.petY - root.spriteSize)
        dragging = false
      }
      onPositionChanged: function(mouse) {
        if (!pressed) return
        var p = mapToItem(root.contentItem, mouse.x, mouse.y)
        if (!dragging) {
          if (Math.abs(p.x - pressGlobalX) < 8 && Math.abs(p.y - pressGlobalY) < 8) return
          dragging = true
          root.action = "held"
          root.pendingClimb = null
          root.support = null
          root.gentleFall = false
          root.beamActive = false
          if (root.petService) {
            root.petService.wakeUp()
            root.petService.playSound("grab")
          }
        }
        root.petX = Math.max(0, Math.min(root.width - root.spriteSize, p.x - grabDx))
        root.petY = Math.max(root.headroom,
          Math.min(root.floorY, p.y - grabDy + root.spriteSize))
      }
      onReleased: {
        if (dragging) {
          dragging = false
          // A small lift so a drop aimed at a window border lands on it
          // instead of slipping just past its top edge.
          root.petY = Math.max(root.headroom, root.petY - 6)
          root.startFall()
        } else {
          if (root.petService) root.petService.petThePet()
          heart.pop()
        }
      }
      // A grab broken by the compositor must not leave the pet floating
      // midair in the held pose.
      onCanceled: {
        if (dragging) {
          dragging = false
          root.startFall()
        }
      }
    }
  }

  // The shared emote bubble: one 16x16 white glyph per state, floating above
  // the head, tinted urgent when the need turns critical. A missing emote
  // file simply hides the bubble (Image.Error), so they can land one by one.
  // While stunned, the complaint bubble yields to the orbiting stars.
  readonly property string emoteName: {
    if (!petService || action === "stunned") return ""
    return petService.emoteName
  }

  Item {
    id: emote
    visible: root.emoteName !== "" && root.action !== "held"
      && emoteImage.status === Image.Ready
    width: Math.round(root.spriteSize * 0.75)
    height: width
    x: root.petX + Math.round(root.spriteSize * 0.7)
    y: root.petY - root.spriteSize - height + bob

    property real bob: 0
    SequentialAnimation on bob {
      running: emote.visible
      loops: Animation.Infinite
      NumberAnimation { from: 0; to: -4; duration: 900; easing.type: Easing.InOutQuad }
      NumberAnimation { from: -4; to: 0; duration: 900; easing.type: Easing.InOutQuad }
    }

    Image {
      id: emoteImage
      anchors.fill: parent
      source: root.emoteName !== ""
        ? Qt.resolvedUrl("assets/sprites/" + root.emoteName + ".png") : ""
      smooth: false
      mipmap: false
      fillMode: Image.PreserveAspectFit
      visible: false
    }

    MultiEffect {
      anchors.fill: emoteImage
      source: emoteImage
      colorization: 1
      // Same tint as the pet, one creature one color.
      colorizationColor: Color.foreground
    }
  }

  // Knocked-out stars: three copies of the star sprite orbiting the head on a
  // flattened ellipse, phased 120° apart. The one swinging "behind" the head
  // shrinks and dims for depth. Pure code — the artist only drew one star.
  Item {
    id: stunStars
    visible: root.action === "stunned"

    property real angle: 0
    NumberAnimation on angle {
      running: stunStars.visible
      from: 0; to: 360
      duration: 1100
      loops: Animation.Infinite
    }

    Repeater {
      model: 3

      Item {
        id: star
        required property int index
        readonly property real theta: (stunStars.angle + star.index * 120) * Math.PI / 180
        readonly property real depth: (Math.sin(theta) + 1) / 2 // 0 = behind, 1 = front

        width: Math.round(root.spriteSize * 0.35)
        height: width
        x: root.petX + root.spriteSize / 2 + Math.cos(theta) * root.spriteSize * 0.6 - width / 2
        y: root.petY - root.spriteSize - height / 2 + Math.sin(theta) * root.spriteSize * 0.16
        opacity: 0.4 + 0.6 * depth
        scale: 0.7 + 0.3 * depth

        Image {
          id: starImage
          anchors.fill: parent
          source: Qt.resolvedUrl("assets/sprites/emote_stunned.png")
          smooth: false
          mipmap: false
          fillMode: Image.PreserveAspectFit
          visible: false
        }

        MultiEffect {
          anchors.fill: starImage
          source: starImage
          colorization: 1
          colorizationColor: Color.foreground
        }
      }
    }
  }

  Text {
    text: "z z Z"
    visible: root.petService && root.petService.sleeping
    color: Color.foreground
    font.pixelSize: Math.max(11, root.spriteSize / 3)
    x: root.petX + root.spriteSize
    y: root.petY - root.spriteSize - height / 2

    SequentialAnimation on opacity {
      running: visible
      loops: Animation.Infinite
      NumberAnimation { from: 0.25; to: 1; duration: 1300 }
      NumberAnimation { from: 1; to: 0.25; duration: 1300 }
    }
  }

  // A small thank-you heart when petted. The overlay is full-screen now, so
  // it has all the headroom it wants.
  Text {
    id: heart
    text: "♥"
    color: Color.accent
    font.pixelSize: Math.max(12, root.spriteSize / 3)
    x: root.petX + root.spriteSize / 2 - width / 2
    opacity: 0

    property real rise: 0
    y: root.petY - root.spriteSize - height - rise

    function pop() { heartAnimation.restart() }

    ParallelAnimation {
      id: heartAnimation
      NumberAnimation { target: heart; property: "rise"; from: 0; to: root.spriteSize; duration: 700 }
      SequentialAnimation {
        NumberAnimation { target: heart; property: "opacity"; from: 0; to: 1; duration: 150 }
        NumberAnimation { target: heart; property: "opacity"; to: 0; duration: 550 }
      }
    }
  }
}
