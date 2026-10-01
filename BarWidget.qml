import QtQuick
import Quickshell
import qs.Commons
import qs.Ui
import "Model.js" as Model

// The bar icon for the flight tracker, and the host for its popup.
//
// Always the one solid plane, and almost always still. The only motion is a
// slow breath — the plane dimming a little and coming back — while a tracked
// flight is actually in the air; scheduled and landed flights don't move it.
// A canceled or diverted flight (Model.focusFlight decides which flight the
// bar speaks for) turns it the urgent color.
//
// Icons are Font Awesome 7 Pro when the person has a copy (see `iconFont`).
//
// Everything stateful lives in Service.qml, once per session; this widget is
// mounted once per monitor and only reads it.
BarWidget {
  id: root
  moduleName: "evansbee.flights"

  // ---- Settings (see manifest.json for the defaults these mirror).
  readonly property bool animate: setting("animate", true) !== false
  readonly property real dropAfterHours: Number(setting("dropAfterHours", 3))
  readonly property int changeMinutes: Number(setting("changeMinutes", 5)) || 5
  readonly property string iconFontPath: {
    var path = String(setting("iconFont", "~/Resources/fontawesome_font/otfs/Font Awesome 7 Pro-Solid-900.otf"))
    return path.indexOf("~/") === 0 ? Quickshell.env("HOME") + path.slice(1) : path
  }

  // ---- Icon font. The Pro font is licensed to the person, so it is read from
  //      their disk at runtime and never shipped with the plugin.
  FontLoader {
    id: proFont
    source: root.iconFontPath !== "" ? "file://" + root.iconFontPath : ""
  }

  readonly property bool freeInstalled: Qt.fontFamilies().indexOf("Font Awesome 7 Free") !== -1
  readonly property string iconTier: proFont.status === FontLoader.Ready ? "pro"
    : (freeInstalled ? "free" : "nerd")
  readonly property string iconFamily: iconTier === "pro" ? proFont.name
    : (iconTier === "free" ? "Font Awesome 7 Free" : (bar ? bar.fontFamily : Style.font.family))
  // Both Font Awesome files are the Solid (900) face; the Free family also has
  // a 400 face that lacks most of these icons, so the weight must be asked for.
  readonly property int iconWeight: iconTier === "nerd" ? Font.Normal : Font.Black

  function iconFor(name) { return Model.icon(name, root.iconTier) }

  // ---- The service. Looked up rather than bound: serviceFor() is a call, so a
  //      binding would never notice the service finishing its load after us.
  property var service: null

  function findService() {
    if (root.service) return
    var api = root.bar ? root.bar.shell : null
    var found = api && typeof api.serviceFor === "function" ? api.serviceFor(root.moduleName) : null
    if (!found) return
    root.service = found
    pushSettings()
    injectPanel()
  }

  function pushSettings() {
    if (root.service && typeof root.service.applySettings === "function")
      root.service.applySettings({ dropAfterHours: root.dropAfterHours, changeMinutes: root.changeMinutes })
  }

  Timer {
    interval: 1000
    repeat: true
    running: root.service === null
    triggeredOnStart: true
    onTriggered: root.findService()
  }

  readonly property var flights: service ? service.sortedFlights : []
  readonly property bool tracking: flights.length > 0
  readonly property bool fetching: service ? service.fetching : false
  readonly property var focusFlight: Model.focusFlight(flights)
  readonly property bool airborne: !!focusFlight && focusFlight.phase === "airborne"
  readonly property bool trouble: !!focusFlight && Model.isTroublePhase(focusFlight.phase)
  readonly property string glyph: iconFor("flying")

  // ---- Popup plumbing. Shape contract for shell.summon/hide/toggle routing:
  //      Bar.findPanelWidget requires open/close/opened on the widget root.
  readonly property bool opened: panelLoader.item ? panelLoader.item.opened === true : false

  function open() {
    if (panelLoader.item) panelLoader.item.open()
  }

  function close() {
    if (panelLoader.item) panelLoader.item.close()
  }

  function togglePanel() {
    if (panelLoader.item) panelLoader.item.toggle()
  }

  // Forwarded so this widget can stand in for the panel as the bar's popout
  // identity: Bar.requestPopout prefers closeForPopoutSwitch over close, and
  // KeyboardPanel reads popoutSwitchClosing back off its owner.
  readonly property bool popoutSwitchClosing: panelLoader.item ? panelLoader.item.popoutSwitchClosing === true : false

  function closeForPopoutSwitch() {
    if (panelLoader.item) panelLoader.item.closeForPopoutSwitch()
  }

  function injectPanel() {
    var target = panelLoader.item
    if (!target) return
    if ("bar" in target) target.bar = root.bar
    if ("settings" in target) target.settings = root.settings
    if ("anchorItem" in target) target.anchorItem = button
    if ("hostWidget" in target) target.hostWidget = root
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  onBarChanged: { injectPanel(); findService() }
  onSettingsChanged: { injectPanel(); pushSettings() }

  Loader {
    id: panelLoader
    active: true
    source: Qt.resolvedUrl("Panel.qml")
    visible: false
    onLoaded: {
      root.injectPanel()
      Qt.callLater(root.injectPanel)
    }
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: root.glyph
    active: root.trouble
    tooltipText: root.service
      ? [Model.tooltip(root.flights, root.service.now, root.service.lastError),
         Model.plansTooltip(root.service.plans, root.service.now)].filter(function(t) { return t }).join("\n")
      : "Flights · starting…"

    onPressed: function(b) {
      if (b === Qt.MiddleButton) { if (root.service) root.service.refreshAll() }
      else root.togglePanel()
    }

    // A custom icon rather than `text`, so the plane can be drawn in the icon
    // font's solid weight and can breathe. `text` stays set so the button
    // still knows it has content.
    iconComponent: Component {
      Item {
        anchors.fill: parent

        Text {
          id: plane
          anchors.centerIn: parent
          textFormat: Text.PlainText
          text: root.glyph
          color: root.trouble ? button.activeColor : button.foreground
          font.family: root.iconFamily
          font.weight: root.iconWeight
          font.pixelSize: Math.round(button.fontSize * (root.iconTier === "nerd" ? 1 : 0.86))
          renderType: Text.NativeRendering
          rotation: Model.flyingRotation(root.iconTier)

          SequentialAnimation on opacity {
            running: root.airborne && root.animate
            loops: Animation.Infinite
            NumberAnimation { to: 0.5; duration: 2200; easing.type: Easing.InOutSine }
            NumberAnimation { to: 1; duration: 2200; easing.type: Easing.InOutSine }
            onRunningChanged: if (!running) plane.opacity = 1
          }
        }
      }
    }
  }
}
