import QtQuick
import Quickshell
import qs.Commons
import qs.Ui
import "Model.js" as Model

// The bar icon for the flight tracker, and the host for its popup.
//
// One icon, chosen by the most interesting flight on the list: an alert for a
// cancellation or diversion, the plane while one is in the air, departure
// while one is at the gate or taxiing, arrival once one is down, and an
// airline ticket while everything is still on the timetable.
//
// Icons are Font Awesome 7 Pro when the person has a copy (see `iconFont`),
// else the Free set Omarchy installs, else the bar's Nerd Font — Model.ICONS.
//
// While anything is being tracked the glyph is alive: it bobs gently, and a
// radar ring pings out from behind it — slowly between polls, quickly while a
// request is actually in flight — so a glance at the bar says "still looking".
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
  readonly property string phase: Model.bestPhase(flights)
  readonly property bool trouble: phase === "canceled" || phase === "diverted"
  readonly property string glyph: iconFor(Model.barIcon(flights))

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

    // A custom icon rather than `text`, so the glyph can move and can be
    // drawn in the icon font at the weight it needs. `text` stays set so the
    // button still knows it has content.
    iconComponent: Component {
      Item {
        id: iconItem
        anchors.fill: parent

        readonly property bool alive: root.tracking && root.animate
        readonly property color ink: root.trouble ? button.activeColor : button.foreground

        // Radar ping: a ring that grows out from the plane and fades. Two of
        // them, half a beat apart, so a fast ping reads as a sweep.
        Repeater {
          model: 2

          Rectangle {
            id: ring
            required property int index
            anchors.centerIn: parent
            width: iconItem.width
            height: width
            radius: width / 2
            color: "transparent"
            border.width: 1
            border.color: iconItem.ink
            opacity: 0
            scale: 0.3
            visible: iconItem.alive

            SequentialAnimation {
              running: iconItem.alive
              loops: Animation.Infinite
              PauseAnimation { duration: ring.index * (root.fetching ? 350 : 1100) }
              ParallelAnimation {
                NumberAnimation { target: ring; property: "scale"; from: 0.3; to: 1.35; duration: 1300; easing.type: Easing.OutCubic }
                NumberAnimation { target: ring; property: "opacity"; from: 0.55; to: 0; duration: 1300; easing.type: Easing.InQuad }
              }
              // Slow and calm between polls; quick while a request is out.
              PauseAnimation { duration: root.fetching ? 100 : 2400 - ring.index * 1100 }
              onRunningChanged: if (!running) { ring.opacity = 0; ring.scale = 0.3 }
            }
          }
        }

        Text {
          id: plane
          anchors.centerIn: parent
          textFormat: Text.PlainText
          text: root.glyph
          color: iconItem.ink
          font.family: root.iconFamily
          font.weight: root.iconWeight
          // Font Awesome draws larger than the Nerd glyphs at one pixel size.
          font.pixelSize: Math.round(button.fontSize * (root.iconTier === "nerd" ? 1 : 0.86))
          renderType: Text.NativeRendering

          // The bob. A pixel and a half each way is enough to read as motion
          // at a glance without making the bar feel busy.
          property real bob: 0
          transform: Translate { y: plane.bob }

          SequentialAnimation on bob {
            running: iconItem.alive
            loops: Animation.Infinite
            NumberAnimation { from: 0; to: -1.5; duration: 900; easing.type: Easing.InOutSine }
            NumberAnimation { from: -1.5; to: 1.5; duration: 1800; easing.type: Easing.InOutSine }
            NumberAnimation { from: 1.5; to: 0; duration: 900; easing.type: Easing.InOutSine }
            onRunningChanged: if (!running) plane.bob = 0
          }
        }
      }
    }
  }
}
