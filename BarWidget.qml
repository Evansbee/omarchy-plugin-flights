import QtQuick
import Quickshell
import qs.Commons
import qs.Ui
import "Model.js" as Model

// The bar icon for the flight tracker, and the host for its popup.
//
// Always the one plane, speaking for the most interesting flight on the list
// (Model.focusFlight), and it says two things:
//
//   The fill is where that flight is. An outline until it leaves, a solid fill
//   sweeping tail to nose across the flight, solid once it's down. "Leaves in
//   two hours" and "halfway to Singapore" read differently at a glance
//   without a second icon.
//
//   The dot at its lower right is the tracker itself. It breathes slowly while
//   anything is tracked, flickers while a request is actually out, and turns
//   the urgent color when the flight is late, canceled, or diverted.
//
// Icons are Font Awesome 7 Pro when the person has a copy (see `iconFont`):
// the outline is Pro Regular and the fill Pro Solid. Without Pro the outline
// is a faint solid plane instead — the Free set has no outline plane.
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
  readonly property real now: service ? service.now : 0
  readonly property real fill: Model.barFill(focusFlight, now)
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

    // A custom icon rather than `text`: the plane is drawn twice (outline,
    // then the solid fill clipped to the flight's progress) with the status dot
    // on top. `text` stays set so the button still knows it has content.
    iconComponent: Component {
      Item {
        id: iconItem
        anchors.fill: parent

        readonly property color ink: root.trouble ? button.activeColor : button.foreground
        readonly property int glyphSize: Math.round(button.fontSize * (root.iconTier === "nerd" ? 1 : 0.86))
        // The Nerd plane points up-right; turned, it flies left to right like
        // the fill does.
        readonly property real turn: Model.flyingRotation(root.iconTier)

        // Where the glyph's ink actually is inside its text box, so the fill
        // runs tail to nose rather than across the advance width.
        TextMetrics {
          id: inkMetrics
          font: solidPlane.font
          text: root.glyph
        }
        readonly property real inkLeft: inkMetrics.tightBoundingRect.x
        readonly property real inkWidth: inkMetrics.tightBoundingRect.width
        readonly property real inkRight: planeBox.x + inkLeft + inkWidth
        readonly property real inkBottom: planeBox.y + emptyPlane.baselineOffset
          + inkMetrics.tightBoundingRect.y + inkMetrics.tightBoundingRect.height

        Item {
          id: planeBox
          anchors.centerIn: parent
          width: emptyPlane.implicitWidth
          height: emptyPlane.implicitHeight
          rotation: iconItem.turn

          // The empty plane: a true outline with Pro, else a faint silhouette.
          Text {
            id: emptyPlane
            textFormat: Text.PlainText
            text: root.glyph
            color: root.hasOutline ? iconItem.ink
              : Qt.rgba(iconItem.ink.r, iconItem.ink.g, iconItem.ink.b, iconItem.ink.a * 0.38)
            font.family: root.iconFamily
            font.weight: root.hasOutline ? Font.Normal : root.iconWeight
            font.pixelSize: iconItem.glyphSize
            renderType: Text.NativeRendering
          }

          // The fill, clipped from the tail.
          Item {
            height: parent.height
            width: root.fill <= 0 ? 0
              : (root.fill >= 1 ? parent.width : iconItem.inkLeft + iconItem.inkWidth * root.fill)
            clip: true

            Behavior on width { NumberAnimation { duration: 700; easing.type: Easing.OutCubic } }

            Text {
              id: solidPlane
              textFormat: Text.PlainText
              text: root.glyph
              color: iconItem.ink
              font.family: root.iconFamily
              font.weight: root.iconWeight
              font.pixelSize: iconItem.glyphSize
              renderType: Text.NativeRendering
            }
          }
        }

        // The status dot, tucked into the empty corner under the nose.
        Rectangle {
          id: dot
          readonly property int size: Math.max(4, Math.round(iconItem.glyphSize * 0.3))
          visible: root.tracking
          width: size
          height: size
          radius: size / 2
          x: Math.round(iconItem.inkRight - size * 0.75)
          y: Math.round(iconItem.inkBottom - size * 0.95)
          color: root.alert ? button.activeColor : button.foreground

          // Breathing between polls...
          SequentialAnimation on opacity {
            running: root.tracking && root.animate && !root.fetching
            loops: Animation.Infinite
            NumberAnimation { to: 0.2; duration: 1100; easing.type: Easing.InOutSine }
            NumberAnimation { to: 1; duration: 1100; easing.type: Easing.InOutSine }
          }

          // ...and a quick flicker while a request is out.
          SequentialAnimation on opacity {
            running: root.tracking && root.animate && root.fetching
            loops: Animation.Infinite
            NumberAnimation { to: 0.15; duration: 140 }
            NumberAnimation { to: 1; duration: 140 }
          }

          Connections {
            target: root
            function onAnimateChanged() { if (!root.animate) dot.opacity = 1 }
          }
        }
      }
    }
  }
}
