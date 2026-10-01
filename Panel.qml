import QtQuick
import qs.Commons
import qs.Ui
import "Model.js" as Model

// The flights popup: a box to type a flight number into, the question that
// comes back when a number flies more than one route, the notification
// switch, and one card per tracked flight.
//
// The box has focus the moment the panel opens, so the whole interaction can
// be "click the plane, type UA1, Enter". Down arrow leaves the box for the
// list below; Up from the top of the list goes back.
//
// BarWidget.qml finds the service and hands this panel the button to anchor
// to; everything rendered here is read straight off the service.
Panel {
  id: root
  moduleName: "evansbee.flights"

  property var anchorItem: null

  // The bar tracks the widget mounted in its slot — BarWidget.qml — not this
  // nested panel, so everything the bar identifies a panel by has to be that
  // widget.
  property var hostWidget: null
  readonly property var barIdentity: hostWidget || root

  readonly property var service: hostWidget ? hostWidget.service : null
  readonly property var flights: service ? service.sortedFlights : []
  readonly property var plans: service ? service.plans : []
  readonly property var options: service ? service.lookupOptions : []
  readonly property bool choosing: options.length > 0
  readonly property real now: service ? service.now : Date.now() / 1000

  readonly property color contentForeground: bar ? bar.foreground : Color.foreground
  readonly property color urgentColor: bar ? bar.urgent : Color.urgent
  readonly property color accentColor: Color.accent
  readonly property string contentFontFamily: bar ? bar.fontFamily : Style.font.family
  readonly property color dimColor: Qt.darker(contentForeground, 1.45)
  readonly property color faintColor: Qt.darker(contentForeground, 1.7)

  readonly property string iconTier: hostWidget ? hostWidget.iconTier : "nerd"
  readonly property string iconFamily: hostWidget ? hostWidget.iconFamily : contentFontFamily
  readonly property int iconWeight: hostWidget ? hostWidget.iconWeight : Font.Normal
  function iconFor(name) { return Model.icon(name, root.iconTier) }

  // ---- Cursor over whichever list is showing: the legs being chosen
  //      between, or the tracked flights followed by the upcoming ones.
  readonly property int rowCount: choosing ? options.length : flights.length + plans.length
  property int selectedIndex: -1

  function focusField() {
    root.selectedIndex = -1
    queryField.forceActiveFocus()
  }

  function focusList() {
    if (root.rowCount === 0) return
    root.selectedIndex = 0
    keyCatcher.forceActiveFocus()
  }

  function moveCursor(delta) {
    if (root.rowCount === 0) return
    var next = root.selectedIndex + delta
    if (next < 0) { focusField(); return }
    root.selectedIndex = Math.min(next, root.rowCount - 1)
  }

  function activateCursor() {
    if (root.choosing) choose(root.selectedIndex)
  }

  function deleteCursor() {
    if (root.choosing || root.selectedIndex < 0 || root.selectedIndex >= root.rowCount) return
    var i = root.selectedIndex
    if (i < root.flights.length) removeFlight(root.flights[i].key)
    else if (root.service) root.service.removePlan(root.plans[i - root.flights.length].key)
    // rowCount has already dropped by one.
    if (root.selectedIndex >= root.rowCount) root.selectedIndex = root.rowCount - 1
    if (root.selectedIndex < 0) focusField()
  }

  // ---- Naming a flight in place: click its name, or `e` on the cursor row.
  property string editingKey: ""

  function startRename(key) {
    root.editingKey = key
  }

  function commitRename(key, text) {
    if (root.editingKey !== key) return
    root.editingKey = ""
    if (root.service) root.service.renameFlight(key, text)
    keyCatcher.forceActiveFocus()
  }

  function cancelRename() {
    root.editingKey = ""
    keyCatcher.forceActiveFocus()
  }

  function renameCursor() {
    var i = root.selectedIndex
    if (root.choosing || i < 0 || i >= root.rowCount) return
    startRename(i < root.flights.length ? root.flights[i].key : root.plans[i - root.flights.length].key)
  }

  function submit() {
    if (!root.service) return
    if (root.service.lookup(queryField.text)) queryField.selectAll()
  }

  function choose(index) {
    if (!root.service) return
    root.service.chooseOption(index)
    queryField.text = ""
    focusField()
  }

  function removeFlight(key) {
    if (root.service) root.service.removeFlight(key)
  }

  function dismiss() {
    if (root.choosing && root.service) { root.service.cancelLookup(); focusField(); return }
    root.close()
  }

  // Delays and trouble in the urgent color; motion in the accent.
  function phaseColor(flight) {
    if (Model.isTroublePhase(flight.phase)) return root.urgentColor
    if (Model.isActivePhase(flight.phase)) return root.accentColor
    if (flight.phase !== "landed" && Model.delayMinutes(flight.row) >= 15) return root.urgentColor
    return root.dimColor
  }

  onOpenedChanged: {
    // A question left open when the panel closes would be waiting, stale,
    // the next time the plane is clicked.
    if (!opened) {
      root.editingKey = ""
      // A half-typed query from last time is never what the next click on
      // the plane is for.
      if (!(root.service && root.service.lookupBusy)) queryField.text = ""
      if (root.choosing && root.service) root.service.cancelLookup()
      return
    }
    if (root.service) {
      root.service.lookupNotice = ""
      if (!root.choosing) root.service.lookupError = ""
    }
    Qt.callLater(root.focusField)
  }

  KeyboardPanel {
    id: panel
    anchorItem: root.anchorItem
    owner: root.barIdentity
    bar: root.bar
    open: root.opened
    focusTarget: queryField
    contentWidth: panel.fittedContentWidth(Style.space(440))
    contentHeight: panel.fittedContentHeight(content.implicitHeight)

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      blocked: queryField.activeFocus || root.editingKey !== ""
      onMoveRequested: function(dx, dy) { if (dy !== 0) root.moveCursor(dy) }
      onActivateRequested: root.activateCursor()
      onDeleteRequested: root.deleteCursor()
      onCloseRequested: root.dismiss()
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onTextKey: function(t) {
        if (t === "/" || t === "a" || t === "i") root.focusField()
        else if (t === "r" && root.service) root.service.refreshAll()
        else if (t === "e") root.renameCursor()
      }

      Flickable {
        id: scroll
        anchors.fill: parent
        contentWidth: width
        contentHeight: content.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        interactive: contentHeight > height

        Column {
          id: content
          width: scroll.width
          spacing: Style.spacing.lg

          // ---- Header: the title and the notification switch.
          Item {
            width: parent.width
            height: Math.max(titleRow.implicitHeight, notifySwitch.height)

            Row {
              id: titleRow
              anchors.left: parent.left
              anchors.verticalCenter: parent.verticalCenter
              spacing: Style.spacing.md

              Text {
                anchors.verticalCenter: parent.verticalCenter
                textFormat: Text.PlainText
                text: root.iconFor("flying")
                rotation: Model.flyingRotation(root.iconTier)
                color: root.accentColor
                font.family: root.iconFamily
                font.weight: root.iconWeight
                font.pixelSize: Style.font.title
              }

              Text {
                anchors.verticalCenter: parent.verticalCenter
                textFormat: Text.PlainText
                text: "Flights"
                color: root.contentForeground
                font.family: root.contentFontFamily
                font.pixelSize: Style.font.title
                font.bold: true
              }
            }

            Row {
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              spacing: Style.spacing.sm

              Text {
                anchors.verticalCenter: parent.verticalCenter
                textFormat: Text.PlainText
                text: root.iconFor(root.service && root.service.notifications ? "bell" : "bellOff")
                color: root.service && root.service.notifications ? root.contentForeground : root.faintColor
                font.family: root.iconFamily
                font.weight: root.iconWeight
                font.pixelSize: Style.font.bodySmall
              }

              Text {
                anchors.verticalCenter: parent.verticalCenter
                textFormat: Text.PlainText
                text: "Notify on changes"

                HoverHandler { id: notifyHover }

                PanelToolTip {
                  visible: notifyHover.hovered
                  text: "Departure or arrival time moving " + (root.service ? root.service.changeMinutes : 5)
                    + "+ min, gate changes, taxi, takeoff, landing, cancellations, diversions"
                  fontFamily: root.contentFontFamily
                }
                color: root.dimColor
                font.family: root.contentFontFamily
                font.pixelSize: Style.font.bodySmall
              }

              ToggleSwitch {
                id: notifySwitch
                anchors.verticalCenter: parent.verticalCenter
                foreground: root.contentForeground
                accent: root.accentColor
                checked: root.service ? root.service.notifications : false
                onToggled: if (root.service) root.service.setNotifications(!root.service.notifications)
              }
            }
          }

          // ---- The box.
          Item {
            width: parent.width
            height: queryField.implicitHeight

            TextField {
              id: queryField
              anchors.left: parent.left
              anchors.right: goButton.left
              anchors.rightMargin: Style.spacing.md
              placeholderText: "UA1 · WN302 AUS · DL1 Dec 15 \"Mom's flight home\""
              foreground: root.contentForeground
              accent: root.accentColor
              font.family: root.contentFontFamily

              Keys.onPressed: function(event) {
                if (event.key === Qt.Key_Escape) {
                  root.dismiss()
                  event.accepted = true
                } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
                  root.submit()
                  event.accepted = true
                } else if (event.key === Qt.Key_Down) {
                  root.focusList()
                  event.accepted = true
                } else if (event.key === Qt.Key_Tab || event.key === Qt.Key_Backtab) {
                  root.switchPanel(event.key === Qt.Key_Backtab ? -1 : 1)
                  event.accepted = true
                }
              }
            }

            PanelActionButton {
              id: goButton
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              size: queryField.implicitHeight
              bordered: true
              iconText: root.service && root.service.lookupBusy ? root.iconFor("radar") : root.iconFor("search")
              fontFamily: root.iconFamily
              fontSize: Style.font.body
              foreground: root.contentForeground
              hoverColor: root.accentColor
              tooltipText: "Look up"
              onClicked: root.submit()

              // The radar sweeps while a lookup is out.
              RotationAnimator on rotation {
                running: root.service ? root.service.lookupBusy : false
                from: 0; to: 360; duration: 1100
                loops: Animation.Infinite
                onRunningChanged: if (!running) goButton.rotation = 0
              }
            }
          }

          // Whatever the last lookup has to say, else how to phrase one.
          Text {
            width: parent.width
            textFormat: Text.PlainText
            wrapMode: Text.WordWrap
            readonly property string error: root.service ? root.service.lookupError : ""
            readonly property string notice: root.service ? root.service.lookupNotice : ""
            text: error !== "" ? error
              : (notice !== "" ? notice
              : (root.service && root.service.lookupBusy ? "Looking it up…"
              : "Enter tracks the next departure, or the one in the air now. Add an airport to pick a leg, or a date, even weeks out, to watch a later flight."))
            color: error !== "" ? root.urgentColor : (notice !== "" ? root.accentColor : root.faintColor)
            font.family: root.contentFontFamily
            font.pixelSize: Style.font.caption
          }

          // ---- Which one? Only while a lookup came back with several legs.
          Column {
            visible: root.choosing
            width: parent.width
            spacing: Style.spacing.sm

            PanelSectionHeader {
              text: (root.options.length > 0 ? root.options[0].number : "") + " flies more than one route — which one?"
              foreground: root.contentForeground
              fontFamily: root.contentFontFamily
            }

            Repeater {
              model: root.choosing ? root.options : []

              CursorSurface {
                id: option
                required property var modelData
                required property int index

                width: content.width
                height: optionColumn.implicitHeight + Style.spacing.md * 2
                foreground: root.contentForeground
                accent: root.accentColor
                hasCursor: root.selectedIndex === option.index

                MouseArea {
                  anchors.fill: parent
                  hoverEnabled: true
                  cursorShape: Qt.PointingHandCursor
                  onEntered: root.selectedIndex = option.index
                  onClicked: root.choose(option.index)
                }

                Column {
                  id: optionColumn
                  anchors.left: parent.left
                  anchors.right: parent.right
                  anchors.verticalCenter: parent.verticalCenter
                  anchors.leftMargin: Style.spacing.rowPaddingX
                  anchors.rightMargin: Style.spacing.rowPaddingX
                  spacing: Style.spacing.xs

                  Text {
                    textFormat: Text.PlainText
                    text: Model.optionLabel(option.modelData)
                      + "   " + option.modelData.origin.city + " to " + option.modelData.destination.city
                    color: root.contentForeground
                    font.family: root.contentFontFamily
                    font.pixelSize: Style.font.body
                    font.bold: true
                    elide: Text.ElideRight
                    width: parent.width
                  }

                  Text {
                    textFormat: Text.PlainText
                    text: Model.optionDetail(option.modelData, root.now)
                    color: root.dimColor
                    font.family: root.contentFontFamily
                    font.pixelSize: Style.font.bodySmall
                  }
                }
              }
            }
          }

          PanelSeparator { foreground: root.contentForeground }

          // ---- The flights.
          Repeater {
            model: root.choosing ? [] : root.flights

            CursorSurface {
              id: card
              required property var modelData
              required property int index

              readonly property var flight: modelData
              readonly property var row: modelData.row
              readonly property color tone: root.phaseColor(modelData)
              readonly property int lateDep: Model.delayMinutes(row)
              readonly property int lateArr: Model.arrivalDelayMinutes(row)

              width: content.width
              height: cardColumn.implicitHeight + Style.spacing.lg * 2
              foreground: root.contentForeground
              accent: root.accentColor
              hasCursor: root.selectedIndex === card.index

              MouseArea {
                id: cardMouse
                anchors.fill: parent
                hoverEnabled: true
                onEntered: if (!queryField.activeFocus) root.selectedIndex = card.index
              }

              Column {
                id: cardColumn
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                anchors.leftMargin: Style.spacing.rowPaddingX
                anchors.rightMargin: Style.spacing.rowPaddingX
                spacing: Style.spacing.md

                // Name (or number), the details, and the phase on the right.
                // Clicking the name renames it in place.
                Item {
                  id: cardHeader
                  width: parent.width
                  height: Math.max(numberText.implicitHeight, removeButton.height,
                                   cardTitleField.visible ? cardTitleField.implicitHeight : 0)
                  readonly property real leftWidth: width - phaseRow.width - Style.spacing.lg

                  Row {
                    anchors.left: parent.left
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: Style.spacing.md
                    visible: !cardTitleField.visible

                    Text {
                      id: numberText
                      width: Math.min(implicitWidth, cardHeader.leftWidth)
                      elide: Text.ElideRight
                      textFormat: Text.PlainText
                      text: card.flight.title || card.row.number
                      color: root.contentForeground
                      font.family: root.contentFontFamily
                      font.pixelSize: Style.font.body
                      font.bold: true

                      MouseArea {
                        anchors.fill: parent
                        cursorShape: Qt.IBeamCursor
                        onClicked: root.startRename(card.flight.key)
                      }
                    }

                    Text {
                      anchors.baseline: numberText.baseline
                      width: Math.max(0, Math.min(implicitWidth, cardHeader.leftWidth - numberText.width - Style.spacing.md))
                      elide: Text.ElideRight
                      textFormat: Text.PlainText
                      text: (card.flight.title ? [card.row.number] : []).concat([card.row.airline, card.row.aircraft])
                        .filter(function(s) { return s }).join(" · ")
                      color: root.faintColor
                      font.family: root.contentFontFamily
                      font.pixelSize: Style.font.caption
                    }
                  }

                  TextField {
                    id: cardTitleField
                    visible: root.editingKey === card.flight.key
                    anchors.left: parent.left
                    anchors.verticalCenter: parent.verticalCenter
                    width: cardHeader.leftWidth
                    verticalPadding: Style.spacing.xs
                    placeholderText: "Name " + card.row.number + ", e.g. Elizabeth's flight home"
                    foreground: root.contentForeground
                    accent: root.accentColor
                    font.family: root.contentFontFamily
                    onVisibleChanged: if (visible) {
                      text = card.flight.title || ""
                      Qt.callLater(function() { cardTitleField.forceActiveFocus(); cardTitleField.selectAll() })
                    }
                    onActiveFocusChanged: if (!activeFocus && visible) root.commitRename(card.flight.key, text)
                    Keys.onPressed: function(event) {
                      if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
                        root.commitRename(card.flight.key, text); event.accepted = true
                      } else if (event.key === Qt.Key_Escape) {
                        root.cancelRename(); event.accepted = true
                      }
                    }
                  }

                  Row {
                    id: phaseRow
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: Style.spacing.md

                    Text {
                      anchors.verticalCenter: parent.verticalCenter
                      textFormat: Text.PlainText
                      text: Model.phaseLabel(card.flight.phase)
                      color: card.tone
                      font.family: root.contentFontFamily
                      font.pixelSize: Style.font.bodySmall
                      font.bold: true
                    }

                    PanelActionButton {
                      id: removeButton
                      anchors.verticalCenter: parent.verticalCenter
                      // Only under the pointer or cursor, so the list reads
                      // as information rather than a column of x's.
                      opacity: cardMouse.containsMouse || pointerOver || card.hasCursor ? 1 : 0
                      enabled: opacity > 0
                      property bool pointerOver: false
                      iconText: root.iconFor("remove")
                      fontFamily: root.iconFamily
                      fontSize: Style.font.caption
                      foreground: root.dimColor
                      hoverColor: root.urgentColor
                      tooltipText: "Stop tracking (x)"
                      onHovered: function(isHovered) { removeButton.pointerOver = isHovered }
                      onClicked: root.removeFlight(card.flight.key)
                    }
                  }
                }

                // The route, with the plane where the flight is.
                Item {
                  width: parent.width
                  height: Math.max(originCode.implicitHeight, planeMark.implicitHeight)

                  Text {
                    id: originCode
                    anchors.left: parent.left
                    anchors.verticalCenter: parent.verticalCenter
                    textFormat: Text.PlainText
                    text: card.row.origin.iata
                    color: root.contentForeground
                    font.family: root.contentFontFamily
                    font.pixelSize: Style.font.title
                    font.bold: true
                  }

                  Text {
                    id: destCode
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    textFormat: Text.PlainText
                    text: card.row.destination.iata
                    color: root.contentForeground
                    font.family: root.contentFontFamily
                    font.pixelSize: Style.font.title
                    font.bold: true
                  }

                  Item {
                    id: track
                    anchors.left: originCode.right
                    anchors.right: destCode.left
                    anchors.leftMargin: Style.spacing.lg
                    anchors.rightMargin: Style.spacing.lg
                    anchors.verticalCenter: parent.verticalCenter
                    height: planeMark.implicitHeight

                    readonly property real fraction: Model.progress(card.flight, root.now)

                    // Dotted ahead, solid behind: the part already flown.
                    Row {
                      anchors.verticalCenter: parent.verticalCenter
                      width: parent.width
                      spacing: Style.space(4)
                      clip: true
                      Repeater {
                        model: Math.max(0, Math.floor(track.width / Style.space(8)))
                        Rectangle {
                          width: Style.space(4)
                          height: Math.max(1, Style.space(2))
                          radius: height / 2
                          color: root.faintColor
                          anchors.verticalCenter: parent.verticalCenter
                        }
                      }
                    }

                    Rectangle {
                      anchors.verticalCenter: parent.verticalCenter
                      width: track.width * track.fraction
                      height: Math.max(1, Style.space(2))
                      radius: height / 2
                      color: card.tone
                      Behavior on width { NumberAnimation { duration: 600; easing.type: Easing.OutCubic } }
                    }

                    Text {
                      id: planeMark
                      textFormat: Text.PlainText
                      anchors.verticalCenter: parent.verticalCenter
                      x: Math.max(0, Math.min(track.width - width, track.width * track.fraction - width / 2))
                      text: root.iconFor(Model.isTroublePhase(card.flight.phase) ? (card.flight.phase === "canceled" ? "canceled" : "alert") : "flying")
                      rotation: Model.isTroublePhase(card.flight.phase) ? 0 : Model.flyingRotation(root.iconTier)
                      color: Model.isActivePhase(card.flight.phase) || Model.isTroublePhase(card.flight.phase) ? card.tone : root.contentForeground
                      font.family: root.iconFamily
                      font.weight: root.iconWeight
                      font.pixelSize: Style.font.body

                      Behavior on x { NumberAnimation { duration: 600; easing.type: Easing.OutCubic } }
                    }
                  }
                }

                // How long: the whole flight before it leaves, what's left
                // while it's up, what it took once down. Centered under the
                // line, where the plane never runs into it.
                Text {
                  visible: text !== ""
                  width: parent.width
                  topPadding: -Style.spacing.sm
                  horizontalAlignment: Text.AlignHCenter
                  textFormat: Text.PlainText
                  text: Model.durationLabel(card.flight, root.now)
                  color: card.flight.phase === "airborne" ? card.tone : root.dimColor
                  font.family: root.contentFontFamily
                  font.pixelSize: Style.font.caption
                }

                // Departure on the left, arrival on the right, in each
                // airport's own time. A changed time shows the timetable one
                // struck through beside it.
                Item {
                  width: parent.width
                  height: Math.max(depColumn.implicitHeight, arrColumn.implicitHeight)

                  Column {
                    id: depColumn
                    anchors.left: parent.left
                    spacing: Style.spacing.xs

                    Row {
                      spacing: Style.spacing.sm
                      Text {
                        textFormat: Text.PlainText
                        text: Model.clock(Model.departureTime(card.row), card.row.origin)
                        color: card.lateDep >= 15 && !card.row.realDep ? root.urgentColor : root.contentForeground
                        font.family: root.contentFontFamily
                        font.pixelSize: Style.font.body
                        font.bold: true
                      }
                      Text {
                        visible: Math.abs(card.lateDep) >= 5
                        textFormat: Text.PlainText
                        text: Model.clock(card.row.schedDep, card.row.origin)
                        font.strikeout: true
                        color: root.faintColor
                        font.family: root.contentFontFamily
                        font.pixelSize: Style.font.bodySmall
                        anchors.bottom: parent.bottom
                      }
                    }

                    Text {
                      textFormat: Text.PlainText
                      text: (card.row.realDep ? "Departed · " : "Departs · ")
                        + Model.dayLabel(Model.departureTime(card.row), card.row.origin, root.now)
                        + " " + card.row.origin.tzAbbr
                        + (card.row.origin.gate ? " · Gate " + card.row.origin.gate : "")
                      color: root.dimColor
                      font.family: root.contentFontFamily
                      font.pixelSize: Style.font.caption
                    }
                  }

                  Column {
                    id: arrColumn
                    anchors.right: parent.right
                    spacing: Style.spacing.xs

                    Row {
                      anchors.right: parent.right
                      spacing: Style.spacing.sm
                      Text {
                        visible: Math.abs(card.lateArr) >= 5
                        textFormat: Text.PlainText
                        text: Model.clock(card.row.schedArr, card.row.destination)
                        font.strikeout: true
                        color: root.faintColor
                        font.family: root.contentFontFamily
                        font.pixelSize: Style.font.bodySmall
                        anchors.bottom: parent.bottom
                      }
                      Text {
                        id: arrClock
                        textFormat: Text.PlainText
                        text: Model.clock(Model.arrivalTime(card.row), card.row.destination)
                        color: card.lateArr >= 15 && card.flight.phase !== "landed" ? root.urgentColor : root.contentForeground
                        font.family: root.contentFontFamily
                        font.pixelSize: Style.font.body
                        font.bold: true
                      }

                      // "+1": lands on a later calendar day than it left, each
                      // in its own airport's time. A filled pill in the theme
                      // accent, so it still stands out in a grayscale theme.
                      Rectangle {
                        readonly property string label: Model.dayShiftText(Model.dayShift(card.row))
                        visible: label !== ""
                        anchors.verticalCenter: arrClock.verticalCenter
                        width: shiftText.implicitWidth + Style.spacing.sm * 2
                        height: shiftText.implicitHeight
                        radius: Math.min(height / 2, Style.cornerRadius > 0 ? height / 2 : 2)
                        color: root.accentColor

                        Text {
                          id: shiftText
                          anchors.centerIn: parent
                          textFormat: Text.PlainText
                          text: parent.label
                          color: Color.popups.background
                          font.family: root.contentFontFamily
                          font.pixelSize: Style.font.caption
                          font.bold: true
                        }
                      }
                    }

                    Text {
                      anchors.right: parent.right
                      textFormat: Text.PlainText
                      text: (card.row.destination.gate ? "Gate " + card.row.destination.gate + " · " : "")
                        + Model.dayLabel(Model.arrivalTime(card.row), card.row.destination, root.now)
                        + " " + card.row.destination.tzAbbr
                        + (card.flight.phase === "landed" ? " · Landed"
                          : (Model.arrivalProjected(card.row) ? " · Projected" : " · Arrives"))
                      color: root.dimColor
                      font.family: root.contentFontFamily
                      font.pixelSize: Style.font.caption
                    }
                  }
                }

                // The sentence version, plus anything that went wrong.
                Text {
                  width: parent.width
                  textFormat: Text.PlainText
                  elide: Text.ElideRight
                  text: Model.statusLine(card.flight, root.now)
                    + (card.flight.error ? " · " + card.flight.error : "")
                  color: card.flight.error ? root.urgentColor : card.tone
                  font.family: root.contentFontFamily
                  font.pixelSize: Style.font.bodySmall
                }
              }
            }
          }

          // ---- Upcoming: flights too far out for the schedule yet.
          PanelSectionHeader {
            visible: !root.choosing && root.plans.length > 0
            text: "Upcoming"
            foreground: root.contentForeground
            fontFamily: root.contentFontFamily
          }

          Repeater {
            model: root.choosing ? [] : root.plans

            CursorSurface {
              id: planCard
              required property var modelData
              required property int index
              readonly property var plan: modelData
              readonly property int cursorIndex: root.flights.length + index
              readonly property var choices: modelData.choices || []

              width: content.width
              height: planColumn.implicitHeight + Style.spacing.lg * 2
              foreground: root.contentForeground
              accent: root.accentColor
              hasCursor: root.selectedIndex === planCard.cursorIndex

              MouseArea {
                id: planMouse
                anchors.fill: parent
                hoverEnabled: true
                onEntered: if (!queryField.activeFocus) root.selectedIndex = planCard.cursorIndex
              }

              Column {
                id: planColumn
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                anchors.leftMargin: Style.spacing.rowPaddingX
                anchors.rightMargin: Style.spacing.rowPaddingX
                spacing: Style.spacing.sm

                Item {
                  id: planHeader
                  width: parent.width
                  height: Math.max(planNumber.implicitHeight, planRemove.height,
                                   planTitleField.visible ? planTitleField.implicitHeight : 0)
                  readonly property real leftWidth: width - planRemove.width - Style.spacing.lg

                  Row {
                    anchors.left: parent.left
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: Style.spacing.md
                    visible: !planTitleField.visible

                    Text {
                      id: planNumber
                      width: Math.min(implicitWidth, planHeader.leftWidth)
                      elide: Text.ElideRight
                      textFormat: Text.PlainText
                      text: planCard.plan.title || planCard.plan.number
                      color: root.contentForeground
                      font.family: root.contentFontFamily
                      font.pixelSize: Style.font.body
                      font.bold: true

                      MouseArea {
                        anchors.fill: parent
                        cursorShape: Qt.IBeamCursor
                        onClicked: root.startRename(planCard.plan.key)
                      }
                    }

                    Text {
                      anchors.baseline: planNumber.baseline
                      width: Math.max(0, Math.min(implicitWidth, planHeader.leftWidth - planNumber.width - Style.spacing.md))
                      elide: Text.ElideRight
                      textFormat: Text.PlainText
                      text: (planCard.plan.title ? planCard.plan.number + " · " : "")
                        + Model.dateText(planCard.plan.date) + " · " + Model.planRouteText(planCard.plan)
                      color: root.contentForeground
                      font.family: root.contentFontFamily
                      font.pixelSize: Style.font.bodySmall
                    }
                  }

                  TextField {
                    id: planTitleField
                    visible: root.editingKey === planCard.plan.key
                    anchors.left: parent.left
                    anchors.verticalCenter: parent.verticalCenter
                    width: planHeader.leftWidth
                    verticalPadding: Style.spacing.xs
                    placeholderText: "Name " + planCard.plan.number + ", e.g. Elizabeth's flight home"
                    foreground: root.contentForeground
                    accent: root.accentColor
                    font.family: root.contentFontFamily
                    onVisibleChanged: if (visible) {
                      text = planCard.plan.title || ""
                      Qt.callLater(function() { planTitleField.forceActiveFocus(); planTitleField.selectAll() })
                    }
                    onActiveFocusChanged: if (!activeFocus && visible) root.commitRename(planCard.plan.key, text)
                    Keys.onPressed: function(event) {
                      if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
                        root.commitRename(planCard.plan.key, text); event.accepted = true
                      } else if (event.key === Qt.Key_Escape) {
                        root.cancelRename(); event.accepted = true
                      }
                    }
                  }

                  PanelActionButton {
                    id: planRemove
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    opacity: planMouse.containsMouse || pointerOver || planCard.hasCursor ? 1 : 0
                    enabled: opacity > 0
                    property bool pointerOver: false
                    iconText: root.iconFor("remove")
                    fontFamily: root.iconFamily
                    fontSize: Style.font.caption
                    foreground: root.dimColor
                    hoverColor: root.urgentColor
                    tooltipText: "Forget it (x)"
                    onHovered: function(isHovered) { planRemove.pointerOver = isHovered }
                    onClicked: if (root.service) root.service.removePlan(planCard.plan.key)
                  }
                }

                Text {
                  width: parent.width
                  wrapMode: Text.WordWrap
                  textFormat: Text.PlainText
                  text: Model.planStatus(planCard.plan, root.now) + (planCard.plan.error ? " · " + planCard.plan.error : "")
                  color: planCard.plan.error ? root.urgentColor : root.dimColor
                  font.family: root.contentFontFamily
                  font.pixelSize: Style.font.caption
                }

                // Its day turned out to fly more than one route.
                Repeater {
                  model: planCard.choices

                  CursorSurface {
                    id: planChoice
                    required property var modelData
                    required property int index
                    width: planColumn.width
                    height: planChoiceText.implicitHeight + Style.spacing.sm * 2
                    foreground: root.contentForeground
                    accent: root.accentColor
                    bordered: true

                    MouseArea {
                      anchors.fill: parent
                      cursorShape: Qt.PointingHandCursor
                      onClicked: if (root.service) root.service.choosePlanOption(planCard.plan.key, planChoice.index)
                    }

                    Text {
                      id: planChoiceText
                      anchors.verticalCenter: parent.verticalCenter
                      x: Style.spacing.md
                      textFormat: Text.PlainText
                      text: Model.optionLabel(planChoice.modelData) + " · " + Model.optionDetail(planChoice.modelData, root.now)
                      color: root.contentForeground
                      font.family: root.contentFontFamily
                      font.pixelSize: Style.font.bodySmall
                    }
                  }
                }
              }
            }
          }

          // ---- Nothing yet.
          Column {
            visible: !root.choosing && root.flights.length === 0 && root.plans.length === 0
            width: parent.width
            spacing: Style.spacing.md
            topPadding: Style.spacing.md
            bottomPadding: Style.spacing.md

            Text {
              anchors.horizontalCenter: parent.horizontalCenter
              textFormat: Text.PlainText
              text: root.iconFor("tower")
              color: root.faintColor
              font.family: root.iconFamily
              font.weight: root.iconWeight
              font.pixelSize: Style.space(32)
            }

            Text {
              anchors.horizontalCenter: parent.horizontalCenter
              textFormat: Text.PlainText
              text: root.service ? "No flights on the board" : "Waiting for the flight service…"
              color: root.dimColor
              font.family: root.contentFontFamily
              font.pixelSize: Style.font.bodySmall
            }
          }

          PanelSeparator { foreground: root.contentForeground }

          Text {
            width: parent.width
            textFormat: Text.PlainText
            horizontalAlignment: Text.AlignHCenter
            wrapMode: Text.WordWrap
            text: root.service && root.service.lastError !== ""
              ? root.service.lastError
              : "↓ to the list · e names a flight · x stops tracking · r refreshes · landed flights leave after "
                + (root.service ? root.service.dropAfterHours : 3) + "h"
            color: root.service && root.service.lastError !== "" ? root.urgentColor : root.faintColor
            font.family: root.contentFontFamily
            font.pixelSize: Style.font.caption
          }
        }
      }
    }
  }
}
