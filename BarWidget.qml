import QtQuick
import Quickshell
import qs.Commons
import qs.Ui
import "Model.js" as Model

// The bar icon for the flight tracker, and the host for its popup.
//
// Always the one solid plane. While anything is tracked it sends out echoes
// of itself: a copy of the plane that grows and fades, so the pulse is in the
// plane's own shape rather than a generic ring. Slow and calm between polls,
// quick while a request is actually out. The echo takes the urgent color when
// the flight the bar speaks for (Model.focusFlight) is late, canceled, or
// diverted; canceled and diverted turn the plane itself urgent too.
//
// Icons are Font Awesome 7 Pro when the person has a copy (see `iconFont`).
// With Pro Regular beside it the echo is the plane's outline, which reads as
// a plane-shaped ripple; without it the echo is a faint solid copy.
//
// Everything stateful lives in Service.qml, once per session; this widget is
// mounted once per monitor and only reads it.
BarWidget {
  id: root
  moduleName: "evansbee.flights"

  // ---- Settings (see manifest.json for the defaults these mirror).
  readonly property bool animate: setting("animate", true) !== false
  readonly property real dropAfterHours: Number(setting("dropAfterHours", 3))
  readonly property int changeMinutes: Number(setting("changeMinutes", 10)) || 10
  readonly property string iconFontPath: {
    var path = String(setting("iconFont", "~/Resources/fontawesome_font/otfs/Font Awesome 7 Pro-Solid-900.otf"))
    return path.indexOf("~/") === 0 ? Quickshell.env("HOME") + path.slice(1) : path
  }
  // The outline face sits next to the solid one in a Font Awesome download.
  readonly property string outlineFontPath: iconFontPath.replace("Solid-900", "Regular-400")

  // ---- Icon font. The Pro font is licensed to the person, so it is read from
  //      their disk at runtime and never shipped with the plugin.
  FontLoader {
    id: proFont
    source: root.iconFontPath !== "" ? "file://" + root.iconFontPath : ""
  }

  FontLoader {
    id: proOutlineFont
    source: root.outlineFontPath !== "" && root.outlineFontPath !== root.iconFontPath
      ? "file://" + root.outlineFontPath : ""
  }

  readonly property bool freeInstalled: Qt.fontFamilies().indexOf("Font Awesome 7 Free") !== -1
  readonly property string iconTier: proFont.status === FontLoader.Ready ? "pro"
    : (freeInstalled ? "free" : "nerd")
  readonly property string iconFamily: iconTier === "pro" ? proFont.name
    : (iconTier === "free" ? "Font Awesome 7 Free" : (bar ? bar.fontFamily : Style.font.family))
  // Both Font Awesome files are the Solid (900) face; the Free family also has
  // a 400 face that lacks most of these icons, so the weight must be asked for.
  readonly property int iconWeight: iconTier === "nerd" ? Font.Normal : Font.Black
  // Pro Regular is the same family at 400; with it loaded the empty plane can
  // be a real outline.
  readonly property bool hasOutline: iconTier === "pro" && proOutlineFont.status === FontLoader.Ready

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
  readonly property bool alert: Model.barAlert(focusFlight)
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
      ? Model.tooltip(root.flights, root.service.now, root.service.lastError)
      : "Flights · starting…"

    onPressed: function(b) {
      if (b === Qt.MiddleButton) { if (root.service) root.service.refreshAll() }
      else root.togglePanel()
    }

    // A custom icon rather than `text`, so the plane can have echoes behind
    // it. `text` stays set so the button still knows it has content.
    iconComponent: Component {
      Item {
        id: iconItem
        anchors.fill: parent

        readonly property bool alive: root.tracking && root.animate
        readonly property color ink: root.trouble ? button.activeColor : button.foreground
        readonly property color echoInk: root.alert ? button.activeColor : button.foreground
        readonly property int glyphSize: Math.round(button.fontSize * (root.iconTier === "nerd" ? 1 : 0.86))

        // Two echoes half a beat apart, so a quick pulse reads as a ripple.
        Repeater {
          model: 2

          Text {
            id: echo
            required property int index
            anchors.centerIn: parent
            textFormat: Text.PlainText
            text: root.glyph
            color: iconItem.echoInk
            font.family: root.iconFamily
            font.weight: root.hasOutline ? Font.Normal : root.iconWeight
            font.pixelSize: iconItem.glyphSize
            // Distance-field rendering, unlike the native hinting the plane
            // uses, stays smooth while it scales.
            renderType: Text.QtRendering
            rotation: iconItem.turn
            opacity: 0
            scale: 1
            visible: iconItem.alive

            readonly property int gap: root.fetching ? 120 : 2600

            SequentialAnimation {
              running: iconItem.alive
              loops: Animation.Infinite
              PauseAnimation { duration: echo.index * (root.fetching ? 300 : 650) }
              ParallelAnimation {
                NumberAnimation { target: echo; property: "scale"; from: 1; to: 1.9; duration: 1250; easing.type: Easing.OutCubic }
                NumberAnimation { target: echo; property: "opacity"; from: root.hasOutline ? 0.7 : 0.45; to: 0; duration: 1250; easing.type: Easing.InQuad }
              }
              PauseAnimation { duration: echo.gap - echo.index * (root.fetching ? 0 : 650) }
              onRunningChanged: if (!running) { echo.opacity = 0; echo.scale = 1 }
            }
          }
        }

        readonly property real turn: Model.flyingRotation(root.iconTier)

        Text {
          anchors.centerIn: parent
          textFormat: Text.PlainText
          text: root.glyph
          color: iconItem.ink
          font.family: root.iconFamily
          font.weight: root.iconWeight
          font.pixelSize: iconItem.glyphSize
          renderType: Text.NativeRendering
          rotation: iconItem.turn
        }
      }
    }
  }
}
