// Model.js is a QML JavaScript library (no exports), so it is loaded into a
// function scope and its top-level functions are picked off by name.
//
//   node --test test/

const test = require("node:test")
const assert = require("node:assert/strict")
const fs = require("fs")
const path = require("path")

const source = fs.readFileSync(path.join(__dirname, "..", "Model.js"), "utf8")
const M = new Function(source + "\nreturn {" + [
  "parseQuery", "parseList", "parseDetail", "resolve", "phaseOf", "newTracked",
  "applyPoll", "findRow", "isExpired", "expiresAt", "pollInterval", "clock",
  "dayLabel", "statusLine", "focusFlight", "icon", "progress", "parseState", "serializeState",
  "splitResponse", "curlArgv", "duration", "wantsDetail"
].join(",") + "}")()

const fixture = (name) => fs.readFileSync(path.join(__dirname, "fixtures", name), "utf8")
const NOW = 1790820642 // 2026-10-01T02:10:42Z, when the fixtures were captured
const HOUR = 3600

test("parseQuery: flight numbers in the forms people type them", () => {
  assert.deepEqual(M.parseQuery("ua1", NOW).number, "UA1")
  assert.deepEqual(M.parseQuery("UA 1", NOW).number, "UA1")
  assert.deepEqual(M.parseQuery("aa0100", NOW).number, "AA100")
  assert.deepEqual(M.parseQuery("B61", NOW).number, "B61")
  assert.deepEqual(M.parseQuery("u2 1234", NOW).number, "U21234")
  assert.equal(M.parseQuery("", NOW).ok, false)
  assert.equal(M.parseQuery("hello", NOW).ok, false)
})

test("parseQuery: airports, routes, and dates narrow the search", () => {
  const route = M.parseQuery("WN302 MCI-AUS", NOW)
  assert.deepEqual(route.airports, ["MCI", "AUS"])
  assert.deepEqual(M.parseQuery("wn302 aus", NOW).airports, ["AUS"])
  assert.deepEqual(M.parseQuery("DL1 10/3", NOW).date, { y: 2026, m: 10, d: 3 })
  assert.deepEqual(M.parseQuery("DL1 2026-10-04", NOW).date, { y: 2026, m: 10, d: 4 })
  assert.ok(M.parseQuery("DL1 tomorrow", NOW).date)
  assert.equal(M.parseQuery("DL1 banana", NOW).ok, false)
})

test("resolve: a flight in the air right now wins", () => {
  const rows = M.parseList(fixture("list-DL1.json"))
  const r = M.resolve(rows, M.parseQuery("DL1", NOW), NOW)
  assert.equal(r.kind, "single")
  assert.equal(r.row.id, "41ea20d0")
  assert.equal(r.row.live, true)
})

test("resolve: otherwise the next departure", () => {
  const rows = M.parseList(fixture("list-UA1.json"))
  const r = M.resolve(rows, M.parseQuery("UA1", NOW), NOW)
  assert.equal(r.kind, "single")
  assert.equal(new Date(r.row.schedDep * 1000).toISOString(), "2026-10-01T05:40:00.000Z")
})

test("resolve: one number flying two routes in one trip asks which", () => {
  const rows = M.parseList(fixture("list-WN302.json"))
  const r = M.resolve(rows, M.parseQuery("WN302", NOW), NOW)
  assert.equal(r.kind, "choose")
  assert.deepEqual(r.options.map((o) => o.origin.iata + "-" + o.destination.iata), ["MCI-AUS", "AUS-DAL"])
})

test("resolve: an airport in the query settles it", () => {
  const rows = M.parseList(fixture("list-WN302.json"))
  const r = M.resolve(rows, M.parseQuery("WN302 DAL", NOW), NOW)
  assert.equal(r.kind, "single")
  assert.equal(r.row.origin.iata, "AUS")
  assert.equal(r.row.destination.iata, "DAL")
})

test("resolve: a date picks that day, even one that already flew", () => {
  const rows = M.parseList(fixture("list-UA1.json"))
  const r = M.resolve(rows, M.parseQuery("UA1 2026-09-29", NOW), NOW)
  assert.equal(r.kind, "single")
  // 22:40 PDT on the 29th, which is already the 30th in UTC: the date is the
  // origin's, as printed on the boarding pass.
  assert.equal(new Date(r.row.schedDep * 1000).toISOString(), "2026-09-30T05:40:00.000Z")
})

test("resolve: no match explains itself", () => {
  const rows = M.parseList(fixture("list-UA1.json"))
  assert.equal(M.resolve(rows, M.parseQuery("UA1 JFK", NOW), NOW).kind, "none")
  assert.equal(M.resolve([], M.parseQuery("ZZ9", NOW), NOW).kind, "none")
})

test("detail: live position turns into a phase", () => {
  const detail = M.parseDetail(fixture("detail-DL1.json"))
  assert.equal(detail.row.origin.gate, "B22")
  assert.equal(M.phaseOf(detail.row, detail, NOW), "airborne")

  const parked = Object.assign({}, detail, { altitude: 0, speed: 0 })
  const rolling = Object.assign({}, detail, { altitude: 0, speed: 14 })
  const ground = Object.assign({}, detail.row, { realDep: 0 })
  assert.equal(M.phaseOf(ground, parked, NOW), "gate")
  assert.equal(M.phaseOf(ground, rolling, NOW), "taxiing")
  // An old position says nothing about moving now.
  assert.equal(M.phaseOf(ground, Object.assign({}, rolling, { positionAt: NOW - 3 * HOUR }), NOW), "gate")
})

// A tracked flight past its silent first poll, so changes announce.
function primed(tracked) {
  return Object.assign(tracked, { primed: true })
}

function scheduledUA1() {
  const rows = M.parseList(fixture("list-UA1.json"))
  return M.resolve(rows, M.parseQuery("UA1", NOW), NOW).row
}

test("applyPoll: a departure delay past the threshold notifies once", () => {
  const row = scheduledUA1()
  let tracked = primed(M.newTracked(row, NOW))

  const small = Object.assign({}, row, { estDep: row.schedDep + 4 * 60 })
  let out = M.applyPoll(tracked, small, null, NOW + 60, 10)
  assert.equal(out.events.length, 0)
  tracked = out.tracked

  const big = Object.assign({}, row, { estDep: row.schedDep + 35 * 60 })
  out = M.applyPoll(tracked, big, null, NOW + 120, 10)
  assert.equal(out.events.length, 1)
  assert.match(out.events[0].title, /UA1 departure delayed/)
  assert.match(out.events[0].body, /was 22:40/)
  tracked = out.tracked

  out = M.applyPoll(tracked, big, null, NOW + 180, 10)
  assert.equal(out.events.length, 0, "same delay is not news twice")
})

test("applyPoll: taxi, takeoff, and landing each notify", () => {
  const row = scheduledUA1()
  let tracked = primed(M.newTracked(row, NOW))
  const live = Object.assign({}, row, { id: "abc", live: true })
  const taxi = { row: live, altitude: 0, speed: 12, positionAt: NOW + 60 }
  let out = M.applyPoll(tracked, live, taxi, NOW + 60, 10)
  assert.equal(out.tracked.phase, "taxiing")
  assert.match(out.events[0].title, /taxiing/)

  const up = Object.assign({}, live, { realDep: NOW + 600 })
  out = M.applyPoll(out.tracked, up, null, NOW + 700, 10)
  assert.equal(out.tracked.phase, "airborne")
  assert.match(out.events[0].title, /took off/)

  const down = Object.assign({}, up, { realArr: NOW + 17 * HOUR, live: false, generic: "landed" })
  out = M.applyPoll(out.tracked, down, null, NOW + 17 * HOUR + 60, 10)
  assert.equal(out.tracked.phase, "landed")
  assert.match(out.events[0].title, /landed in Singapore/)
  assert.equal(out.events.length, 1)
})

test("applyPoll: phases never step backwards on a thin response", () => {
  const row = scheduledUA1()
  const tracked = Object.assign(primed(M.newTracked(row, NOW)), { phase: "taxiing" })
  tracked.told = Object.assign({}, tracked.told, { phase: "taxiing" })
  const out = M.applyPoll(tracked, row, null, NOW + 60, 10)
  assert.equal(out.tracked.phase, "taxiing")
  assert.equal(out.events.length, 0)
})

test("applyPoll: cancellation is urgent", () => {
  const row = scheduledUA1()
  const out = M.applyPoll(primed(M.newTracked(row, NOW)), Object.assign({}, row, { generic: "canceled" }), null, NOW + 60, 10)
  assert.equal(out.tracked.phase, "canceled")
  assert.equal(out.events[0].urgency, "critical")
})

test("applyPoll: a gate change is announced", () => {
  const row = scheduledUA1()
  let tracked = primed(M.newTracked(row, NOW))
  const g1 = { row: Object.assign({}, row, { origin: Object.assign({}, row.origin, { gate: "G92" }) }) }
  let out = M.applyPoll(tracked, row, g1, NOW + 60, 10)
  assert.match(out.events.map((e) => e.title).join(), /gate assigned/)
  const g2 = { row: Object.assign({}, row, { origin: Object.assign({}, row.origin, { gate: "G98" }) }) }
  out = M.applyPoll(out.tracked, row, g2, NOW + 120, 10)
  assert.match(out.events.map((e) => e.title).join(), /gate change/)
  assert.match(out.events.map((e) => e.body).join(), /was G92/)
})

test("applyPoll: the first poll after adding is silent", () => {
  const row = scheduledUA1()
  const fresh = M.newTracked(row, NOW)
  const g = { row: Object.assign({}, row, { origin: Object.assign({}, row.origin, { gate: "G92" }) }) }
  const out = M.applyPoll(fresh, row, g, NOW + 60, 10)
  assert.equal(out.events.length, 0)
  assert.equal(out.tracked.told.depGate, "G92")
  assert.equal(out.tracked.primed, true)
})

test("expiry: landed flights fall off three hours after touchdown", () => {
  const row = scheduledUA1()
  const landedRow = Object.assign({}, row, { realDep: row.schedDep, realArr: row.schedArr, generic: "landed" })
  const tracked = Object.assign(M.newTracked(landedRow, NOW), { phase: "landed" })
  assert.equal(M.isExpired(tracked, row.schedArr + 2 * HOUR, 3), false)
  assert.equal(M.isExpired(tracked, row.schedArr + 3 * HOUR, 3), true)
})

test("expiry: a scheduled flight is kept until well after it was due", () => {
  const tracked = M.newTracked(scheduledUA1(), NOW)
  assert.equal(M.isExpired(tracked, NOW, 3), false)
})

test("poll cadence tightens near departure", () => {
  const tracked = M.newTracked(scheduledUA1(), NOW)
  assert.equal(M.pollInterval(tracked, NOW), 600)                   // ~3.5h out
  assert.equal(M.pollInterval(tracked, tracked.schedDep - HOUR), 120)
  assert.equal(M.pollInterval(Object.assign({}, tracked, { phase: "airborne" }), NOW), 60)
})

test("formatting: airport-local clocks and day labels", () => {
  const row = scheduledUA1()
  assert.equal(M.clock(row.schedDep, row.origin), "22:40")     // PDT
  assert.equal(M.dayLabel(row.schedDep, row.origin, NOW), "Today")
  assert.equal(M.duration(95 * 60), "1h 35m")
  assert.equal(M.duration(120 * 60), "2h")
  assert.match(M.statusLine(primed(M.newTracked(row, NOW)), NOW), /^Departs in 3h/)
})

test("state round-trips and drops junk", () => {
  const tracked = M.newTracked(scheduledUA1(), NOW)
  const state = M.parseState(M.serializeState({ notifications: false, flights: [tracked, { nope: 1 }] }))
  assert.equal(state.notifications, false)
  assert.equal(state.flights.length, 1)
  assert.equal(M.parseState("garbage").notifications, true)
})

test("icons fall through tiers", () => {
  assert.equal(M.icon("flying", "pro"), "\uf072")
  assert.equal(M.icon("flying", "nerd"), "\u{f001d}")
  assert.equal(M.icon("nope", "pro"), M.icon("flying", "pro"))
})

test("bar: the icon speaks for the loudest flight", () => {
  const row = scheduledUA1()
  const waiting = primed(M.newTracked(row, NOW))
  const flying = Object.assign(primed(M.newTracked(Object.assign({}, row, { schedDep: row.schedDep + 1 }), NOW)), {
    phase: "airborne",
    row: Object.assign({}, row, { realDep: NOW - HOUR, estArr: NOW + 3 * HOUR })
  })
  const canceled = Object.assign(primed(M.newTracked(row, NOW)), { phase: "canceled" })

  assert.equal(M.focusFlight([]), null)
  assert.equal(M.focusFlight([waiting, flying]), flying)
  assert.equal(M.focusFlight([flying, canceled]), canceled)

})

test("curl response status is split from the body", () => {
  assert.deepEqual(M.splitResponse('{"a":1}\n200'), { status: 200, body: '{"a":1}' })
  assert.equal(M.splitResponse("").status, 0)
  assert.ok(M.curlArgv("https://x").indexOf("-A") !== -1)
})
