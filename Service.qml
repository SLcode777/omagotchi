import QtQuick
import Quickshell
import Quickshell.Io

// Headless pet brain. Loaded once at shell startup, independent of the bar
// widget, so the pet keeps living (and roaming) with the panel closed.
//
// Needs follow the classic loop: they rise with active shell time so there is
// always something to do, whatever the hardware. System state only flavors the
// pace — pending updates make it hungrier faster, orphaned packages make it
// get dirty faster. Nothing here depends on absolute machine performance.
//
// Commands executed (all fixed argv, read-only, no interpolation):
//   checkupdates              pending official updates
//   pacman -Qdtq              orphaned packages
//   head -c N <file>          bounded state-file reads
//   find <dir> -name '*.json' list external-platform provider files
Item {
  id: root

  property var shell: null
  property var manifest: null

  readonly property string stateHome: Quickshell.env("XDG_STATE_HOME")
    || ((Quickshell.env("HOME") || "") + "/.local/state")
  readonly property string stateDir: stateHome + "/omarchy"
  readonly property string settingsPath: stateDir + "/omagotchi-settings.json"
  readonly property string petPath: stateDir + "/omagotchi-state.json"

  readonly property var defaultSettings: ({
    roamEnabled: false,
    roamScale: 3,
    // Which output the pet roams on, named as Hyprland names it (whatever
    // `hyprctl monitors` prints, e.g. "DP-1"). Empty keeps the default: the
    // largest screen.
    roamScreen: "",
    soundVolume: 0.5
  })
  // Effects volume, 0 (mute) to 1.
  readonly property real soundVolume: {
    var v = Number(settings.soundVolume)
    return isFinite(v) ? Math.max(0, Math.min(1, v)) : 0.5
  }
  property var settings: defaultSettings

  // --- persistent pet facts --------------------------------------------------

  property double hatchedAtMs: 0
  property double lastPetMs: 0

  // Growth, Gen1-chart style: the stage advances with active shell minutes,
  // and the branch taken depends on average happiness over the stage.
  property string stage: "egg"     // egg | baby | child | teen | adult
  property string form: "egg"      // sprite prefix in assets/sprites/
  property real ageMinutes: 0
  property real careSum: 0
  property int careCount: 0
  property int generation: 1

  // Need levels, 0 = fine, 100 = critical. All persisted.
  property real hungerLevel: 0
  property real dirtLevel: 0
  property real tirednessLevel: 0
  property real boredomLevel: 0
  property real lonelinessLevel: 0
  property bool sleeping: false

  readonly property var knownForms: ["egg", "baby", "child", "teen_neat",
    "teen_scruffy", "adult_ace", "adult_ok", "adult_gremlin"]

  property string omarchyPath: Quickshell.env("OMARCHY_PATH") || ""
  readonly property string notificationExecutable: omarchyPath !== ""
    ? omarchyPath + "/bin/omarchy-notification-send"
    : "omarchy-notification-send"

  // --- probe results ---------------------------------------------------------

  property int pendingUpdates: 0
  property int orphanCount: 0
  property double nowMs: Date.now()

  property bool initialized: false
  // State files are read through `head -c` so a huge or symlinked file can
  // never be pulled whole into the shell; the plugin writes a few hundred
  // bytes, anything hitting the cap is treated as corrupt.
  readonly property int maxStateBytes: 65536
  property bool settingsFileLoaded: false
  property bool petFileLoaded: false
  property string loadedSettingsText: ""
  property string loadedPetText: ""
  property string petReadProblem: ""

  // --- derived needs ---------------------------------------------------------

  readonly property real hunger: Math.max(0, Math.min(100, hungerLevel))
  readonly property real dirtiness: Math.max(0, Math.min(100, dirtLevel))
  readonly property real tiredness: Math.max(0, Math.min(100, tirednessLevel))
  readonly property real boredom: Math.max(0, Math.min(100, boredomLevel))
  // Affection is a cuddle-session need: it fills over active time and each
  // petting only takes a bite out of it — a truly lonely pet wants a real
  // fuss, not a single tap.
  readonly property real loneliness: Math.max(0, Math.min(100, lonelinessLevel))

  readonly property bool roaming: canRoam && settings.roamEnabled === true

  readonly property real worstNeed: Math.max(hunger, dirtiness, tiredness,
    boredom, loneliness)
  readonly property real happiness: Math.round(100 - worstNeed)

  readonly property real careAverage: careCount > 0 ? careSum / careCount : 100
  readonly property bool canRoam: stage !== "egg" && stage !== "baby"
  readonly property string stageLabel: ({
    egg: "Egg", baby: "Baby", child: "Child", teen: "Teen", adult: "Adult"
  })[stage] || stage

  // Where the pet left its panel, in screen coordinates (center x, feet y),
  // so the roaming window can pick up the fall right under the card. Negative
  // x means "no handoff": spawn at the usual floor spot.
  property real handoffX: -1
  property real handoffY: -1
  property string handoffScreen: ""
  // The screen Go play / Come home was last clicked on. Runtime-only: after
  // a shell restart the playground falls back to the usual screen choice.
  property string requestedScreenName: ""

  // Set by the panel to call the pet home through the tractor beam; the roam
  // window beams it up to the handoff spot, then clears this and fires
  // arrivedHome so the panel can play the entrance.
  property bool returnRequested: false
  signal arrivedHome()

  // Short-lived animation for a care action ("eat", "wash"), shown by the
  // panel and the roaming pet, then cleared.
  property string transientAnim: ""
  Timer {
    id: transientTimer
    interval: 2500
    onTriggered: root.endCare()
  }

  function endCare() {
    transientAnim = ""
    // Woken up for a meal or a bath? It stays up a little while, then goes
    // back to bed if it is still sleepy. The flag survives until the pet
    // actually dozes back off, so chained cares (feed then wash) re-arm it.
    if (wokenForCare) resleepTimer.restart()
  }
  Timer {
    id: resleepTimer
    interval: 30000
    onTriggered: {
      // Mid-meal or mid-scrub: stay up, endCare re-arms the timer.
      if (root.sleeping || root.eating || root.transientAnim !== "") return
      root.wokenForCare = false
      if (root.tirednessLevel < 60 || root.roaming) return
      root.sleeping = true
      root.playSound("sleep")
      root.flushPet()
    }
  }

  // A meal is eaten bite by bite: hunger drains over ~6 s from full while
  // the eat frames play, then a last chew before the animation ends.
  readonly property bool eating: eatTimer.running
  Timer {
    id: eatTimer
    interval: 100
    repeat: true
    onTriggered: {
      root.hungerLevel = Math.max(0, root.hungerLevel - 100 / 60)
      if (root.hungerLevel > 0) return
      stop()
      transientTimer.interval = 600
      transientTimer.restart()
      root.flushPet()
    }
  }

  // The shared emote bubbles, one glyph per complaining need. When several
  // needs complain at once the bubble cycles through them every few seconds.
  // Views hide the bubble when the file doesn't exist yet.
  readonly property var activeEmotes: {
    if (!initialized || sleeping || stage === "egg") return []
    var list = []
    if (hunger >= 60) list.push("emote_hungry")
    if (dirtiness >= 60) list.push("emote_dirty")
    if (tiredness >= 60) list.push("emote_sleepy")
    if (boredom >= 60) list.push("emote_bored")
    if (loneliness >= 60) list.push("emote_sad")
    return list
  }
  property int emoteCycle: 0
  readonly property string emoteName: activeEmotes.length === 0
    ? "" : activeEmotes[emoteCycle % activeEmotes.length]

  Timer {
    interval: 3000
    running: root.initialized && root.activeEmotes.length > 1
    repeat: true
    onTriggered: root.emoteCycle += 1
  }

  // The idle-state animation views should show (falls back to plain idle in
  // PetSprite when the dedicated sprite doesn't exist yet).
  readonly property string stateAnim: {
    if (!initialized || stage === "egg") return "idle"
    if (sleeping) return "sleep"
    switch (mood) {
    case "hungry": return "hungry"
    case "dirty": return "dirty"
    case "sleepy": return "sleepy"
    case "bored": return "bored"
    case "lonely": return "sad"
    default: return "idle"
    }
  }

  // Priority order: sleep is a state, then the loudest complaint wins.
  readonly property string mood: {
    if (!initialized) return "sleeping"
    if (stage === "egg") return "egg"
    if (sleeping) return "sleeping"
    if (hunger >= 60) return "hungry"
    if (dirtiness >= 60) return "dirty"
    if (tiredness >= 60) return "sleepy"
    if (boredom >= 60) return "bored"
    if (loneliness >= 60) return "lonely"
    if (worstNeed >= 35) return "meh"
    return "happy"
  }

  readonly property string moodLabel: {
    switch (mood) {
    case "egg": return "An egg. Something wiggles inside…"
    case "sleeping": return "Zzz…"
    case "hungry": return pendingUpdates > 0
      ? "Hungry — and those " + pendingUpdates + " pending updates smell delicious"
      : "Hungry — feed me!"
    case "dirty": return orphanCount > 0
      ? "Feeling gross — the " + orphanCount + " orphaned packages don't help"
      : "Feeling gross — bath time?"
    case "sleepy": return "Sleepy — about to doze off…"
    case "bored": return "Bored — let me out to play!"
    case "lonely": return "Lonely — pet me!"
    case "meh": return "Doing okay"
    case "happy": return "Happy!"
    default: return "Omagotchi"
    }
  }

  // --- the minute tick -------------------------------------------------------

  // Per-stage personalities: babies nap constantly, children burst with
  // energy and want out, teens raid the fridge and stay in. See ROADMAP §3.
  readonly property var stageRates: ({
    baby:  { hunger: 1.5, dirt: 1, tired: 2.0, fun: 0.5 },
    child: { hunger: 1,   dirt: 1, tired: 1,   fun: 1.5 },
    teen:  { hunger: 2,   dirt: 1, tired: 0.8, fun: 0.5 },
    adult: { hunger: 1,   dirt: 1, tired: 1,   fun: 1 }
  })

  // Per-active-minute rates. System state flavors the pace: pending updates
  // and orphans speed up hunger/dirt, roaming is fun but tiring.
  function applyMinute() {
    if (stage === "egg") return // an egg has no needs yet
    var rates = stageRates[stage] || stageRates.adult

    // Out and about, it hums to itself once or twice an hour.
    if (roaming && !sleeping && Math.random() < 1.5 / 60) playSound("hum")

    hungerLevel = Math.min(100,
      hungerLevel + (pendingUpdates > 0 ? 0.5 : 0.33) * rates.hunger)
    dirtLevel = Math.min(100,
      dirtLevel + (orphanCount > 0 ? 0.33 : 0.21) * rates.dirt)

    if (sleeping) {
      tirednessLevel = Math.max(0, tirednessLevel - 2.2)
      if (tirednessLevel <= 5) {
        sleeping = false
        // A little hum tells the user it woke up on its own.
        playSound("hum")
      }
    } else {
      tirednessLevel = Math.min(100,
        tirednessLevel + (roaming ? 0.55 : 0.28) * rates.tired)
      if (tirednessLevel >= 90) {
        sleeping = true
        playSound("sleep")
      } else if (tirednessLevel >= 60 && !roaming && !resleepTimer.running) {
        // Sleepy at home with nothing better to do: doze off shortly.
        // The timer re-checks (eating, care animation) before committing.
        resleepTimer.restart()
      }
    }

    boredomLevel = roaming
      ? Math.max(0, boredomLevel - 2.0)
      : Math.min(100, boredomLevel + 0.45 * rates.fun)

    // Full in ~14 active hours; each petting takes 10 off.
    lonelinessLevel = Math.min(100, lonelinessLevel + 0.12)
  }

  // --- growth ----------------------------------------------------------------

  function maybeEvolve() {
    if (stage === "egg" && ageMinutes >= 5)
      return evolve("baby", "baby", "The egg hatched!")
    if (stage === "baby" && ageMinutes >= 70)
      return evolve("child", "child", "Your baby grew into a child!")
    if (stage === "child" && ageMinutes >= 550)
      return evolve("teen", careAverage >= 55 ? "teen_neat" : "teen_scruffy",
        "Your child is a teen now. Interesting haircut.")
    if (stage === "teen" && ageMinutes >= 1510) {
      var neat = form === "teen_neat"
      var next = "adult_gremlin"
      if (careAverage >= 75) next = neat ? "adult_ace" : "adult_ok"
      else if (careAverage >= 40) next = neat ? "adult_ok" : "adult_gremlin"
      return evolve("adult", next, "Your teen is all grown up.")
    }
  }

  function evolve(nextStage, nextForm, message) {
    stage = nextStage
    form = nextForm
    careSum = 0
    careCount = 0
    flushPet()
    playSound(nextStage === "baby" ? "hatch" : "evolve")
    notify("Omagotchi", message)
  }

  // --- sounds ----------------------------------------------------------------

  // One short clip per event, named after the event so better sounds can be
  // dropped in without touching code. The current set is placeholders reused
  // from the tomato-timer plugin's library — see CREDITS.md.
  // One file per event, or a list to pick from at random (see CREDITS.md).
  readonly property var eventSounds: ({
    hatch: "hatch.wav",
    evolve: "evolve.wav",
    eat: "eat.wav",
    wash: "wash.wav",
    pet: ["pet.wav", "pet2.wav"],
    hum: "humming.wav",
    grab: "grab.wav",
    sleep: "sleep.mp3",
    stun: "stun.mp3",
    land: "fall.wav",
    beamCharge: "subbass.wav",
    beam: "tractorbeam.wav",
    ball: "balloon.wav",
    farewell_ace: "farewell_ace.wav",
    farewell_ok: "farewell_ok.mp3",
    farewell_gremlin: "farewell_gremlin.mp3"
  })

  // pw-play wants a filesystem path, not a file:// URL.
  function soundPath(relativePath) {
    var url = Qt.resolvedUrl(relativePath).toString()
    if (url.indexOf("file://") === 0) url = url.substring(7)
    return decodeURIComponent(url)
  }

  function playSound(event) {
    if (soundVolume <= 0) return
    var file = eventSounds[event]
    if (Array.isArray(file)) file = file[Math.floor(Math.random() * file.length)]
    if (!file) return
    Quickshell.execDetached(["pw-play", "--volume", soundVolume.toFixed(2),
      soundPath("sounds/" + file)])
  }

  function notify(title, body) {
    Quickshell.execDetached([
      notificationExecutable,
      "--app-name", "omagotchi",
      "-u", "normal",
      title,
      body
    ])
  }

  // --- actions ---------------------------------------------------------------

  // Care wakes a sleeping pet first; once the fuss is over it dozes back
  // off if it is still sleepy (see transientTimer).
  property bool wokenForCare: false

  function wakeForCare() {
    // A pending doze interrupted by more care still counts as one to resume.
    if (resleepTimer.running) wokenForCare = true
    resleepTimer.stop()
    if (!sleeping) return
    sleeping = false
    wokenForCare = true
  }

  function feedNow() {
    if (eating) return
    wakeForCare()
    transientAnim = "eat"
    transientTimer.stop()
    playSound("eat")
    if (hungerLevel > 0) eatTimer.restart()
    else {
      // Nothing to eat: a polite nibble, then back to whatever it was doing.
      transientTimer.interval = 1200
      transientTimer.restart()
    }
  }

  // Washing is a scrubbing gesture: the panel feeds it mouse travel and the
  // dirt comes off progressively. Persisted by the caller on gesture end.
  function scrub(amount) {
    if (dirtLevel <= 0) return
    wakeForCare()
    dirtLevel = Math.max(0, dirtLevel - amount)
    transientAnim = "wash"
    transientTimer.interval = 2500
    transientTimer.restart()
    if (dirtLevel === 0) flushPet()
  }

  // The Tamagotchi farewell: the adult sets off into the world, a new egg appears, and
  // the generation counter carries the legacy.
  // Letting go is a little ceremony: the adult leaves its room (if home),
  // walks to the nearest screen corner, says goodbye in its own voice and
  // walks off the screen. Only then does the new egg appear.
  property bool farewellPending: false

  function beginFarewell() {
    if (stage !== "adult" || farewellPending) return
    wakeUp()
    farewellPending = true
  }

  function farewellSoundEvent() {
    return "farewell_" + form.replace("adult_", "")
  }

  function sendOff() {
    if (stage !== "adult") return
    farewellPending = false
    generation += 1
    stage = "egg"
    form = "egg"
    ageMinutes = 0
    careSum = 0
    careCount = 0
    hungerLevel = 0
    dirtLevel = 0
    tirednessLevel = 0
    boredomLevel = 0
    lonelinessLevel = 0
    sleeping = false
    hatchedAtMs = Date.now()
    lastPetMs = hatchedAtMs
    // The adult may leave from outdoors; the egg must not inherit a stale
    // "out playing" state (disabled Come home button, surprise exit at
    // the child stage).
    updateSettings({ roamEnabled: false })
    flushPet()
    notify("Omagotchi", "Your companion said goodbye and walked off into the world… a new egg appeared! (Gen " + generation + ")")
  }

  // A deliberate wake-up — petting, grabbing, or sending it out — unlike
  // wakeForCare it does not tuck the pet back in afterwards.
  function wakeUp() {
    if (!sleeping) return
    resleepTimer.stop()
    sleeping = false
    wokenForCare = false
    flushPet()
  }

  function petThePet() {
    wakeUp()
    lastPetMs = Date.now()
    nowMs = lastPetMs
    lonelinessLevel = Math.max(0, lonelinessLevel - 10)
    // Cuddles only entertain a pet too little to go out; once it can
    // roam, boredom is cured outside.
    if (!canRoam) boredomLevel = Math.max(0, boredomLevel - 10)
    playSound("pet")
    flushPet()
  }

  function setRoamEnabled(value) {
    updateSettings({ roamEnabled: value === true })
    // Brought home already sleepy? It settles in for a moment, then dozes
    // off — no need to hit rock bottom first.
    if (value !== true && !sleeping && tirednessLevel >= 60)
      resleepTimer.restart()
  }

  // A big fall hurts its feelings too: the inverse of a petting.
  // A big fall: the thud first, the dizzy jingle right after it.
  function stunShock() {
    lonelinessLevel = Math.min(100, lonelinessLevel + 10)
    playSound("land")
    stunSoundTimer.restart()
    flushPet()
  }
  Timer {
    id: stunSoundTimer
    interval: 450
    onTriggered: root.playSound("stun")
  }

  // The tractor beam: a low thrum powering up, then the beam itself. On the
  // way home it is mirrored: the beam plays out (~2.7 s), then the thrum.
  function playBeamSound(homeward) {
    beamSoundTimer.second = homeward ? "beamCharge" : "beam"
    beamSoundTimer.interval = homeward ? 2700 : 650
    playSound(homeward ? "beam" : "beamCharge")
    beamSoundTimer.restart()
  }
  Timer {
    id: beamSoundTimer
    property string second: "beam"
    onTriggered: root.playSound(second)
  }

  function updateSettings(patch) {
    var merged = {}
    for (var key in defaultSettings) merged[key] = defaultSettings[key]
    // Only known keys survive a write: retired settings (soundEnabled…) drop
    // out of the file on their own.
    for (var current in settings) if (current in merged) merged[current] = settings[current]
    for (var change in patch) if (change in merged) merged[change] = patch[change]
    settings = merged
    settingsFile.setText(JSON.stringify(settings, null, 2) + "\n")
  }

  function flushPet() {
    petFile.setText(JSON.stringify({
      hatchedAtMs: hatchedAtMs,
      lastPetMs: lastPetMs,
      stage: stage,
      form: form,
      ageMinutes: ageMinutes,
      careSum: careSum,
      careCount: careCount,
      generation: generation,
      hungerLevel: hungerLevel,
      dirtLevel: dirtLevel,
      tirednessLevel: tirednessLevel,
      boredomLevel: boredomLevel,
      lonelinessLevel: lonelinessLevel,
      sleeping: sleeping
    }, null, 2) + "\n")
  }

  // --- init ------------------------------------------------------------------

  function initializeIfReady() {
    if (initialized || !settingsFileLoaded || !petFileLoaded) return

    try {
      var parsedSettings = loadedSettingsText !== "" ? JSON.parse(loadedSettingsText) : {}
      updateSettingsInMemory(parsedSettings)
    } catch (error) {
      console.warn("omagotchi: settings file unreadable (" + error + "), using defaults")
      settings = defaultSettings
    }

    var hatch = false
    var saveProblem = petReadProblem
    // Persisted numbers must be finite and non-negative; anything else
    // (NaN, Infinity, negatives, strings) reads as 0.
    function num(v) { var n = Number(v); return isFinite(n) && n > 0 ? n : 0 }
    try {
      var pet = loadedPetText !== "" ? JSON.parse(loadedPetText) : {}
      hatchedAtMs = num(pet.hatchedAtMs)
      lastPetMs = num(pet.lastPetMs)
      stage = typeof pet.stage === "string" ? pet.stage : "egg"
      form = typeof pet.form === "string" ? pet.form : "egg"
      ageMinutes = num(pet.ageMinutes)
      careSum = num(pet.careSum)
      careCount = Math.round(num(pet.careCount))
      generation = Math.max(1, Math.round(num(pet.generation)))
      hungerLevel = num(pet.hungerLevel)
      dirtLevel = num(pet.dirtLevel)
      tirednessLevel = num(pet.tirednessLevel)
      boredomLevel = num(pet.boredomLevel)
      if (pet.lonelinessLevel !== undefined) {
        lonelinessLevel = num(pet.lonelinessLevel)
      } else {
        // Soft migration from the old wall-clock model: seed the stored level
        // from the time since the last petting.
        var hours = Number(pet.lastPetMs) > 0
          ? Math.max(0, (Date.now() - Number(pet.lastPetMs)) / 3600000) : 0
        lonelinessLevel = Math.min(100, hours / 24 * 100)
      }
      sleeping = pet.sleeping === true
    } catch (petError) {
      hatchedAtMs = 0; lastPetMs = 0
      saveProblem = "not valid JSON (" + petError + ")"
    }
    // A corrupt or hand-edited form or stage falls back to a fresh egg
    // rather than a broken sprite path or NaN-poisoned need rates.
    if (knownForms.indexOf(form) < 0
        || ["egg", "baby", "child", "teen", "adult"].indexOf(stage) < 0) {
      if (saveProblem === "") saveProblem = "unknown stage/form " + stage + "/" + form
      stage = "egg"
      form = "egg"
      ageMinutes = 0
      careSum = 0
      careCount = 0
    }
    if (hatchedAtMs === 0) {
      hatchedAtMs = Date.now()
      lastPetMs = hatchedAtMs
      hatch = true
    }

    initialized = true
    if (saveProblem !== "") {
      console.warn("omagotchi: save file " + petPath + " " + saveProblem + " — starting over")
      notify("Omagotchi couldn't read its save file",
             "It was corrupt or oversized, so a fresh egg takes over.")
    }
    if (hatch) flushPet()

    updatesProc.running = true
    orphansProc.running = true
  }

  function updateSettingsInMemory(parsed) {
    var merged = {}
    for (var key in defaultSettings) merged[key] = defaultSettings[key]
    for (var loaded in parsed) if (loaded in merged) merged[loaded] = parsed[loaded]
    settings = merged
  }

  // --- probes ----------------------------------------------------------------

  Process {
    id: updatesProc
    command: ["checkupdates"]
    stdout: StdioCollector { id: updatesOut }
    onExited: function(exitCode) {
      if (exitCode === 0) {
        var text = updatesOut.text.trim()
        root.pendingUpdates = text === "" ? 0 : text.split("\n").length
      } else if (exitCode === 2) {
        root.pendingUpdates = 0
      }
      // exit 1 = error (offline, db lock): keep the previous value.
    }
  }

  Process {
    id: orphansProc
    command: ["pacman", "-Qdtq"]
    stdout: StdioCollector { id: orphansOut }
    onExited: function(exitCode) {
      if (exitCode === 0) {
        var text = orphansOut.text.trim()
        root.orphanCount = text === "" ? 0 : text.split("\n").length
      } else {
        root.orphanCount = 0
      }
    }
  }

  // The heartbeat: needs, age, care sampling and evolution, every minute.
  Timer {
    interval: 60 * 1000
    running: root.initialized
    repeat: true
    onTriggered: {
      root.nowMs = Date.now()
      root.applyMinute()
      root.ageMinutes += 1
      root.careSum += root.happiness
      root.careCount += 1
      root.maybeEvolve()
      if (root.careCount % 5 === 0) root.flushPet()
    }
  }
  // Both probes only flavor the pace, so every 30 minutes is plenty (and
  // checkupdates syncs its own db copy each time).
  Timer {
    interval: 30 * 60 * 1000
    running: root.initialized
    repeat: true
    onTriggered: orphansProc.running = true
  }
  Timer {
    interval: 30 * 60 * 1000
    running: root.initialized
    repeat: true
    onTriggered: updatesProc.running = true
  }

  // --- roaming ---------------------------------------------------------------

  // Outputs coming and going (monitors powered off, lock, unplug) destroy the
  // roam layer surface while QML still believes the window is visible — the
  // pet keeps "roaming" with nowhere to be drawn, and the return sequence's
  // visible-gated timers never fire. Dropping visibility for a beat after the
  // screen list settles forces Quickshell to map a fresh surface.
  property bool screensSettled: true
  Connections {
    target: Quickshell
    function onScreensChanged() {
      root.screensSettled = false
      screensSettleTimer.restart()
    }
  }
  Timer {
    id: screensSettleTimer
    interval: 1000
    onTriggered: root.screensSettled = true
  }

  // Deliberately a static window with a visibility binding, not a Loader:
  // dynamically created windows leak a zombie layer surface across the shell's
  // plugin hot-reload, which then wedges screencopy (grim) on that output.
  RoamWindow {
    petService: root
    visible: root.initialized && root.roaming && root.screensSettled
  }

  // --- external roam platforms --------------------------------------------
  // Any other plugin can give the roaming pet somewhere extra to stand by
  // dropping a JSON file in ~/.local/state/omarchy/omagotchi-platforms.d/ —
  // one file per provider, named after the plugin id, written atomically.
  // Format:
  //   { "version": 1,
  //     "screen": "DP-1",                  // Hyprland output name; "" = any
  //     "platforms": [
  //       { "id": "shelf",                 // unique within the file
  //         "x1": 100, "x2": 340,          // screen px at scale 1, x2 > x1
  //         "y": 700,                      // top of the surface, screen px
  //         "kind": "surface" } ] }        // optional: surface | ledge | perch
  // The pet is never told anything — it just walks onto ground that is there,
  // climbs to it, and stands. An absent or empty directory changes nothing.
  readonly property string platformsDir: root.stateDir + "/omagotchi-platforms.d"
  readonly property int maxProviderBytes: 16384
  readonly property int maxProviderPlatforms: 24
  // Flattened [{ id, x1, x2, y, kind, screen }] across every provider file.
  property var externalPlatforms: []
  property var _providerPlatforms: ({})   // path -> that file's platforms

  Process {
    id: platformsLister
    // Fixed argv, read-only. find does its own globbing — no shell.
    command: ["find", root.platformsDir, "-maxdepth", "1", "-type", "f",
              "-name", "*.json"]
    stdout: SplitParser {
      onRead: function(line) {
        var p = String(line).trim()
        if (p !== "") platformsLister._found.push(p)
      }
    }
    property var _found: []
    onStarted: _found = []
    onExited: function() {
      var live = {}
      for (var i = 0; i < _found.length; i++) live[_found[i]] = true
      // Forget providers whose file has gone.
      var next = {}
      for (var path in root._providerPlatforms)
        if (live[path]) next[path] = root._providerPlatforms[path]
      root._providerPlatforms = next
      root.providerPaths = _found.slice()
      root.rebuildExternalPlatforms()
    }
  }
  property var providerPaths: []

  Instantiator {
    model: root.providerPaths
    delegate: FileView {
      required property string modelData
      path: modelData
      watchChanges: true
      printErrors: false
      onLoaded: root.ingestProvider(modelData, text())
      onFileChanged: reload()
      onLoadFailed: root.ingestProvider(modelData, "")
    }
  }

  FileView {
    id: platformsDirWatcher
    path: root.platformsDir
    watchChanges: true
    printErrors: false
    onFileChanged: platformsRescan.restart()
  }

  Timer {
    id: platformsRescan
    interval: 200
    onTriggered: platformsLister.running = true
  }
  Timer {
    // Backstop: a provider that writes in place (no rename) won't bump the
    // directory, and a watcher can miss events under churn.
    running: true; repeat: true; interval: 15000
    onTriggered: platformsLister.running = true
  }
  Component.onCompleted: platformsLister.running = true

  function ingestProvider(path, raw) {
    var list = []
    var text = String(raw || "")
    if (text.length > 0 && text.length <= root.maxProviderBytes) {
      try {
        var doc = JSON.parse(text)
        if (doc && doc.version === 1 && Array.isArray(doc.platforms)) {
          var screen = doc.screen ? String(doc.screen) : ""
          var n = Math.min(doc.platforms.length, root.maxProviderPlatforms)
          for (var i = 0; i < n; i++) {
            var p = doc.platforms[i]
            if (!p || !isFinite(p.x1) || !isFinite(p.x2) || !isFinite(p.y)
                || Number(p.x2) <= Number(p.x1)) continue
            list.push({
              id: String(p.id !== undefined ? p.id : i),
              x1: Number(p.x1), x2: Number(p.x2), y: Number(p.y),
              kind: p.kind ? String(p.kind) : "surface",
              screen: screen,
            })
          }
        }
      } catch (e) { /* a malformed provider file just contributes nothing */ }
    }
    var map = root._providerPlatforms
    map[path] = list
    root._providerPlatforms = map
    root.rebuildExternalPlatforms()
  }

  function rebuildExternalPlatforms() {
    var out = []
    for (var path in root._providerPlatforms) {
      var list = root._providerPlatforms[path]
      for (var i = 0; i < list.length && out.length < 96; i++)
        out.push(list[i])
    }
    root.externalPlatforms = out
  }

  // --- persistence -----------------------------------------------------------

  // Bounded reads: at most maxStateBytes per file, once at startup. A file
  // that fills the cap (or can't be read) counts as empty → defaults.
  function boundedText(collector, exitCode) {
    if (exitCode !== 0) return ""
    var text = collector.text
    return text.length >= maxStateBytes ? "" : text
  }

  Process {
    id: settingsReader
    command: ["head", "-c", String(root.maxStateBytes), root.settingsPath]
    running: true
    stdout: StdioCollector { id: settingsOut }
    onExited: function(exitCode) {
      root.loadedSettingsText = root.boundedText(settingsOut, exitCode)
      root.settingsFileLoaded = true
      root.initializeIfReady()
    }
  }

  Process {
    id: petReader
    command: ["head", "-c", String(root.maxStateBytes), root.petPath]
    running: true
    stdout: StdioCollector { id: petOut }
    onExited: function(exitCode) {
      root.loadedPetText = root.boundedText(petOut, exitCode)
      if (exitCode === 0 && petOut.text.length >= root.maxStateBytes)
        root.petReadProblem = "exceeds " + root.maxStateBytes + " bytes"
      root.petFileLoaded = true
      root.initializeIfReady()
    }
  }

  // Write-only views: preload off, text() is never called, so the shell
  // never maps these files itself.
  FileView {
    id: settingsFile
    path: root.settingsPath
    preload: false
    watchChanges: false
    atomicWrites: true
    printErrors: false
  }

  FileView {
    id: petFile
    path: root.petPath
    preload: false
    watchChanges: false
    atomicWrites: true
    printErrors: false
  }
}
