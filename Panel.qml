pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Effects
import QtQuick.Shapes
import Quickshell
import qs.Commons
import qs.Commons as Commons
import qs.Ui

// The pet's home: a card with the pet front and center, its needs as bars,
// and the care actions. Every action maps to real system maintenance.
Panel {
  id: root
  moduleName: "slcode777.omagotchi"

  // One panel instance exists per bar; only the largest screen's instance
  // claims the IPC target, so `qs ipc call slcode777.omagotchi toggle` acts
  // on a predictable panel instead of whichever instance registered first.
  readonly property var panelScreen: anchorItem && anchorItem.QsWindow.window
    ? anchorItem.QsWindow.window.screen : null
  readonly property var mainScreen: {
    var best = null
    var screens = Quickshell.screens
    for (var i = 0; i < screens.length; i++) {
      if (!best || screens[i].width * screens[i].height > best.width * best.height)
        best = screens[i]
    }
    return best
  }
  ipcTarget: panelScreen && panelScreen === mainScreen ? moduleName : ""

  property var anchorItem: null
  property var hostWidget: null
  property var petService: null
  readonly property var barIdentity: hostWidget || root

  readonly property bool ready: !!petService && petService.initialized === true
  // Out roaming = not home: the plate stays empty while it plays outside.
  readonly property bool petIsOut: ready && petService.roaming === true
  readonly property color foreground: Commons.Color.popups.text
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family

  readonly property var needs: ready ? [
    { label: "Hunger", value: petService.hunger,
      hint: petService.pendingUpdates > 0
        ? "rising faster: " + petService.pendingUpdates + " updates pending"
        : "rises over time",
      action: "feed", actionLabel: "Feed", needsHome: true,
      actionTip: petService.stage === "egg" ? "Still an egg — nothing to feed yet"
        : petService.eating ? "Nom nom nom…"
        : petIsOut ? "It's out playing — call it home first"
        : "A good meal, hunger back to zero" },
    { label: "Hygiene", value: petService.dirtiness,
      hint: petIsOut ? "wash it at home: press and scrub it with your mouse"
        : "press and scrub it with your mouse to wash it",
      action: "", actionLabel: "", actionTip: "" },
    { label: "Energy", value: petService.tiredness,
      hint: petService.sleeping ? "recovering — Zzz…" : "naps when exhausted",
      action: "", actionLabel: "", actionTip: "" },
    { label: "Fun", value: petService.boredom, hint: "roaming cures boredom",
      action: "", actionLabel: "", actionTip: "" },
    { label: "Affection", value: petService.loneliness, hint: "click the pet!",
      action: "", actionLabel: "", actionTip: "" }
  ] : []

  // Going out is staged: the pet visibly slides down out of its room, drops
  // through the card, and only then does roaming actually start — with the
  // exit spot handed to RoamWindow so the fall continues under the panel.
  // Coming home mirrors it: the beam pulls the pet up to the card, then it
  // rises back into its room.
  property bool exiting: false
  property bool entering: false

  // "90h 56m" reads badly past a few days: break the age into y/mo/d/h/m
  // from the largest non-zero unit. Pet time: a month is 30 active days and
  // a year is 12 of those, so units always roll over cleanly.
  function ageLabel(minutes) {
    var left = Math.floor(minutes)
    var units = [
      { size: 518400, suffix: "y" },
      { size: 43200, suffix: "mo" },
      { size: 1440, suffix: "d" },
      { size: 60, suffix: "h" },
      { size: 1, suffix: "m" }
    ]
    var parts = []
    for (var i = 0; i < units.length; i++) {
      var n = Math.floor(left / units[i].size)
      left -= n * units[i].size
      if (parts.length === 0 && n === 0 && i < units.length - 1) continue
      parts.push(n + units[i].suffix)
    }
    return parts.join(" ")
  }

  function runAction(kind) {
    if (!ready) return
    if (kind === "feed") petService.feedNow()
    else if (kind === "roam") {
      if (petService.settings.roamEnabled === true) beginReturn()
      else beginExit()
    }
  }

  function beginReturn() {
    if (petService.returnRequested) return
    // Same anchor as the exit: the beam hangs from the card's bottom edge,
    // centered under the room.
    var center = petRoom.mapToItem(null, petRoom.width / 2, 0)
    var cardBottom = keyCatcher.mapToItem(null, 0, keyCatcher.height).y
    petService.handoffX = center.x
    petService.handoffY = cardBottom
    petService.handoffScreen = panelScreen ? panelScreen.name : ""
    // Declare the return BEFORE pulling the playground onto this screen:
    // the surface hop replays resetPosition, which must already know a
    // return is pending or it mistakes the handoff for an exit beam-in.
    petService.returnRequested = true
    petService.requestedScreenName = petService.handoffScreen
    petService.playBeamSound(true)
  }

  Connections {
    target: root.ready ? root.petService : null
    function onArrivedHome() { root.playEntrance() }
  }

  function playEntrance() {
    if (!opened || !ready) return
    entering = true
    exitPet.x = (petRoom.width - exitPet.width) / 2
    exitPet.y = petRoom.height
    enterAnim.restart()
  }

  function beginExit() {
    if (exiting || !ready) return
    petService.wakeUp()
    exiting = true
    petService.playBeamSound()
    var start = petRoom.mapToItem(exitOverlay,
      (petRoom.width - exitPet.width) / 2, (petRoom.height - exitPet.height) / 2)
    exitPet.x = start.x
    exitPet.y = start.y
    exitPet.slideToY = petRoom.mapToItem(exitOverlay, 0, petRoom.height).y
    exitAnim.restart()
  }

  function finishExit() {
    if (!exiting) return
    exiting = false
    if (!ready) return
    // The panel surface is a full-screen layer shell, so scene coordinates
    // are screen coordinates. The sprite disappeared behind the card at the
    // room's edge, so the fall resumes under the card's bottom, not where
    // the sprite actually stopped.
    var feetX = exitPet.mapToItem(null, exitPet.width / 2, 0).x
    var cardBottom = keyCatcher.mapToItem(null, 0, keyCatcher.height).y
    petService.handoffX = feetX
    petService.handoffY = cardBottom
    petService.handoffScreen = panelScreen ? panelScreen.name : ""
    // The pet goes out on the screen it was sent out from.
    petService.requestedScreenName = petService.handoffScreen
    petService.setRoamEnabled(true)
  }

  KeyboardPanel {
    id: panel
    anchorItem: root.anchorItem
    owner: root.barIdentity
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    padding: Style.space(14)
    contentWidth: panel.fittedContentWidth(Style.space(410))
    // The card sizes itself from the actual content, plus breathing room at
    // the bottom. fittedContentHeight adds the card's own padding and border
    // inset — contentHeight includes them, so feeding it a raw content height
    // silently shaves that inset off the content area instead.
    contentHeight: panel.fittedContentHeight(contentColumn.implicitHeight + Style.space(16))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }

      Column {
        id: contentColumn
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        spacing: Style.space(12)

        // --- the pet -------------------------------------------------------

        Rectangle {
          id: petRoom
          width: parent.width
          height: Style.space(150)
          radius: Style.cornerRadius > 0 ? Style.space(10) : 0
          color: Qt.alpha(Commons.Color.accent, 0.08)
          border.width: 1
          border.color: Qt.alpha(Commons.Color.accent, 0.25)

          Text {
            anchors.centerIn: parent
            visible: root.petIsOut
            text: "Out playing…"
            color: Qt.alpha(root.foreground, 0.5)
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
            renderType: Text.NativeRendering
          }

          // --- the decor ---------------------------------------------------
          // Each life stage furnishes the room differently. Pieces are
          // decor_<name>.png sprites of ANY size (pets are 16×16 but decor
          // may be bigger, even rectangular); one that is not drawn yet
          // simply does not render, so the set can grow sprite by sprite.
          // x/y are fractions of the room; px is the zoom applied to the
          // sprite's own pixels (integers keep the pixel grid crisp; 1.5 is
          // tolerable on a dim piece). The room stays furnished while the
          // pet is out.
          readonly property var stageDecor: ({
            // beam = the shade's open edge in sprite pixels [x1, y1, x2, y2];
            // a cone of light is cast from it onto the pet.
            egg: [
              { name: "lamp", x: 0.60, y: 0.04, px: 1.5, beam: [1, 13, 14, 25], shelf: true }
            ],
            baby: [
              { name: "mobile", x: 0.08, y: 0.04, px: 2, sway: true }
            ],
            child: [
              { name: "ball", x: 0.74, y: 0.52, px: 2, bounce: true }
            ],
            teen_neat: [
              { name: "poster", x: 0.72, y: 0.08, px: 2 },
              { name: "controller", x: 0.11, y: 0.76, px: 2 }
            ],
            teen_scruffy: [
              { name: "poster", x: 0.72, y: 0.08, px: 2 },
              { name: "sock", x: 0.11, y: 0.76, px: 2 }
            ],
            adult_gremlin: [
              { name: "plant_gremlin", x: 0.80, y: 0.48, px: 3 }
            ],
            adult_ok: [
              { name: "plant_ok", x: 0.80, y: 0.48, px: 3 }
            ],
            adult_ace: [
              { name: "plant_ace", x: 0.80, y: 0.48, px: 1 }
            ]
          })

          // Form-specific decor wins over the shared stage decor.
          Repeater {
            model: root.ready
              ? (petRoom.stageDecor[root.petService.form]
                 || petRoom.stageDecor[root.petService.stage] || [])
              : []
            delegate: Item {
              id: decorItem
              required property var modelData
              // Clamped so a large sprite can never spill past the room walls.
              x: Math.min(petRoom.width * modelData.x,
                          petRoom.width - decorItem.width - Style.space(6))
              y: Math.min(petRoom.height * modelData.y,
                          petRoom.height - decorItem.height - Style.space(6)) - hop
              width: Style.space(decorImage.status === Image.Ready
                ? decorImage.implicitWidth * modelData.px : 0)
              height: Style.space(decorImage.status === Image.Ready
                ? decorImage.implicitHeight * modelData.px : 0)
              visible: decorImage.status === Image.Ready

              // A hanging piece sways gently around its attachment point.
              property real swayAngle: 0
              transform: Rotation {
                origin.x: decorItem.width / 2
                origin.y: 0
                angle: decorItem.swayAngle
              }
              SequentialAnimation {
                running: decorItem.visible && decorItem.modelData.sway === true
                loops: Animation.Infinite
                NumberAnimation { target: decorItem; property: "swayAngle"
                  to: 5; duration: 1900; easing.type: Easing.InOutSine }
                NumberAnimation { target: decorItem; property: "swayAngle"
                  to: -5; duration: 1900; easing.type: Easing.InOutSine }
              }

              // A toy bounces when clicked: two hops, the second smaller.
              property real hop: 0
              SequentialAnimation {
                id: bounceAnim
                NumberAnimation { target: decorItem; property: "hop"
                  to: Style.space(22); duration: 170; easing.type: Easing.OutQuad }
                NumberAnimation { target: decorItem; property: "hop"
                  to: 0; duration: 170; easing.type: Easing.InQuad }
                NumberAnimation { target: decorItem; property: "hop"
                  to: Style.space(8); duration: 110; easing.type: Easing.OutQuad }
                NumberAnimation { target: decorItem; property: "hop"
                  to: 0; duration: 110; easing.type: Easing.InQuad }
              }
              MouseArea {
                anchors.fill: parent
                enabled: decorItem.modelData.bounce === true
                cursorShape: Qt.PointingHandCursor
                onClicked: {
                  if (bounceAnim.running) return
                  bounceAnim.start()
                  root.petService.playSound("ball")
                }
              }

              // Cone of light from a lamp's shade, aimed at the pet so the
              // lamp can be nudged around and still light it. Drawn under
              // the sprite; breathes slowly through the gradient alpha.
              property bool lit: modelData.beam !== undefined
              property real glow: 1
              SequentialAnimation {
                running: decorItem.visible && decorItem.lit
                loops: Animation.Infinite
                NumberAnimation { target: decorItem; property: "glow"
                  to: 0.65; duration: 2600; easing.type: Easing.InOutSine }
                NumberAnimation { target: decorItem; property: "glow"
                  to: 1; duration: 2600; easing.type: Easing.InOutSine }
              }
              Shape {
                id: lightCone
                visible: decorItem.lit
                anchors.fill: parent
                preferredRendererType: Shape.CurveRenderer
                readonly property real s: decorImage.implicitWidth > 0
                  ? decorItem.width / decorImage.implicitWidth : 1
                readonly property real ax: decorItem.lit ? decorItem.modelData.beam[0] * s : 0
                readonly property real ay: decorItem.lit ? decorItem.modelData.beam[1] * s : 0
                readonly property real bx: decorItem.lit ? decorItem.modelData.beam[2] * s : 0
                readonly property real by: decorItem.lit ? decorItem.modelData.beam[3] * s : 0
                readonly property real mx: (ax + bx) / 2
                readonly property real my: (ay + by) / 2
                readonly property real ex: bigPet.x + bigPet.width / 2 - decorItem.x
                readonly property real ey: bigPet.y + bigPet.height / 2 - decorItem.y
                readonly property real len: Math.max(1, Math.hypot(ex - mx, ey - my))
                readonly property real ux: (ex - mx) / len
                readonly property real uy: (ey - my) / len
                readonly property real reach: len + bigPet.height * 0.45
                readonly property real cx: mx + ux * reach
                readonly property real cy: my + uy * reach
                readonly property real halfW: bigPet.width * 0.55
                ShapePath {
                  strokeWidth: -1
                  fillGradient: LinearGradient {
                    x1: lightCone.mx; y1: lightCone.my
                    x2: lightCone.cx; y2: lightCone.cy
                    GradientStop { position: 0; color: Qt.alpha(Commons.Color.accent, 0.45 * decorItem.glow) }
                    GradientStop { position: 1; color: Qt.alpha(Commons.Color.accent, 0) }
                  }
                  startX: lightCone.ax; startY: lightCone.ay
                  PathLine { x: lightCone.bx; y: lightCone.by }
                  PathLine { x: lightCone.cx + lightCone.uy * lightCone.halfW
                             y: lightCone.cy - lightCone.ux * lightCone.halfW }
                  PathLine { x: lightCone.cx - lightCone.uy * lightCone.halfW
                             y: lightCone.cy + lightCone.ux * lightCone.halfW }
                }
              }

              // A thin shelf under pieces that need something to stand on.
              Rectangle {
                visible: decorItem.modelData.shelf === true
                x: decorItem.width * 0.15
                y: decorItem.height
                width: decorItem.width * 0.75
                height: Style.space(2)
                color: Qt.alpha(Commons.Color.accent, 0.55)
              }

              Image {
                id: decorImage
                anchors.fill: parent
                source: Qt.resolvedUrl("assets/sprites/decor_" + decorItem.modelData.name + ".png")
                smooth: false
                visible: false
              }
              MultiEffect {
                anchors.fill: decorImage
                source: decorImage
                colorization: 1
                colorizationColor: Commons.Color.accent
                // Furniture stays in the background: dimmer than the pet.
                opacity: 0.55
              }
            }
          }

          PetSprite {
            id: bigPet
            anchors.centerIn: parent
            visible: !root.petIsOut && !root.exiting && !root.entering
            width: Style.space(80)
            height: Style.space(80)
            form: root.ready ? root.petService.form : "egg"
            anim: {
              if (!root.ready) return "idle"
              if (root.petService.transientAnim !== "") return root.petService.transientAnim
              // Teens hanging out in their room are on their laptop, obviously.
              if (root.petService.stage === "teen" && root.petService.stateAnim === "idle")
                return "laptop"
              return root.petService.stateAnim
            }
            frameMs: anim === "eat" ? 350 : 600
            tint: Commons.Color.accent

            // Being scrubbed is wobbly business.
            SequentialAnimation {
              running: petArea.pressed && petArea.scrubbing
              loops: Animation.Infinite
              NumberAnimation { target: bigPet; property: "rotation"; to: -7; duration: 90 }
              NumberAnimation { target: bigPet; property: "rotation"; to: 7; duration: 90 }
              onStopped: bigPet.rotation = 0
            }
          }

          // Click = pet; press and rub = scrub the dirt off. Same
          // click-vs-gesture threshold as the roam grab.
          MouseArea {
            id: petArea
            anchors.fill: bigPet
            enabled: !root.petIsOut && !root.exiting && !root.entering
            cursorShape: pressed && scrubbing ? Qt.ClosedHandCursor : Qt.PointingHandCursor

            property real lastX: 0
            property real lastY: 0
            property real travel: 0
            property bool scrubbing: false

            onPressed: function(mouse) {
              lastX = mouse.x
              lastY = mouse.y
              travel = 0
              scrubbing = false
            }
            property real travelSinceSparkle: 0
            property int sparkleIndex: 0

            onPositionChanged: function(mouse) {
              if (!pressed) return
              var moved = Math.abs(mouse.x - lastX) + Math.abs(mouse.y - lastY)
              lastX = mouse.x
              lastY = mouse.y
              travel += moved
              if (!scrubbing && travel > 12) {
                scrubbing = true
                if (root.ready && root.petService.dirtiness > 0) {
                  root.petService.playSound("wash")
                  scrubSoundTimer.restart()
                }
              }
              if (scrubbing && root.ready && root.petService.dirtiness > 0) {
                root.petService.scrub(moved * 0.03)
                if (root.petService.dirtiness <= 0) scrubSoundTimer.stop()
                travelSinceSparkle += moved
                if (travelSinceSparkle > 50) {
                  travelSinceSparkle = 0
                  var item = sparkles.itemAt(sparkleIndex % sparkles.count)
                  if (item) item.pop(bigPet.x + mouse.x, bigPet.y + mouse.y)
                  sparkleIndex += 1
                }
              }
            }
            // The scrubbing clip is ~3 s: keep it going for as long as the
            // rubbing lasts and there is dirt left.
            Timer {
              id: scrubSoundTimer
              interval: 3000
              repeat: true
              onTriggered: root.petService.playSound("wash")
            }

            onReleased: {
              scrubSoundTimer.stop()
              if (scrubbing) {
                if (root.ready) root.petService.flushPet()
              } else {
                if (root.ready) root.petService.petThePet()
                panelHeart.pop()
              }
            }
          }

          // Soap sparkles while scrubbing: a small pool of them popping in
          // round-robin around the cursor, so a vigorous scrub foams visibly.
          Repeater {
            id: sparkles
            model: 4

            Text {
              id: sparkleItem
              text: "✦"
              color: Commons.Color.accent
              font.pixelSize: Style.space(18)
              opacity: 0

              function pop(cx, cy) {
                x = cx - width / 2 + (Math.random() * 44 - 22)
                y = cy - height / 2 + (Math.random() * 28 - 14)
                sparkleAnimation.restart()
              }

              ParallelAnimation {
                id: sparkleAnimation
                NumberAnimation {
                  target: sparkleItem; property: "y"
                  from: sparkleItem.y; to: sparkleItem.y - Style.space(22)
                  duration: 600
                }
                NumberAnimation {
                  target: sparkleItem; property: "rotation"
                  from: 0; to: Math.random() < 0.5 ? -40 : 40; duration: 600
                }
                SequentialAnimation {
                  NumberAnimation { target: sparkleItem; property: "opacity"; from: 0; to: 1; duration: 100 }
                  NumberAnimation { target: sparkleItem; property: "opacity"; to: 0; duration: 500 }
                }
              }
            }
          }

          // Same recipe as the roaming view: three letters and a slow pulse.
          Text {
            id: panelZzz
            visible: !root.petIsOut && !root.exiting && !root.entering && root.ready
              && root.petService.sleeping
            text: "z z Z"
            color: Commons.Color.accent
            font.pixelSize: Style.space(16)
            anchors.left: bigPet.right
            anchors.leftMargin: -Style.space(6)
            anchors.bottom: bigPet.top
            anchors.bottomMargin: -Style.space(12)

            SequentialAnimation {
              running: panelZzz.visible
              loops: Animation.Infinite
              NumberAnimation { target: panelZzz; property: "opacity"; from: 0.25; to: 1; duration: 1300 }
              NumberAnimation { target: panelZzz; property: "opacity"; from: 1; to: 0.25; duration: 1300 }
            }
          }

          // The emote bubble, floating at the pet's shoulder when it is home.
          Item {
            id: panelEmote
            visible: !root.petIsOut && !root.exiting && !root.entering && root.ready
              && root.petService.emoteName !== ""
              && root.petService.transientAnim === ""
              && panelEmoteImage.status === Image.Ready
            width: Style.space(32)
            height: width
            anchors.left: bigPet.right
            anchors.leftMargin: -Style.space(10)
            anchors.bottom: bigPet.top
            anchors.bottomMargin: -Style.space(14)

            property real bob: 0
            SequentialAnimation on bob {
              running: panelEmote.visible
              loops: Animation.Infinite
              NumberAnimation { from: 0; to: -3; duration: 900; easing.type: Easing.InOutQuad }
              NumberAnimation { from: -3; to: 0; duration: 900; easing.type: Easing.InOutQuad }
            }
            transform: Translate { y: panelEmote.bob }

            Image {
              id: panelEmoteImage
              anchors.fill: parent
              source: root.ready && root.petService.emoteName !== ""
                ? Qt.resolvedUrl("assets/sprites/" + root.petService.emoteName + ".png") : ""
              smooth: false
              mipmap: false
              fillMode: Image.PreserveAspectFit
              visible: false
            }

            MultiEffect {
              anchors.fill: panelEmoteImage
              source: panelEmoteImage
              colorization: 1
              // Same tint as the pet in the panel.
              colorizationColor: Commons.Color.accent
            }
          }

          Text {
            id: panelHeart
            text: "♥"
            color: Commons.Color.accent
            font.pixelSize: Style.space(20)
            anchors.horizontalCenter: parent.horizontalCenter
            anchors.verticalCenter: parent.verticalCenter
            opacity: 0

            function pop() { panelHeartAnimation.restart() }

            ParallelAnimation {
              id: panelHeartAnimation
              NumberAnimation {
                target: panelHeart; property: "anchors.verticalCenterOffset"
                from: -Style.space(20); to: -Style.space(50); duration: 700
              }
              SequentialAnimation {
                NumberAnimation { target: panelHeart; property: "opacity"; from: 0; to: 1; duration: 150 }
                NumberAnimation { target: panelHeart; property: "opacity"; to: 0; duration: 550 }
              }
            }
          }
        }

        // The mood line, with the settings cogwheel at its right edge: the
        // text is centered on the full card width so the cog never shifts it.
        Item {
          width: parent.width
          height: Math.max(moodText.implicitHeight, settingsButton.height)

          Text {
            id: moodText
            width: parent.width
            anchors.verticalCenter: parent.verticalCenter
            horizontalAlignment: Text.AlignHCenter
            text: settingsControl.open ? "Settings"
              : root.ready ? root.petService.moodLabel : "Waking up…"
            color: root.foreground
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
            wrapMode: Text.Wrap
            renderType: Text.NativeRendering
          }

          PanelActionButton {
            id: settingsButton
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            // nf-md-cog, by code point so it survives tools that strip
            // private-use characters.
            iconText: String.fromCodePoint(0xF0493)
            tooltipText: settingsControl.open ? "Back to the pet" : "Settings"
            fontFamily: root.fontFamily
            foreground: root.foreground
            bordered: true
            enabled: root.ready
            onClicked: settingsControl.open = !settingsControl.open
          }
        }

        Text {
          width: parent.width
          visible: !settingsControl.open
          horizontalAlignment: Text.AlignHCenter
          text: root.ready
            ? root.petService.stageLabel + " · "
              + root.ageLabel(root.petService.ageMinutes) + " old"
              + (root.petService.generation > 1
                ? " · Gen " + root.petService.generation : "")
            : ""
          color: Qt.alpha(root.foreground, 0.6)
          font.family: root.fontFamily
          font.pixelSize: Style.font.bodySmall
          renderType: Text.NativeRendering

          // The one hint the game gives about evolution — deliberately
          // number-free: the exact thresholds stay a playground mystery.
          MouseArea {
            id: ageHover
            anchors.fill: parent
            hoverEnabled: true
            acceptedButtons: Qt.NoButton
          }
          PanelToolTip {
            visible: ageHover.containsMouse && root.ready
            text: "It grows with time. Who it becomes reflects the care you gave it."
            fontFamily: root.fontFamily
          }
        }

        Button {
          anchors.horizontalCenter: parent.horizontalCenter
          visible: root.ready && root.petService.stage === "adult"
            && !root.petService.farewellPending && !settingsControl.open
          text: "Let it go"
          tooltipText: "Say goodbye — a new egg will appear (Gen "
            + (root.ready ? root.petService.generation + 1 : 2) + ")"
          fontFamily: root.fontFamily
          onClicked: farewellConfirm.opened = true
        }

        // --- needs ---------------------------------------------------------

        Column {
          width: parent.width
          spacing: Style.space(8)
          visible: !settingsControl.open

          Repeater {
            model: root.needs

            // One row per need: the gauge block on the left, its care button
            // (when the need has one) right next to it. A fixed action slot
            // on every row keeps all the gauges the same length.
            Row {
              id: needRow
              required property var modelData
              width: parent.width
              spacing: Style.space(10)

              readonly property real actionSlot: Style.space(104)

              Column {
                width: needRow.width - needRow.actionSlot - needRow.spacing
                spacing: Style.space(3)
                anchors.verticalCenter: parent.verticalCenter

                Text {
                  text: needRow.modelData.label
                  color: root.foreground
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.bodySmall
                  renderType: Text.NativeRendering
                }

                Rectangle {
                  width: parent.width
                  height: Style.space(6)
                  radius: height / 2
                  color: Qt.alpha(root.foreground, 0.15)

                  Rectangle {
                    // The bar shows wellbeing, so a rising need drains it.
                    width: parent.width * (1 - needRow.modelData.value / 100)
                    height: parent.height
                    radius: parent.radius
                    color: needRow.modelData.value >= 60
                      ? Commons.Color.urgent : Commons.Color.accent

                    Behavior on width { NumberAnimation { duration: 300 } }
                  }
                }

                Text {
                  text: needRow.modelData.hint
                  color: Qt.alpha(root.foreground, 0.6)
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption !== undefined ? Style.font.caption : Style.font.bodySmall
                  renderType: Text.NativeRendering
                }
              }

              Item {
                width: needRow.actionSlot
                height: needRow.height
                anchors.verticalCenter: parent.verticalCenter

                Button {
                  anchors.centerIn: parent
                  visible: needRow.modelData.action !== ""
                  text: needRow.modelData.actionLabel
                  tooltipText: needRow.modelData.actionTip
                  fontFamily: root.fontFamily
                  enabled: root.ready
                    && (needRow.modelData.action !== "roam"
                        || (root.petService.canRoam && !root.petService.farewellPending))
                    && (needRow.modelData.action !== "feed"
                        || (root.petService.stage !== "egg" && !root.petService.eating))
                    && (needRow.modelData.needsHome !== true || !root.petIsOut)
                  opacity: enabled ? 1 : 0.4
                  onClicked: root.runAction(needRow.modelData.action)
                }
              }
            }
          }
        }

        // --- settings -------------------------------------------------------
        // Unfolded by the cogwheel in the card's top-right corner: effects
        // volume, and where the pet goes out to play.
        Column {
          id: settingsControl
          width: parent.width
          spacing: Style.space(8)
          visible: open
          property bool open: false
          readonly property real volume: root.ready ? root.petService.soundVolume : 0.5

          Row {
            spacing: Style.space(8)
            anchors.horizontalCenter: parent.horizontalCenter

            Text {
              anchors.verticalCenter: parent.verticalCenter
              // Nerd Font speaker glyphs (nf-md-volume_off/low/medium/high),
              // by code point so the icons survive any editor or tool that
              // strips private-use characters.
              text: String.fromCodePoint(settingsControl.volume <= 0 ? 0xF0581
                : settingsControl.volume < 0.34 ? 0xF057F
                : settingsControl.volume < 0.67 ? 0xF0580 : 0xF057E)
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
              renderType: Text.NativeRendering
            }

            PanelSlider {
              id: volumeSlider
              bar: root.bar
              width: Style.space(180)
              anchors.verticalCenter: parent.verticalCenter
              minimum: 0
              maximum: 1
              step: 0.05
              value: settingsControl.volume
              // Persist on release, and let it be heard right away.
              onReleased: function(v) {
                root.petService.updateSettings({ soundVolume: v })
                Qt.callLater(function() { root.petService.playSound("hum") })
              }
              onRightClicked: root.petService.updateSettings({
                soundVolume: settingsControl.volume > 0 ? 0 : 0.5 })
            }
            Text {
              anchors.verticalCenter: parent.verticalCenter
              width: Style.space(36)
              horizontalAlignment: Text.AlignRight
              text: Math.round((volumeSlider.dragging ? volumeSlider.liveValue
                : settingsControl.volume) * 100) + "%"
              color: Qt.alpha(root.foreground, 0.7)
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
              renderType: Text.NativeRendering
            }
          }

          Row {
            spacing: Style.space(8)
            anchors.horizontalCenter: parent.horizontalCenter
            // On a single screen every choice lands in the same place —
            // don't show a setting that cannot do anything.
            visible: Quickshell.screens.length > 1

            Text {
              anchors.verticalCenter: parent.verticalCenter
              text: "Roam screen"
              color: Qt.alpha(root.foreground, 0.7)
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
              renderType: Text.NativeRendering
            }

            Button {
              anchors.verticalCenter: parent.verticalCenter
              text: root.ready && root.petService.settings.roamScreen
                ? root.petService.settings.roamScreen : "Where I click"
              tooltipText: "Where the pet goes out to play: the screen Go play"
                + " is clicked on, or one pinned output"
              fontFamily: root.fontFamily
              enabled: root.ready
              onClicked: {
                // Cycle: follow the click, then each connected output.
                var names = [""]
                var screens = Quickshell.screens
                for (var i = 0; i < screens.length; i++) names.push(screens[i].name)
                var current = root.petService.settings.roamScreen || ""
                var next = names[(names.indexOf(current) + 1) % names.length]
                root.petService.updateSettings({ roamScreen: next })
              }
            }
          }
        }

        // --- go play / come home --------------------------------------------
        Button {
          width: parent.width
          visible: root.ready && !settingsControl.open
          text: root.ready && root.petService.settings.roamEnabled === true
            ? "Come home" : "Go play"
          tooltipText: root.ready && root.petService.canRoam
            ? "Let the pet roam and climb your windows"
            : "Too young to go out alone"
          fontFamily: root.fontFamily
          enabled: root.ready && root.petService.canRoam
            && !root.petService.farewellPending
          opacity: enabled ? 1 : 0.4
          onClicked: root.runAction("roam")
        }

      }

      // The going-out animation: the pet slides over the room's edge, then
      // gravity wins and it drops straight out. The overlay covers only the
      // room, so the clip cuts the sprite at the room's bottom border — it
      // vanishes behind the gauges instead of gliding over them.
      Item {
        id: exitOverlay
        x: contentColumn.x + petRoom.x
        y: contentColumn.y + petRoom.y
        width: petRoom.width
        height: petRoom.height
        clip: true
        z: 5
        visible: exitAnim.running || enterAnim.running

        PetSprite {
          id: exitPet
          width: Style.space(80)
          height: Style.space(80)
          form: root.ready ? root.petService.form : "egg"
          // Legs pumping on the way out; serenely carried on the way in.
          anim: root.entering ? "idle" : "walk"
          fallbackAnim: "idle"
          frameMs: 220
          tint: Commons.Color.accent

          property real slideToY: 0
        }

        SequentialAnimation {
          id: exitAnim
          // A careful slide over the edge of the room…
          NumberAnimation {
            target: exitPet; property: "y"
            to: exitPet.slideToY
            duration: 650
            easing.type: Easing.InOutQuad
          }
          // …then straight down, fully past the room's clipped edge.
          NumberAnimation {
            target: exitPet; property: "y"
            to: exitOverlay.height + exitPet.height
            duration: 200
            easing.type: Easing.InQuad
          }
          ScriptAction { script: root.finishExit() }
        }

        // The homecoming: beamed up through the card, the pet rises from the
        // room's bottom edge back to its spot.
        SequentialAnimation {
          id: enterAnim
          NumberAnimation {
            target: exitPet; property: "y"
            to: (petRoom.height - exitPet.height) / 2
            duration: 600
            easing.type: Easing.OutQuad
          }
          ScriptAction { script: root.entering = false }
        }
      }

      ConfirmDialog {
        id: farewellConfirm
        anchors.fill: parent
        message: "Let your companion go? It will head out into the big wide world, and a new egg will appear."
        confirmText: "Say goodbye"
        onConfirmed: {
          opened = false
          if (!root.ready) return
          root.petService.beginFarewell()
          // From home it first has to get outside — the usual way out.
          if (!root.petIsOut) root.beginExit()
        }
        onCanceled: opened = false
      }
    }
  }
}
