import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Hyprland
import Quickshell.Io
import qs.Commons
import qs.Commons as Commons
import qs.Ui
import "AppModel.js" as AppModel

// Pinned application launcher for the Omarchy bar.
//
// Each pinned entry is one icon. Clicking launches the app, or focuses it when
// it already has a window, so the strip doubles as a switcher. Windows are
// matched to entries by app id / window class, which is also what drives the
// running indicator under each icon.
//
// Pinning is done from the bar itself: the trailing + opens an app picker and
// right-clicking an icon opens its actions. Both borrow the Omarchy menu's
// dmenu mode rather than growing a second picker UI, and both persist through
// `omarchy bar set`, so shell.json stays the single source of truth.
BarWidget {
  id: root
  moduleName: "io.github.jmr85.taskbar"

  Commons.Translations {
    id: strings
    directory: Qt.resolvedUrl("i18n")
  }

  // AppLibrary owns desktop-entry icon resolution (including the on-disk index
  // that catches icons Qt's cache missed). The bar hands us the shell root.
  readonly property var appLibrary: bar && bar.shell ? bar.shell.appLibrary : null

  readonly property var pinned: AppModel.normalizeApps(root.setting("apps", []))
  readonly property int iconSize: Math.max(8, root.setting("iconSize", 17))
  readonly property int gap: Math.max(0, root.setting("spacing", 2))
  readonly property bool runningIndicator: root.setting("runningIndicator", true) === true
  readonly property bool highlightRunning: root.setting("highlightRunning", true) === true
  readonly property bool windowCountBadge: root.setting("windowCountBadge", true) === true
  readonly property bool dimWhenClosed: root.setting("dimWhenClosed", true) === true
  readonly property bool cycleWindows: root.setting("cycleWindows", true) === true
  readonly property bool wheelCycles: root.setting("wheelCycles", true) === true
  readonly property bool previewOnHover: root.setting("previewOnHover", true) === true
  readonly property bool showAddButton: root.setting("showAddButton", true) === true
  readonly property bool showRunningApps: root.setting("showRunningApps", true) === true

  // ----------------------------------------------------------- hover preview
  //
  // One card for the whole widget, anchored to whichever icon the pointer is
  // over, rather than one popup window per slot. The card is built on
  // PopupCard, so it fades and grows like the rest of the shell and takes part
  // in the bar's one-popup-at-a-time coordination.
  property var previewRecord: null
  property Item previewAnchor: null
  property bool previewOpen: false
  property var hoverRecord: null
  property Item hoverAnchor: null

  readonly property var previewWindows: root.previewRecord
    ? AppModel.windowsFor(root.previewRecord, root.windows) : []

  function openPreview(record, anchorItem) {
    if (!root.previewOnHover || !record || !anchorItem) return
    if (AppModel.windowsFor(record, root.windows).length === 0) return

    // The bar's own label would sit under the card; the card carries the app
    // name in its header instead.
    if (root.bar && typeof root.bar.hideTooltip === "function") root.bar.hideTooltip(anchorItem)

    root.previewRecord = record
    root.previewAnchor = anchorItem
    root.previewOpen = true
  }

  function closePreview() {
    root.previewOpen = false
    root.previewRecord = null
    root.previewAnchor = null
  }

  // Called by the slot delegates as their hover state changes. Leaving starts
  // a short grace period so the pointer can cross the gap into the card;
  // reaching another icon cancels the pending card and starts its own delay.
  function noteHover(record, anchorItem, hovered) {
    if (!hovered) {
      openTimer.stop()
      if (root.hoverAnchor === anchorItem) {
        root.hoverRecord = null
        root.hoverAnchor = null
      }
      if (root.previewOpen) closeTimer.restart()
      return
    }

    closeTimer.stop()
    openTimer.stop()
    if (root.previewOpen && root.previewAnchor !== anchorItem) root.closePreview()

    root.hoverRecord = record
    root.hoverAnchor = anchorItem
    if (root.previewOnHover && AppModel.windowsFor(record, root.windows).length > 0)
      openTimer.restart()
  }

  onPreviewWindowsChanged: {
    if (root.previewOpen && root.previewWindows.length === 0) root.closePreview()
  }

  Timer {
    id: openTimer
    interval: 380
    repeat: false
    onTriggered: root.openPreview(root.hoverRecord, root.hoverAnchor)
  }

  Timer {
    id: closeTimer
    interval: 260
    repeat: false
    onTriggered: if (!previewCard.containsMouse) root.closePreview()
  }

  // A passive hover card has no dismissal of its own: leaving the icon for
  // somewhere other than the card, or leaving the card, must close it. This
  // watches both while it is open, so it cannot outlive the pointer.
  Timer {
    interval: 300
    repeat: true
    running: root.previewOpen
    onTriggered: {
      var onIcon = root.previewAnchor && "tooltipHovered" in root.previewAnchor
        && root.previewAnchor.tooltipHovered === true
      if (!onIcon && !previewCard.containsMouse) root.closePreview()
    }
  }

  // Open apps that nothing pinned claims, rendered after the pinned strip and
  // gone again with their last window.
  //
  // Two guards, cheapest first. Every window event reaches here, and the
  // continuous windowtitle ones can change neither which apps are open nor
  // which are claimed, so a fingerprint of the windows is compared before any
  // matching happens. Past that, the list is still only *reassigned* when the
  // set really moved, because handing the Repeater a fresh array tears down
  // and rebuilds every icon.
  property var unpinnedApps: []

  // Deliberately not "": that is the real fingerprint of an empty window list.
  readonly property string noFingerprint: "\u0000"
  property string lastFingerprint: root.noFingerprint

  function refreshUnpinned() {
    if (!root.showRunningApps) {
      if (root.unpinnedApps.length > 0) root.unpinnedApps = []
      return
    }

    var fingerprint = AppModel.windowFingerprint(root.windows,
      AppModel.anyMatchTitle(root.pinned))
    if (fingerprint === root.lastFingerprint) return
    root.lastFingerprint = fingerprint

    var next = AppModel.unpinnedRecords(root.pinned, root.windows)
    if (AppModel.sameKeys(next, root.unpinnedApps)) return
    root.unpinnedApps = next
  }

  // Tracks `windows` rather than `windowSerial`: a shell restart repopulates
  // the toplevel list without Hyprland emitting any event, so a serial-only
  // trigger leaves the strip empty until the user happens to open or close
  // something. `windows` re-evaluates on both.
  onWindowsChanged: root.refreshUnpinned()
  // Editing the pins changes what counts as unclaimed even when not a single
  // window moved, so the fingerprint has to be dropped rather than compared.
  onPinnedChanged: root.forgetFingerprint()
  onShowRunningAppsChanged: root.forgetFingerprint()
  Component.onCompleted: root.refreshUnpinned()

  function forgetFingerprint() {
    root.lastFingerprint = root.noFingerprint
    root.refreshUnpinned()
  }

  // One model for both kinds: the slot delegate, handlePress, launch and focus
  // are all written against a record and neither needs to know the difference.
  readonly property var slots: root.pinned.concat(root.unpinnedApps)

  // With no slots at all and the + turned off the widget would be invisible,
  // so keep a trailing slot in that case purely as an affordance.
  readonly property bool showTrailing: root.showAddButton || root.slots.length === 0

  readonly property int slotSize: root.iconSize + Style.spaceReal(9)

  readonly property string pickerPath: String(Qt.resolvedUrl("bin/taskbar-pick")).replace(/^file:\/\//, "")

  // Hyprland's toplevel objects notify on their own properties, but a list of
  // them does not re-emit when a member's class or title changes. Bumping a
  // serial on every window event gives the descriptor binding something to
  // depend on.
  property int windowSerial: 0
  property int entrySerial: 0

  readonly property string activeAddress: Hyprland.activeToplevel
    ? String(Hyprland.activeToplevel.address || "") : ""

  // Flatten live toplevels into the plain descriptors AppModel matches against.
  function windowDescriptors() {
    var serial = root.windowSerial // binding dependency, see above
    var out = []
    var values = Hyprland.toplevels ? Hyprland.toplevels.values : []
    for (var i = 0; i < values.length; i++) {
      var toplevel = values[i]
      if (!toplevel) continue
      var ipc = toplevel.lastIpcObject || {}
      out.push({
        address: String(toplevel.address || ""),
        appId: toplevel.wayland ? String(toplevel.wayland.appId || "") : "",
        cls: String(ipc["class"] || ""),
        title: String(toplevel.title || ""),
        toplevel: toplevel
      })
    }
    return out
  }

  readonly property var windows: root.windowDescriptors()

  function entryById(desktopId) {
    var serial = root.entrySerial // binding dependency
    var id = String(desktopId || "")
    if (!id) return null
    try {
      var exact = DesktopEntries.byId(id)
      if (exact) return exact
    } catch (e) { }
    // heuristicLookup answers with *some* application rather than nothing, so
    // before the entry index is warm it will hand back an unrelated app and we
    // would paint its icon and name onto this slot. Keep the lookup — it is
    // what resolves "firefox" to org.mozilla.firefox — but only accept a
    // result whose id is actually related to the one asked for.
    try {
      var guess = DesktopEntries.heuristicLookup(id)
      if (guess && root.idsRelated(id, String(guess.id || ""))) return guess
    } catch (e) { }
    return null
  }

  function idsRelated(wanted, found) {
    if (!wanted || !found) return false
    var a = wanted.toLowerCase()
    var b = found.toLowerCase()
    return a === b || a.indexOf(b) !== -1 || b.indexOf(a) !== -1
  }

  function desktopEntry(record) {
    return root.entryById(record ? record.desktopId : "")
  }

  function iconSource(name) {
    var serial = root.iconSerial // binding dependency: re-resolve once scanned

    // AppLibrary resolves icons best, but since Omarchy 4.0.3 the shell facade
    // only hands it to plugins declaring kind "menu" (shell.qml,
    // manifestHasKind), so a bar widget has to resolve them itself.
    if (root.appLibrary) return root.appLibrary.iconSource(name)

    var value = String(name || "")
    if (!value) return ""
    if (value.indexOf("file://") === 0 || value.indexOf("image://") === 0) return value
    if (value.charAt(0) === "/") return Util.fileUrl(value)

    // Prefer the on-disk index. A themed lookup resolves nothing at all when
    // the configured icon theme is not installed, which is a state a user can
    // easily be in without knowing, and it also resolves an app name like
    // "zoom" to an unrelated action icon. This is the same trade AppLibrary
    // makes, for the same reasons.
    var indexed = root.iconIndex[value]
    if (indexed) return Util.fileUrl(indexed)

    // Themed lookup last, with the existence check so a miss returns "" and
    // the delegate falls back to its letter tile rather than a broken image.
    return Quickshell.iconPath(value, true)
  }

  // Icon name -> absolute path, scanned from the XDG icon directories.
  //
  // Built a line at a time as the scan streams, so the whole listing is never
  // held in memory at once, and capped so a pathological icon tree cannot grow
  // it without bound. Published only when the scan ends, so the visible index
  // never contains a half-finished scan.
  property var iconIndex: ({})
  property var pendingIcons: null
  property int pendingCount: 0
  property int iconSerial: 0

  readonly property int iconIndexLimit: 20000

  function indexIconLine(path) {
    if (root.pendingCount >= root.iconIndexLimit) return
    var value = String(path || "").trim()
    if (!value) return
    var slash = value.lastIndexOf("/")
    var file = slash >= 0 ? value.slice(slash + 1) : value
    var dot = file.lastIndexOf(".")
    var name = dot > 0 ? file.slice(0, dot) : file
    if (!name) return

    if (!root.pendingIcons) root.pendingIcons = ({})
    // First hit wins, and the scan emits svg before png, so scalable icons
    // take precedence over bitmaps.
    if (root.pendingIcons[name] !== undefined) return
    root.pendingIcons[name] = value
    root.pendingCount++
  }

  function finishIconScan() {
    // An empty result means the scan was killed by its deadline or found
    // nothing. Keep whatever the previous scan produced rather than blanking
    // every icon on a transient failure.
    if (root.pendingCount > 0) {
      root.iconIndex = root.pendingIcons
      root.iconSerial++
    }
    root.pendingIcons = null
    root.pendingCount = 0
  }

  function labelFor(record) {
    if (record && record.label) return record.label
    var entry = root.desktopEntry(record)
    if (entry && entry.name) return String(entry.name)
    return String(record && record.desktopId || "")
  }

  // Labels cross two boundaries this plugin does not own: the bar tooltip and
  // the Omarchy menu picker, both of which paint with their own rich-text
  // Text. Sanitising here keeps a markup-shaped desktop-entry name or window
  // title from being interpreted there.
  function plainLabel(record) {
    return AppModel.plainText(root.labelFor(record), 120)
  }

  function iconNameFor(record) {
    if (record && record.icon) return record.icon
    var entry = root.desktopEntry(record)
    return entry && entry.icon ? String(entry.icon) : String(record && record.desktopId || "")
  }

  readonly property color textColor: root.bar ? root.bar.foreground : Commons.Color.foreground
  readonly property string textFont: root.bar ? root.bar.fontFamily : Style.font.family

  function windowCountText(count) {
    return strings.tn("widget.windows", count)
      .arg(Commons.I18n.formatNumber(count))
  }

  // A running app with a preview card suppresses the bar tooltip: the card
  // opens at the same 380ms beat and already carries the app name.
  function tooltipFor(record, matched) {
    if (!record) return ""
    if (root.previewOnHover && matched.length > 0) return ""
    var label = root.plainLabel(record)
    if (matched.length === 0) return label
    return strings.tn("widget.tooltip", matched.length)
      .arg(label).arg(Commons.I18n.formatNumber(matched.length))
  }

  // ------------------------------------------------------------- launch/focus

  // The shell one-liner that focuses `descriptor` while holding the pointer
  // still. Split out from focusWindow so it can be inspected directly.
  function focusCommand(descriptor) {
    // Both values below are interpolated into Lua that hyprctl evaluates.
    // Util.shellQuote guards the shell layer only; a compositor value carrying
    // a quote or brace would still rewrite the Lua. So neither is trusted on
    // shape: the address is validated here, and the cursor position is
    // validated in the shell before it can reach the dispatch.
    var hex = AppModel.windowAddressHex(descriptor ? descriptor.address : "")
    if (!hex) return ""

    var target = "address:" + hex
    var focusLua = 'hl.dsp.focus({ window = "' + target + '" })'

    // awk both validates and normalises: it emits "<int> <int>" only when the
    // reply is exactly two integers (negative on monitors left of origin), and
    // nothing at all otherwise, so only numbers can reach the Lua below.
    return "pos=$(hyprctl cursorpos 2>/dev/null | awk -F, "
      + "'NR==1 && $1 ~ /^[ \t]*-?[0-9]+[ \t]*$/ && $2 ~ /^[ \t]*-?[0-9]+[ \t]*$/"
      + " { gsub(/[ \t]/, \"\", $1); gsub(/[ \t]/, \"\", $2); print $1, $2 }'); "
      // Hyprland's Lua parser rejects the legacy string form and exits 7,
      // which is what selects the fallback on older, non-Lua configs.
      + "hyprctl dispatch " + Util.shellQuote(focusLua) + " >/dev/null 2>&1 || "
      + "hyprctl dispatch focuswindow " + Util.shellQuote(target) + " >/dev/null 2>&1; "
      + '[ -n "$pos" ] && hyprctl dispatch '
      + '"hl.dsp.cursor.move({ x = ${pos%% *}, y = ${pos##* } })" >/dev/null 2>&1'
  }

  function focusWindow(descriptor) {
    if (!descriptor) return
    var toplevel = descriptor.toplevel

    // Focusing warps the pointer to the centre of the target window, because
    // Hyprland's cursor:no_warps defaults to false. That drags the pointer off
    // the icon, so a second click lands on the window instead of the taskbar
    // and cycling through an app's windows can never get past the first one.
    //
    // So capture the pointer, focus, and put the pointer back — all in one
    // shell invocation. hyprctl dispatch returns only once the compositor has
    // processed it, so the restore cannot race the warp. Landing the pointer
    // back on the bar does not steal focus: it is a layer surface, and
    // follow_mouse only refocuses when the pointer is over a window.
    if (descriptor.address && root.bar && typeof root.bar.run === "function") {
      // Empty when the address did not validate; fall through to activation
      // rather than dispatching something built from a value we do not trust.
      var command = root.focusCommand(descriptor)
      if (command) {
        root.bar.run(command)
        return
      }
    }

    // No way to run commands: fall back to the compositor's own
    // foreign-toplevel activation, which switches workspace but warps.
    if (toplevel && toplevel.wayland && typeof toplevel.wayland.activate === "function") {
      toplevel.wayland.activate()
    }
  }

  function launch(record) {
    if (!record) return
    if (record.exec) {
      if (root.bar) root.bar.run(record.exec)
      return
    }
    if (!record.desktopId) return

    // A running-app record carries the window's own class, which is often but
    // not always a desktop entry id, so resolve it to a real entry before
    // launching. Stored pins are left alone deliberately: entryById falls back
    // to a heuristic lookup that accepts substrings in both directions, and
    // letting that rewrite an id the user chose is the substitution bc1459d
    // was written to close.
    var launchId = record.desktopId
    if (record.unpinned) {
      var entry = root.desktopEntry(record)
      if (entry && entry.id) launchId = String(entry.id)
    }

    if (root.appLibrary) {
      // Goes through AppLibrary so the launch OSD behaves like the menu's.
      root.appLibrary.launch(launchId, root.labelFor(record))
      return
    }
    if (root.bar) {
      root.bar.run("uwsm-app -- gtk-launch " + Util.shellQuote(launchId + ".desktop"))
    }
  }

  function handlePress(record, button) {
    if (button === Qt.MiddleButton) {
      root.launch(record)
      return
    }
    if (button === Qt.RightButton) {
      root.promptActions(record)
      return
    }
    var matched = AppModel.windowsFor(record, root.windows)
    if (matched.length === 0) {
      root.launch(record)
      return
    }
    var index = AppModel.nextWindowIndex(matched, root.activeAddress, root.cycleWindows)
    root.focusWindow(matched[index])
  }

  // Wheel up walks back through the app's windows, wheel down forward, both
  // wrapping. Nothing happens for an app with no windows open, so scrolling
  // along the strip can never launch something by accident.
  function cycleWithWheel(record, delta) {
    if (!root.wheelCycles || !delta) return
    var matched = AppModel.windowsFor(record, root.windows)
    var index = AppModel.wheelWindowIndex(matched, root.activeAddress, delta)
    if (index >= 0) root.focusWindow(matched[index])
  }

  // ------------------------------------------------------- window operations

  // Both builders interpolate into Lua that hyprctl evaluates, so the same
  // rule as focusCommand applies: the address is validated by AppModel and the
  // workspace by a digits-only test, and nothing else reaches the string.
  function windowCloseCommand(descriptors) {
    var all = descriptors || []
    var parts = []
    for (var i = 0; i < all.length; i++) {
      var hex = AppModel.windowAddressHex(all[i] ? all[i].address : "")
      if (!hex) continue
      var target = "address:" + hex
      parts.push("hyprctl dispatch "
        + Util.shellQuote('hl.dsp.window.close({ window = "' + target + '" })')
        + " >/dev/null 2>&1 || hyprctl dispatch closewindow "
        + Util.shellQuote(target) + " >/dev/null 2>&1")
    }
    return parts.join("; ")
  }

  function windowMoveCommand(descriptors, workspace) {
    var ws = String(workspace || "")
    if (!/^[1-9][0-9]{0,3}$/.test(ws)) return ""
    var all = descriptors || []
    var parts = []
    for (var i = 0; i < all.length; i++) {
      var hex = AppModel.windowAddressHex(all[i] ? all[i].address : "")
      if (!hex) continue
      var target = "address:" + hex
      parts.push("hyprctl dispatch "
        + Util.shellQuote('hl.dsp.window.move({ window = "' + target
          + '", workspace = "' + ws + '", follow = false })')
        + " >/dev/null 2>&1 || hyprctl dispatch movetoworkspacesilent "
        + Util.shellQuote(ws + "," + target) + " >/dev/null 2>&1")
    }
    return parts.join("; ")
  }

  function closeWindows(record) {
    var command = root.windowCloseCommand(AppModel.windowsFor(record, root.windows))
    if (command && root.bar) root.bar.run(command)
  }

  function moveWindows(record, workspace) {
    var command = root.windowMoveCommand(
      AppModel.windowsFor(record, root.windows), workspace)
    if (command && root.bar) root.bar.run(command)
  }

  // ----------------------------------------------------------------- editing

  function layoutEntryIn(config) {
    var layout = config && config.bar ? config.bar.layout : null
    if (!layout) return null
    var sections = ["left", "center", "right"]
    for (var s = 0; s < sections.length; s++) {
      var list = layout[sections[s]]
      if (!Array.isArray(list)) continue
      for (var i = 0; i < list.length; i++) {
        var entry = list[i]
        if (entry && Util.canonicalWidgetId(String(entry.id || "")) === root.moduleName) return entry
      }
    }
    return null
  }

  // Apply an edit to the pin list.
  //
  // `operation` receives the list as it is *stored* and returns the new list
  // (or null to decline). It deliberately does not receive root.pinned, whose
  // per-instance injected state can be stale on an instance that survived a
  // reload; the read happens at write time instead.
  //
  // Omarchy 4.0.3 capability-scopes third-party plugin shell access
  // (services/PluginShellApi.qml): only kind "bar" plugins may mutate the
  // whole bar config, so for a bar-widget `mutateShellConfig` returns false
  // on every call and every pin save silently did nothing. A widget may,
  // however, write settings to its own bar layout entry through
  // `updateEntryInline`, which every Omarchy 4 host permits.
  function mutateApps(operation) {
    var host = root.bar ? root.bar.shell : null
    if (!host) {
      console.warn("taskbar: no shell facade, refusing to edit pins")
      return
    }

    if (typeof host.updateEntryInline === "function") {
      // root.settings is what the bar host injects per instance and patches
      // after every persist, so it holds the stored list as of the last
      // write. Each edit runs to completion inside one input event, so the
      // read-modify-write never spans two of the user's clicks.
      var stored = AppModel.normalizeApps(
        root.settings && root.settings.apps !== undefined ? root.settings.apps : [])
      var next = operation(stored)
      if (!next) return

      // updateEntryInline replaces the entry wholesale, so carry across every
      // other stored setting (iconSize, spacing, hand-written match/exec/…)
      // — a pin edit must not reset the user's configuration.
      var settings = {}
      for (var key in root.settings) if (key !== "id") settings[key] = root.settings[key]
      settings.apps = AppModel.serialize(next)

      // updateEntryInline returns false when no layout entry answers to this
      // id. Say so — the failure used to be indistinguishable from success.
      if (!host.updateEntryInline(root.moduleName, settings))
        console.warn("taskbar: no layout entry for " + root.moduleName + ", pins not saved")
      return
    }

    // Pre-4.0.3 host: the mutator is ungated there and was the seam this
    // widget was written against. Kept so `omarchy plugin update` can ship
    // this fix to installs still running 4.0.2.
    if (typeof host.mutateShellConfig !== "function") {
      console.warn("taskbar: no shell config mutator, refusing to edit pins")
      return
    }

    host.mutateShellConfig(function(config) {
      var entry = root.layoutEntryIn(config)
      if (!entry) {
        console.warn("taskbar: no layout entry for " + root.moduleName + ", pins not saved")
        return
      }
      var next = operation(AppModel.normalizeApps(entry.apps))
      if (!next) return
      entry.apps = AppModel.serialize(next)
    })
  }

  // Best-effort window-class match for a newly pinned app, so the running
  // indicator works without the user ever learning what a window class is.
  // Returns "" when the id-derived default already covers the app.
  function smartMatch(desktopId) {
    var entry = root.entryById(desktopId)
    if (!entry) return ""

    var startupClass = String(entry.startupClass || "")
    if (startupClass && AppModel.plausibleWindowClass(startupClass)) {
      if (AppModel.defaultCovers(desktopId, startupClass)) return ""
      return "^" + AppModel.escapeRegex(startupClass) + "$"
    }

    var webapp = AppModel.webappPattern(String(entry.execString || ""))
    if (webapp) {
      // The pattern is a regex, so probe it against the class it describes.
      var probe = webapp.replace(/\\/g, "")
      if (AppModel.defaultCovers(desktopId, probe)) return ""
      return webapp
    }
    return ""
  }

  function pinApp(desktopId) {
    var id = String(desktopId || "")
    if (!id) return "no id"

    var record = { desktopId: id }
    var match = root.smartMatch(id)
    if (match) record.match = match

    return root.appendPin(record)
  }

  function unpinApp(desktopId) {
    var id = String(desktopId || "")
    var outcome = "not pinned"
    root.mutateApps(function(current) {
      for (var i = 0; i < current.length; i++) {
        if (current[i].desktopId === id) {
          var next = current.slice()
          next.splice(i, 1)
          outcome = "ok"
          return next
        }
      }
      return null
    })
    return outcome
  }

  // ------------------------------------------------------------------ picker

  function runPicker(kind, context, prompt, options) {
    if (pickerProc.running) return
    pickerProc.result = ""
    pickerProc.collected = false
    pickerProc.exited = false
    pickerProc.kind = kind
    pickerProc.context = context
    var command = Util.shellQuote(root.pickerPath) + " " + Util.shellQuote(prompt)
    for (var i = 0; i < options.length; i++) command += " " + Util.shellQuote(options[i])
    pickerProc.command = ["bash", "-lc", command]
    pickerProc.running = true
  }

  function promptAdd() {
    var rows = []
    if (root.appLibrary) {
      var sorted = root.appLibrary.sortedEntries("")
      for (var i = 0; i < sorted.length; i++) rows.push(sorted[i].entry)
    } else {
      var values = DesktopEntries.applications.values || []
      for (var j = 0; j < values.length; j++) rows.push(values[j])
    }

    var options = []
    for (var k = 0; k < rows.length; k++) {
      var entry = rows[k]
      if (!entry || entry.noDisplay) continue
      var id = String(entry.id || "")
      if (!id || AppModel.hasDesktopId(root.pinned, id)) continue
      var name = AppModel.plainText(entry.name || id, 120)
      options.push("\t" + name + "\t" + id)
    }

    if (options.length === 0) return
    root.closePreview()
    root.runPicker("add", "", strings.t("widget.pinApp"), options)
  }

  function recordForKey(key) {
    var index = AppModel.indexOfKey(root.slots, key)
    return index >= 0 ? root.slots[index] : null
  }

  // Promote a running app into the pinned list. Prefer the resolved desktop
  // entry's own id, so the stored pin is a real entry rather than whatever
  // string the window happened to report.
  function pinRunning(record) {
    if (!record) return "no record"

    var entry = root.desktopEntry(record)
    if (!entry || !entry.id) {
      // No desktop entry answers to this window class. Pin it anyway, keeping
      // the anchored match so the icon still finds its windows; only launching
      // a fresh instance will be unavailable.
      return root.appendPin({ desktopId: record.desktopId, match: record.match })
    }

    var id = String(entry.id)
    var match = root.smartMatch(id)
    // smartMatch infers from the desktop entry, while record.match was built
    // from a window open right now — better evidence when the inference comes
    // up empty. Without this the new pin can fail to claim the very window
    // that produced it, leaving the app with two icons: a dead pin and the
    // live running-app one.
    if (!match && !AppModel.defaultCovers(id, record.desktopId)) match = record.match

    var stored = { desktopId: id }
    if (match) stored.match = match
    return root.appendPin(stored)
  }

  // The single place a record is appended to the stored pin list. Both the +
  // picker and the right-click promotion come through here, so the outcome
  // strings they report over IPC cannot drift apart.
  function appendPin(record) {
    var outcome = "ok"
    root.mutateApps(function(current) {
      if (AppModel.hasDesktopId(current, record.desktopId)) {
        outcome = "already pinned"
        return null
      }
      var next = current.slice()
      next.push(record)
      return next
    })
    return outcome
  }

  function promptActions(record) {
    if (!record) return
    root.closePreview()

    var matched = AppModel.windowsFor(record, root.windows)
    var options = ["\t" + strings.t("action.newInstance") + "\tlaunch"]

    if (record.unpinned) {
      options.push("\t" + strings.t("action.pin") + "\tpin")
    } else {
      var index = AppModel.indexOfKey(root.pinned, record.key)
      if (index < 0) return
      if (index > 0)
        options.push("\t" + (root.vertical ? strings.t("action.moveUp") : strings.t("action.moveLeft")) + "\tback")
      if (index < root.pinned.length - 1)
        options.push("\t" + (root.vertical ? strings.t("action.moveDown") : strings.t("action.moveRight")) + "\tforward")
      options.push("\t" + strings.t("action.unpin") + "\tunpin")
    }

    // Movement and closing act on the windows open right now, so they only
    // appear when there are any.
    if (matched.length > 0) {
      options.push("\t" + strings.t("action.moveToWorkspace") + "\tworkspace")
      options.push("\t" + (matched.length > 1
        ? strings.t("action.closeWindows") : strings.t("action.closeWindow")) + "\tclose")
    }

    root.runPicker("actions", record.key, root.plainLabel(record), options)
  }

  // Workspaces come from the compositor, so named and non-contiguous ids are
  // listed as they actually exist. Sorting keeps the picker stable between
  // summons.
  function promptWorkspace(key) {
    var values = Hyprland.workspaces ? Hyprland.workspaces.values : []
    var ids = []
    var monitors = {}
    for (var i = 0; i < values.length; i++) {
      var value = values[i]
      var id = value ? Number(value.id) : 0
      if (!(id > 0) || ids.indexOf(id) !== -1) continue
      ids.push(id)
      monitors[id] = value.monitor ? String(value.monitor.name || "") : ""
    }
    if (ids.length === 0) for (var n = 1; n <= 10; n++) ids.push(n)
    ids.sort(function(left, right) { return left - right })

    var options = []
    for (var j = 0; j < ids.length; j++) {
      var label = strings.t("workspace.label").arg(Commons.I18n.formatNumber(ids[j]))
      var monitor = AppModel.plainText(monitors[ids[j]] || "", 40)
      if (monitor) label += " \u00b7 " + monitor
      options.push("\t" + label + "\t" + ids[j])
    }

    root.closePreview()
    root.runPicker("workspaces", key, strings.t("workspace.prompt"), options)
  }

  // Closing windows is not undoable, so it always goes through a confirmation
  // that names how many will go.
  function promptClose(key) {
    var matched = AppModel.windowsFor(root.recordForKey(key), root.windows)
    if (matched.length === 0) return
    var prompt = strings.tn("action.closePrompt", matched.length)
      .arg(Commons.I18n.formatNumber(matched.length))
    root.closePreview()
    // Two fields only: the menu renders a third as subtext, and "close" under
    // "Close" is noise. The selection then comes back as the label itself, so
    // the check below compares against the same translated string.
    root.runPicker("close-confirm", key, prompt,
      ["\t" + strings.t("action.confirm"),
       "\t" + strings.t("action.cancel")])
  }

  // The menu returns "<label>\t<value>"; the value is the field we set.
  function onPicked(kind, context, raw) {
    var text = String(raw || "").trim()
    if (!text) return
    var parts = text.split("\t")
    var value = parts[parts.length - 1]
    if (!value) return

    if (kind === "add") {
      root.pinApp(value)
      return
    }
    if (kind === "workspaces") {
      root.moveWindows(root.recordForKey(context), value)
      return
    }
    if (kind === "close-confirm") {
      if (value === strings.t("action.confirm"))
        root.closeWindows(root.recordForKey(context))
      return
    }
    if (kind === "actions") root.runAction(context, value)
  }

  function runAction(key, action) {
    // Launching reads nothing back, so the local list is fine for it.
    if (action === "launch") {
      root.launch(root.recordForKey(key))
      return
    }
    if (action === "pin") {
      root.pinRunning(root.recordForKey(key))
      return
    }
    if (action === "workspace") {
      root.promptWorkspace(key)
      return
    }
    if (action === "close") {
      root.promptClose(key)
      return
    }

    // Everything else edits the list, so it works against stored state.
    root.mutateApps(function(current) {
      var index = AppModel.indexOfKey(current, key)
      if (index < 0) return null
      if (action === "unpin") {
        var next = current.slice()
        next.splice(index, 1)
        return next
      }
      if (action === "back") return AppModel.movedRecords(current, index, -1)
      if (action === "forward") return AppModel.movedRecords(current, index, 1)
      return null
    })
  }

  implicitWidth: layout.implicitWidth
  implicitHeight: layout.implicitHeight

  // App and device icons across the XDG icon dirs plus /usr/share/pixmaps.
  // Some entries use a device icon (a printer, say) rather than an app icon,
  // so both contexts are indexed. svg before png so the parser, which keeps
  // the first hit per name, prefers scalable icons.
  //
  // This runs in a long-lived shell process against directories a user can
  // point anywhere, so it is bounded on every axis: `timeout` ends a scan that
  // stalls on a slow or unresponsive mount, `-maxdepth` stops an unbounded
  // walk, awk drops the size variants of a name it has already seen (~6x fewer
  // lines on a machine with Papirus installed), `head` caps what can reach us
  // at all, and SplitParser hands over one line at a time so the listing is
  // never accumulated in memory.
  Process {
    id: iconScan
    running: true
    command: ["bash", "-lc",
      'dirs="$HOME/.icons $HOME/.local/share/icons";'
      + ' IFS=":"; for d in ${XDG_DATA_DIRS:-/usr/local/share:/usr/share}; do dirs="$dirs $d/icons"; done; unset IFS;'
      + ' { for ext in svg png; do'
      + '     for base in $dirs; do'
      + '       [ -d "$base" ] && timeout 10 find "$base" -maxdepth 6 \\( -path "*/apps/*" -o -path "*/devices/*" \\) -name "*.$ext" 2>/dev/null;'
      + '     done;'
      + '     timeout 5 find /usr/share/pixmaps -maxdepth 1 -name "*.$ext" 2>/dev/null;'
      + '   done; }'
      + ' | awk -F/ \'!seen[$NF]++\' | head -n 20000']
    stdout: SplitParser {
      splitMarker: "\n"
      onRead: function(line) { root.indexIconLine(line) }
    }
    onExited: root.finishIconScan()
  }

  Process {
    id: pickerProc
    property string kind: ""
    property string context: ""
    property string result: ""
    property bool collected: false
    property bool exited: false

    // The selection and the exit can arrive in either order, so deliver only
    // once both have. Running the next picker from here also guarantees this
    // Process no longer reports running, which runPicker checks.
    function maybeDeliver() {
      if (!pickerProc.exited || !pickerProc.collected) return
      var raw = pickerProc.result
      pickerProc.result = ""
      pickerProc.collected = false
      pickerProc.exited = false
      root.onPicked(pickerProc.kind, pickerProc.context, raw)
    }

    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        pickerProc.result = text
        pickerProc.collected = true
        pickerProc.maybeDeliver()
      }
    }
    onExited: {
      pickerProc.exited = true
      pickerProc.maybeDeliver()
    }
  }

  IpcHandler {
    target: "io.github.jmr85.taskbar"

    function pin(desktopId: string): string { return root.pinApp(desktopId) }
    function unpin(desktopId: string): string { return root.unpinApp(desktopId) }
    function list(): string { return JSON.stringify(AppModel.serialize(root.pinned)) }
    function windows(desktopId: string): string {
      var record = null
      for (var i = 0; i < root.slots.length; i++) {
        if (root.slots[i].desktopId === desktopId) { record = root.slots[i]; break }
      }
      if (!record) return "[]"
      return JSON.stringify(AppModel.windowsFor(record, root.windows).map(function(w) {
        return { address: w.address, title: w.title }
      }))
    }
    // Opens the same actions menu the right click shows, for a desktop id or a
    // slot key (an unpinned app is "unpinned:<class>").
    function actions(desktopId: string): string {
      for (var i = 0; i < root.slots.length; i++) {
        var record = root.slots[i]
        if (record.desktopId === desktopId || record.key === desktopId) {
          root.promptActions(record)
          return "ok"
        }
      }
      return "not found"
    }
    function add(): void { root.promptAdd() }
  }

  Connections {
    target: Hyprland
    function onRawEvent(event) {
      // openwindow, closewindow, movewindow, windowtitle, activewindow[v2].
      if (String(event.name || "").indexOf("window") !== -1) root.windowSerial++
    }
  }

  Connections {
    target: root.appLibrary
    ignoreUnknownSignals: true
    function onAppsChanged() { root.entrySerial++ }
  }

  GridLayout {
    id: layout
    anchors.fill: parent
    columns: root.vertical ? 1 : Math.max(1, root.slots.length + (root.showTrailing ? 1 : 0))
    columnSpacing: root.vertical ? 0 : root.gap
    rowSpacing: root.vertical ? root.gap : 0

    Repeater {
      model: root.slots

      WidgetButton {
        id: slot
        required property var modelData

        readonly property var matched: AppModel.windowsFor(modelData, root.windows)
        readonly property bool running: matched.length > 0
        readonly property bool focused: {
          if (!running || root.activeAddress === "") return false
          for (var i = 0; i < matched.length; i++) {
            if (matched[i].address === root.activeAddress) return true
          }
          return false
        }

        readonly property string iconName: root.iconNameFor(modelData)
        readonly property string appLabel: root.labelFor(modelData)

        bar: root.bar
        labelVisible: false
        hasVisualContent: true
        dimmed: root.dimWhenClosed && !running
        tooltipText: root.tooltipFor(modelData, matched)
        fixedWidth: root.vertical ? root.barSize : root.slotSize
        fixedHeight: root.vertical ? root.slotSize : root.barSize

        onPressed: function(button) { root.handlePress(slot.modelData, button) }
        onWheelMoved: function(delta) { root.cycleWithWheel(slot.modelData, delta) }
        onTooltipHoveredChanged: root.noteHover(slot.modelData, slot, slot.tooltipHovered)

        // Running apps get a faint accent wash behind the icon, the focused one
        // stronger, so the strip reads at a glance. The wash sits under the
        // icon and takes no input.
        Rectangle {
          anchors.fill: parent
          anchors.margins: Style.space(1)
          radius: Style.space(4)
          color: Commons.Color.accent
          visible: root.highlightRunning && slot.running
          opacity: slot.focused ? 0.24 : 0.13

          Behavior on opacity {
            NumberAnimation { duration: Style.duration(160); easing.type: Easing.OutCubic }
          }
        }

        Image {
          id: iconImage
          visible: status === Image.Ready
          anchors.centerIn: parent
          // Leave room for the indicator so the icon stays optically centered.
          anchors.verticalCenterOffset: root.runningIndicator && !root.vertical ? -1 : 0
          anchors.horizontalCenterOffset: root.runningIndicator && root.vertical ? 1 : 0
          width: root.iconSize
          height: root.iconSize
          sourceSize.width: root.iconSize * 2
          sourceSize.height: root.iconSize * 2
          fillMode: Image.PreserveAspectFit
          asynchronous: true
          smooth: true
          source: root.iconSource(slot.iconName)
        }

        // Icon lookups fail for entries with no themed icon; a letter tile
        // keeps the slot readable instead of leaving a hole in the bar.
        Text {
          visible: iconImage.status !== Image.Ready
          anchors.centerIn: iconImage
          textFormat: Text.PlainText
          text: slot.appLabel.substring(0, 1).toUpperCase()
          color: slot.focused ? slot.activeColor : slot.foreground
          font.family: slot.fontFamily
          font.pixelSize: Style.font.bodySmall
          renderType: Text.NativeRendering
        }

        // Accent rule under every running app, longer and solid when focused.
        Rectangle {
          visible: root.runningIndicator && slot.running
          readonly property int extent: slot.focused ? 8 : 5
          width: root.vertical ? 2 : extent
          height: root.vertical ? extent : 2
          radius: 1
          color: Commons.Color.accent
          opacity: slot.focused ? 1 : 0.6
          x: root.vertical ? 2 : (slot.width - width) / 2
          y: root.vertical ? (slot.height - height) / 2 : slot.height - height - 3

          Behavior on color {
            ColorAnimation { duration: Style.duration(160); easing.type: Easing.OutCubic }
          }
          Behavior on opacity {
            NumberAnimation { duration: Style.duration(160); easing.type: Easing.OutCubic }
          }
          Behavior on width {
            NumberAnimation { duration: Style.duration(160); easing.type: Easing.OutCubic }
          }
        }

        // Window count for apps with more than one open. The rule alone says
        // "running"; the badge says "three of them".
        Rectangle {
          visible: root.windowCountBadge && slot.matched.length > 1
          z: 2
          width: Math.max(Style.space(12), badgeLabel.implicitWidth + Style.space(5))
          height: Style.space(12)
          radius: height / 2
          color: Commons.Color.accent
          x: slot.width - width + Style.space(1)
          y: Style.space(1)

          Text {
            id: badgeLabel
            anchors.centerIn: parent
            textFormat: Text.PlainText
            text: Commons.I18n.formatNumber(slot.matched.length)
            color: Commons.Color.background
            font.family: slot.fontFamily
            font.pixelSize: Style.font.caption
            font.bold: true
            renderType: Text.NativeRendering
          }
        }
      }
    }

    WidgetButton {
      id: trailing
      visible: root.showTrailing
      bar: root.bar
      text: root.showAddButton ? "\uf067" : "\uf009"
      fontSize: Style.font.bodySmall
      hasVisualContent: root.showTrailing
      pressable: root.showAddButton
      // Sits at full strength while there is nothing pinned, so a fresh widget
      // reads as an invitation rather than as decoration.
      dimmed: root.pinned.length > 0 && !tooltipHovered
      tooltipText: root.showAddButton
        ? strings.t("widget.pinTooltip")
        : strings.t("widget.noPins")
      fixedWidth: root.vertical ? root.barSize : root.slotSize
      fixedHeight: root.vertical ? root.slotSize : root.barSize

      onPressed: function(button) { if (root.showAddButton) root.promptAdd() }
    }
  }

  // Window list for a running app: the card that makes the strip a switcher
  // rather than a launcher. One card serves every icon; rows focus a window.
  PopupCard {
    id: previewCard
    anchorItem: root.previewAnchor || root
    bar: root.bar
    owner: root
    open: root.previewOpen
    triggerMode: "hover"
    contentWidth: fittedContentWidth(Style.space(340))
    contentHeight: fittedContentHeight(previewColumn.implicitHeight, Style.space(460))

    Column {
      id: previewColumn
      width: parent.width
      spacing: Style.space(4)

      Row {
        width: parent.width
        spacing: Style.space(8)

        Item {
          width: Style.space(18)
          height: Style.space(18)

          Image {
            id: headerIcon
            anchors.fill: parent
            sourceSize.width: width * 2
            sourceSize.height: height * 2
            fillMode: Image.PreserveAspectFit
            asynchronous: true
            source: root.previewRecord ? root.iconSource(root.iconNameFor(root.previewRecord)) : ""
          }

          Text {
            visible: headerIcon.status !== Image.Ready
            anchors.centerIn: parent
            textFormat: Text.PlainText
            text: root.previewRecord
              ? root.plainLabel(root.previewRecord).substring(0, 1).toUpperCase() : ""
            color: root.textColor
            font.family: root.textFont
            font.pixelSize: Style.font.caption
            renderType: Text.NativeRendering
          }
        }

        Text {
          width: parent.width - Style.space(18) - Style.space(8)
          height: Style.space(18)
          verticalAlignment: Text.AlignVCenter
          textFormat: Text.PlainText
          text: root.previewRecord ? root.plainLabel(root.previewRecord) : ""
          color: root.textColor
          font.family: root.textFont
          font.pixelSize: Style.font.body
          elide: Text.ElideRight
        }
      }

      Text {
        width: parent.width
        textFormat: Text.PlainText
        visible: root.previewWindows.length > 1
        text: root.windowCountText(root.previewWindows.length)
        color: Util.alpha(root.textColor, 0.6)
        font.family: root.textFont
        font.pixelSize: Style.font.caption
      }

      Rectangle {
        width: parent.width
        height: 1
        color: Util.alpha(root.textColor, 0.12)
      }

      Repeater {
        model: root.previewWindows.slice(0, 8)

        Rectangle {
          id: previewRow
          required property var modelData
          width: previewColumn.width
          height: Style.space(26)
          radius: Style.space(4)
          color: rowMouse.containsMouse ? Util.alpha(root.textColor, 0.08) : "transparent"

          Text {
            anchors.left: parent.left
            anchors.leftMargin: Style.space(6)
            anchors.right: parent.right
            anchors.rightMargin: Style.space(6)
            anchors.verticalCenter: parent.verticalCenter
            textFormat: Text.PlainText
            text: AppModel.plainText(previewRow.modelData.title, 120)
            color: root.textColor
            font.family: root.textFont
            font.pixelSize: Style.font.bodySmall
            elide: Text.ElideRight
          }

          MouseArea {
            id: rowMouse
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: {
              root.focusWindow(previewRow.modelData)
              root.closePreview()
            }
          }
        }
      }

      Text {
        width: parent.width
        textFormat: Text.PlainText
        visible: root.previewWindows.length > 8
        text: strings.tn("preview.more", root.previewWindows.length - 8)
          .arg(Commons.I18n.formatNumber(root.previewWindows.length - 8))
        color: Util.alpha(root.textColor, 0.6)
        font.family: root.textFont
        font.pixelSize: Style.font.caption
      }
    }
  }
}
