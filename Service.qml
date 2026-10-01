import QtQuick
import Quickshell
import Quickshell.Io
import "Model.js" as Model

// The flight tracker itself: the list of flights, the polling, the
// notifications, and the file they survive restarts in.
//
// A service rather than part of the bar widget because the bar mounts one
// widget per monitor, and a flight must be polled — and announced — once per
// session, not once per screen. The widgets and their panels are views onto
// this object; they find it with bar.shell.serviceFor().
//
// Data comes from Flightradar24's public web endpoints: the flight list for a
// number (every recent and upcoming departure, with times and status), and,
// once an aircraft is live, the per-flight detail (position, gates). Both are
// fetched with curl, one request at a time, at a cadence that tightens as the
// flight gets close (see Model.pollInterval).
Item {
  id: root

  // Injected by omarchy-shell's service loader.
  property var shell: null
  property var manifest: null
  property string omarchyPath: "/usr/share/omarchy"

  readonly property string home: Quickshell.env("HOME")
  readonly property string stateDir: home + "/.local/state/omarchy-flights"
  readonly property string statePath: stateDir + "/flights.json"
  // A file path rather than a theme icon name: the notification daemon's
  // icon theme has no airplane in it.
  readonly property string notifyIcon: Qt.resolvedUrl("icon.svg").toString().replace(/^file:\/\//, "")

  // ---- Settings, pushed in by the bar widget from its shell.json entry.
  property real dropAfterHours: 3
  property int changeMinutes: 10

  function applySettings(settings) {
    var s = settings || {}
    if (s.dropAfterHours !== undefined && isFinite(Number(s.dropAfterHours)))
      root.dropAfterHours = Math.max(0, Number(s.dropAfterHours))
    if (s.changeMinutes !== undefined && isFinite(Number(s.changeMinutes)))
      root.changeMinutes = Math.max(1, Math.round(Number(s.changeMinutes)))
  }

  // ---- State.
  property var flights: []
  // Flights too far out for Flightradar24's schedule yet; see Model "Planned".
  property var plans: []
  property bool notifications: true
  property bool stateLoaded: false

  // Seconds, advanced by a timer: a binding on Date.now() has no dependency on
  // the clock and would freeze at its first value.
  property real now: Date.now() / 1000

  readonly property var sortedFlights: Model.sortFlights(flights)
  readonly property bool tracking: flights.length > 0
  readonly property bool fetching: pollProc.running || lookupProc.running
  property string lastError: ""

  // FR24 throttles; after a refusal every poll waits until this time.
  property real backoffUntil: 0

  // ---- Lookup state the panel renders: typing, asking which leg, or failed.
  property bool lookupBusy: lookupProc.running
  property string lookupError: ""
  property string lookupNotice: ""
  property var lookupOptions: []
  property var pendingQuery: null

  function log(event, detail) {
    console.log("flights " + new Date().toISOString() + " " + event
      + (detail === undefined || detail === "" ? "" : ": " + String(detail)))
  }

  // ---- Persistence.
  function save() {
    if (!root.stateLoaded) return
    stateFile.setText(Model.serializeState({ notifications: root.notifications, flights: root.flights, plans: root.plans }))
  }

  function setFlights(list) {
    root.flights = list
    save()
  }

  function setPlans(list) {
    root.plans = list
    save()
  }

  function findPlan(key) {
    for (var i = 0; i < root.plans.length; i++) if (root.plans[i].key === key) return i
    return -1
  }

  function replacePlan(next) {
    var index = findPlan(next.key)
    if (index === -1) return
    var list = root.plans.slice()
    list[index] = next
    setPlans(list)
  }

  function removePlan(key) {
    var list = root.plans.filter(function(p) { return p.key !== key })
    if (list.length !== root.plans.length) {
      log("remove-plan", key)
      setPlans(list)
    }
  }

  function addPlan(query, rows) {
    var plan = Model.newPlan(query, rows, Date.now() / 1000)
    if (findPlan(plan.key) !== -1) {
      root.lookupNotice = "Already watching for " + plan.number + " on " + Model.dateText(plan.date)
      return
    }
    setPlans(root.plans.concat([plan]))
    root.lookupNotice = plan.number + " on " + Model.dateText(plan.date)
      + " is on your upcoming list. Tracking starts when the schedule is published."
    log("add-plan", plan.key)
  }

  // A leg picked on a plan's card once its day turned out to fly several.
  function choosePlanOption(key, index) {
    var at = findPlan(key)
    if (at === -1) return
    var choices = root.plans[at].choices || []
    if (index < 0 || index >= choices.length) return
    removePlan(key)
    addFlight(choices[index])
  }

  function setNotifications(on) {
    root.notifications = !!on
    save()
  }

  function findIndex(key) {
    for (var i = 0; i < root.flights.length; i++) if (root.flights[i].key === key) return i
    return -1
  }

  function replaceFlight(next) {
    var index = findIndex(next.key)
    if (index === -1) return
    var list = root.flights.slice()
    list[index] = next
    setFlights(list)
  }

  function removeFlight(key) {
    var list = []
    for (var i = 0; i < root.flights.length; i++) if (root.flights[i].key !== key) list.push(root.flights[i])
    if (list.length !== root.flights.length) {
      log("remove", key)
      setFlights(list)
    }
  }

  // ---- Lookup: text from the panel → a flight on the list, or a question.
  function lookup(text) {
    var query = Model.parseQuery(text, root.now)
    root.lookupOptions = []
    root.lookupNotice = ""
    if (!query.ok) {
      root.lookupError = query.error
      return false
    }
    if (lookupProc.running) return false
    root.lookupError = ""
    root.pendingQuery = query
    lookupProc.command = Model.curlArgv(Model.listUrl(query.number))
    lookupProc.running = true
    log("lookup", text)
    return true
  }

  function cancelLookup() {
    root.lookupOptions = []
    root.lookupError = ""
    root.pendingQuery = null
  }

  function applyLookup(raw) {
    var query = root.pendingQuery
    root.pendingQuery = null
    if (!query) return

    var response = Model.splitResponse(raw)
    if (response.status !== 200) {
      root.lookupError = Model.httpError(response.status)
      return
    }
    var rows = Model.parseList(response.body)
    if (rows === null) {
      root.lookupError = "Couldn't read Flightradar24's answer"
      return
    }

    var result = Model.resolve(rows, query, Date.now() / 1000)
    if (result.kind === "none" && Model.shouldPlan(query, rows, Date.now() / 1000)) addPlan(query, rows)
    else if (result.kind === "none") root.lookupError = result.message
    else if (result.kind === "choose") root.lookupOptions = result.options
    else addFlight(result.row)
  }

  function chooseOption(index) {
    var options = root.lookupOptions
    if (index < 0 || index >= options.length) return
    root.lookupOptions = []
    addFlight(options[index])
  }

  function addFlight(row) {
    var nowSec = Date.now() / 1000
    var tracked = Model.newTracked(row, nowSec)
    if (findIndex(tracked.key) !== -1) {
      root.lookupNotice = "Already tracking " + row.number + " " + row.origin.iata + "→" + row.destination.iata
      return
    }
    var list = root.flights.slice()
    list.push(tracked)
    setFlights(list)
    root.lookupNotice = "Tracking " + row.number + " " + row.origin.iata + "→" + row.destination.iata
    log("add", tracked.key)
    // Due immediately, so a live flight gets its position and gates now
    // instead of at the next tick.
    pollSoon.restart()
  }

  // ---- Polling. One request at a time; each tick picks the first flight
  //      that is due.
  property var polling: null   // { key, listRow }

  function pollNext() {
    if (pollProc.running || !root.stateLoaded) return
    var nowSec = Date.now() / 1000
    root.now = nowSec
    dropExpired(nowSec)
    if (nowSec < root.backoffUntil) return

    for (var i = 0; i < root.flights.length; i++) {
      var f = root.flights[i]
      if (!Model.isDue(f, nowSec)) continue
      root.polling = { key: f.key, number: f.number, stage: "list", listRow: null }
      startRequest(Model.listUrl(f.number))
      return
    }

    for (var j = 0; j < root.plans.length; j++) {
      var plan = root.plans[j]
      if (!Model.planDue(plan, nowSec)) continue
      root.polling = { key: plan.key, number: plan.number, stage: "plan" }
      startRequest(Model.listUrl(plan.number))
      return
    }
  }

  // A plan's day came back from the schedule: track it, ask which leg, or
  // keep waiting.
  function applyPlanResponse(job, response, nowSec) {
    root.polling = null
    var at = findPlan(job.key)
    if (at === -1) return
    var plan = {}
    for (var k in root.plans[at]) plan[k] = root.plans[at][k]
    plan.lastChecked = nowSec

    var rows = response.status === 200 ? Model.parseList(response.body) : null
    if (rows === null) {
      plan.error = Model.httpError(response.status)
      replacePlan(plan)
      return
    }
    plan.error = ""

    var result = Model.resolve(rows, Model.planQuery(plan), nowSec)
    if (result.kind === "single") {
      removePlan(plan.key)
      addFlight(result.row)
      root.lookupNotice = ""
      var row = result.row
      announce([{ title: row.number + " is on the schedule",
        body: "Now tracking " + row.origin.iata + " → " + row.destination.iata + " · departs "
          + Model.dayLabel(row.schedDep, row.origin, nowSec) + " " + Model.clock(row.schedDep, row.origin),
        urgency: "normal" }])
    } else if (result.kind === "choose") {
      plan.choices = result.options
      if (!plan.asked) {
        plan.asked = true
        announce([{ title: plan.number + " on " + Model.dateText(plan.date) + " flies " + result.options.length + " routes",
          body: "Open Flights to pick the one you're on", urgency: "normal" }])
      }
      replacePlan(plan)
    } else {
      plan.guess = Model.guessRoute(rows, plan.airports) || plan.guess
      replacePlan(plan)
    }
    pollSoon.restart()
  }

  function refreshAll() {
    var list = []
    for (var i = 0; i < root.flights.length; i++) {
      var f = {}
      for (var k in root.flights[i]) f[k] = root.flights[i][k]
      f.lastPolled = 0
      list.push(f)
    }
    root.flights = list
    root.backoffUntil = 0
    pollSoon.restart()
  }

  function startRequest(url) {
    pollProc.command = Model.curlArgv(url)
    pollProc.running = true
  }

  function applyPollResponse(raw) {
    var job = root.polling
    if (!job) return
    var index = findIndex(job.key)
    if (index === -1 && job.stage !== "plan") { root.polling = null; return }
    var nowSec = Date.now() / 1000
    var response = Model.splitResponse(raw)
    if (job.stage === "plan") { applyPlanResponse(job, response, nowSec); return }
    var tracked = root.flights[index]

    if (response.status !== 200) {
      root.polling = null
      root.lastError = Model.httpError(response.status)
      if (response.status === 403 || response.status === 429) root.backoffUntil = nowSec + 5 * 60
      log("poll-failed", job.key + " " + response.status)
      var failed = {}
      for (var k in tracked) failed[k] = tracked[k]
      failed.lastPolled = nowSec
      failed.error = root.lastError
      replaceFlight(failed)
      return
    }

    if (job.stage === "list") {
      var rows = Model.parseList(response.body)
      var listRow = Model.findRow(rows, tracked)
      if (rows !== null && !listRow) log("not-in-list", job.key)
      // Ask for the live detail once FR24 has an aircraft for this flight.
      var probe = {}
      for (var p in tracked) probe[p] = tracked[p]
      probe.row = listRow || tracked.row
      if (Model.wantsDetail(probe)) {
        root.polling = { key: job.key, number: job.number, stage: "detail", listRow: listRow }
        startRequest(Model.detailUrl(probe.row.id))
        return
      }
      finishPoll(tracked, listRow, null, nowSec)
      return
    }

    finishPoll(tracked, job.listRow, Model.parseDetail(response.body), nowSec)
  }

  function finishPoll(tracked, listRow, detail, nowSec) {
    root.polling = null
    root.lastError = ""
    var result = Model.applyPoll(tracked, listRow, detail, nowSec, root.changeMinutes)
    if (result.tracked.phase !== tracked.phase) log("phase", tracked.key + " " + tracked.phase + " → " + result.tracked.phase)
    replaceFlight(result.tracked)
    announce(result.events)
    // Another flight may be due right behind this one.
    pollSoon.restart()
  }

  function dropExpired(nowSec) {
    var keep = []
    for (var i = 0; i < root.flights.length; i++) {
      var f = root.flights[i]
      if (Model.isExpired(f, nowSec, root.dropAfterHours)) log("expire", f.key)
      else keep.push(f)
    }
    if (keep.length !== root.flights.length) setFlights(keep)

    var keepPlans = root.plans.filter(function(p) {
      var gone = Model.planExpired(p, nowSec)
      if (gone) root.log("expire-plan", p.key)
      return !gone
    })
    if (keepPlans.length !== root.plans.length) setPlans(keepPlans)
  }

  // ---- Notifications. Several changes from one poll become one bubble.
  function announce(events) {
    if (!events || events.length === 0) return
    for (var i = 0; i < events.length; i++) log("event", events[i].title + " — " + events[i].body)
    if (!root.notifications) return

    var urgency = "normal"
    var body = []
    for (var j = 0; j < events.length; j++) {
      if (events[j].urgency === "critical") urgency = "critical"
      body.push(j === 0 ? events[j].body : events[j].title + ": " + events[j].body)
    }
    Quickshell.execDetached(["notify-send", "--app-name=Flights", "--icon=" + root.notifyIcon,
                             "--urgency=" + urgency, events[0].title, body.join("\n")])
  }

  // ---- Timers and processes.
  Timer {
    // The heartbeat: advances `now` for countdowns and checks what's due.
    interval: 15000
    repeat: true
    running: root.stateLoaded
    triggeredOnStart: true
    onTriggered: root.pollNext()
  }

  Timer {
    id: pollSoon
    interval: 400
    repeat: false
    onTriggered: root.pollNext()
  }

  Process {
    id: pollProc
    running: false
    // Parsed from onStreamFinished, not onExited: the exit can be reported
    // before the collector has the last of stdout.
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.applyPollResponse(text)
    }
    onRunningChanged: if (running) pollWatchdog.restart()
    onExited: pollWatchdog.stop()
  }

  Timer {
    // A curl that never exits would leave pollProc.running set and silently
    // stop every later poll. curl's own -m 20 should prevent that; this is
    // the belt to it.
    id: pollWatchdog
    interval: 30000
    onTriggered: if (pollProc.running) { pollProc.running = false; root.polling = null }
  }

  Process {
    id: lookupProc
    running: false
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.applyLookup(text)
    }
  }

  Process {
    id: mkdirProc
    command: ["mkdir", "-p", root.stateDir]
    onExited: stateFile.path = root.statePath
  }

  FileView {
    id: stateFile
    // Path is set only once the directory exists, so the first load can't
    // race the mkdir.
    path: ""
    printErrors: false
    atomicWrites: true
    onLoaded: {
      var state = Model.parseState(text())
      root.notifications = state.notifications
      root.flights = state.flights
      root.plans = state.plans
      root.stateLoaded = true
      root.log("loaded", state.flights.length + " flight(s)")
    }
    onLoadFailed: function(error) {
      // No file yet: a fresh install. Start empty and write on first change.
      root.stateLoaded = true
      root.log("fresh-state", error)
    }
  }

  // `omarchy-shell flights <fn>` for debugging and scripting.
  IpcHandler {
    target: "flights"

    function status(): string {
      return JSON.stringify({
        notifications: root.notifications,
        fetching: root.fetching,
        lastError: root.lastError,
        backoffUntil: root.backoffUntil,
        plans: root.plans.map(function(p) {
          return { key: p.key, route: Model.planRouteText(p), status: Model.planStatus(p, Date.now() / 1000),
                   choices: (p.choices || []).length, error: p.error || "" }
        }),
        flights: root.sortedFlights.map(function(f) {
          return {
            key: f.key, phase: f.phase, status: Model.statusLine(f, Date.now() / 1000),
            departs: new Date(Model.departureTime(f.row) * 1000).toISOString(),
            arrives: new Date(Model.arrivalTime(f.row) * 1000).toISOString(),
            lastPolled: f.lastPolled ? new Date(f.lastPolled * 1000).toISOString() : "",
            nextPollIn: Math.max(0, Math.round(f.lastPolled + Model.pollInterval(f, Date.now() / 1000) - Date.now() / 1000)),
            error: f.error
          }
        })
      }, null, 2)
    }
    function track(query: string): string {
      return root.lookup(query) ? "looking up " + query : root.lookupError
    }
    function remove(key: string): void { root.removeFlight(key); root.removePlan(key) }
    function refresh(): void {
      root.plans = root.plans.map(function(p) {
        var c = {}
        for (var k in p) c[k] = p[k]
        c.lastChecked = 0
        return c
      })
      root.refreshAll()
    }
    function notify(on: bool): void { root.setNotifications(on) }
    function testNotification(): void {
      Quickshell.execDetached(["notify-send", "--app-name=Flights", "--icon=" + root.notifyIcon,
                               "UA1 took off", "SFO → SIN · lands 07:29 +08"])
    }
  }

  Component.onCompleted: mkdirProc.running = true
}
