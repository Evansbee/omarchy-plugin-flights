// Pure parsing, resolution, and formatting for the flight tracker. Deliberately
// Qt-free so every rule here runs under node without a shell (see test/); the
// QML owns processes, timers, persistence, colors, and layout.
//
// All times are epoch *seconds*, the unit Flightradar24 speaks. Airport-local
// times are rendered from the offset FR24 sends with each airport rather than
// from the machine's zone, because "lands 07:29" means Singapore time when the
// flight lands in Singapore.

var LIST_URL = "https://api.flightradar24.com/common/v1/flight/list.json"
var DETAIL_URL = "https://data-live.flightradar24.com/clickhandler/"

// FR24 answers 403 to curl's own user agent.
var USER_AGENT = "Mozilla/5.0 (X11; Linux x86_64; rv:131.0) Gecko/20100101 Firefox/131.0"

var MINUTE = 60
var HOUR = 3600

// Legs of one flight number within this span of the first one are "the same
// trip" for disambiguation. A daily flight repeats at 24h, so it never counts.
var TRIP_WINDOW = 18 * HOUR

// A row that never reported landing is given up on this long after it was due.
var STALE_AFTER = 12 * HOUR

// Icons come in three tiers, best first:
//   pro   Font Awesome 7 Pro, loaded at runtime from the person's own copy
//         (it's licensed per person, so it is never shipped in this repo)
//   free  Font Awesome 7 Free Solid, which Omarchy installs system-wide
//   nerd  Material Design glyphs from the Nerd Font every Omarchy bar uses
// A name missing from a tier falls through to the next one that has it.
var ICONS = {
  idle:      { pro: "\ue22d", free: "\ue22d", nerd: "\udb80\udc1d" },  // plane-up
  scheduled: { pro: "\ue29a", free: "\ue22d", nerd: "\udb86\udc7c" },  // ticket-airline
  departing: { pro: "\uf5b0", free: "\uf5b0", nerd: "\udb81\uddd5" },  // plane-departure
  flying:    { pro: "\uf072", free: "\uf072", nerd: "\udb80\udc1d" },  // plane (points right)
  landed:    { pro: "\uf5af", free: "\uf5af", nerd: "\udb81\uddd4" },  // plane-arrival
  alert:     { pro: "\ue556", free: "\ue556", nerd: "\udb86\udc7a" },  // plane-circle-exclamation
  canceled:  { pro: "\ue557", free: "\ue557", nerd: "\udb86\udc7a" },  // plane-circle-xmark
  radar:     { pro: "\ue024", free: "\uf110", nerd: "\udb81\udc37" },  // radar / spinner
  search:    { pro: "\uf002", free: "\uf002", nerd: "\udb86\udc83" },  // magnifying-glass
  remove:    { pro: "\uf00d", free: "\uf00d", nerd: "\udb80\udd56" },  // xmark
  bell:      { pro: "\uf0f3", free: "\uf0f3", nerd: "\udb80\udc9a" },
  bellOff:   { pro: "\uf1f6", free: "\uf1f6", nerd: "\udb80\udc9b" },
  tower:     { pro: "\ue2a2", free: "\uf519", nerd: "\udb82\udc4b" }   // tower-control
}

// The md-airplane Nerd glyph points up-right; the Font Awesome plane points
// right. Rotation that makes a tier's "flying" glyph point along the route.
function flyingRotation(tier) {
  return tier === "nerd" ? 45 : 0
}

function icon(name, tier) {
  var entry = ICONS[name] || ICONS.idle
  return entry[tier] || entry.nerd
}

// ---------------------------------------------------------------------------
// Requests

function listUrl(number) {
  return LIST_URL + "?query=" + encodeURIComponent(number) + "&fetchBy=flight&page=1&limit=100"
}

function detailUrl(id) {
  return DETAIL_URL + "?version=1.5&flight=" + encodeURIComponent(id)
}

// argv, not a shell line: nothing typed into the panel ever meets a shell.
// -w appends the status on its own line so a 403 is reported as one rather
// than as a JSON parse failure.
function curlArgv(url) {
  return ["curl", "-sS", "--compressed", "-m", "20",
          "-A", USER_AGENT,
          "-H", "Accept: application/json",
          "-w", "\n%{http_code}",
          url]
}

// Splits the trailing status line written by curlArgv's -w.
function splitResponse(raw) {
  var text = String(raw || "")
  var cut = text.lastIndexOf("\n")
  var code = cut === -1 ? 0 : parseInt(text.slice(cut + 1), 10)
  return { status: isFinite(code) ? code : 0, body: cut === -1 ? text : text.slice(0, cut) }
}

function httpError(status) {
  if (status === 403 || status === 451) return "Flightradar24 refused the request (" + status + ")"
  if (status === 429) return "Flightradar24 is rate limiting — backing off"
  if (status >= 500) return "Flightradar24 is having trouble (" + status + ")"
  if (status === 0) return "No response from Flightradar24"
  return "Flightradar24 answered " + status
}

// ---------------------------------------------------------------------------
// Query parsing: "UA1", "ua 1", "WN302 AUS", "WN302 MCI-AUS", "DL1 10/3",
// "AA100 tomorrow", "B6 1 2026-10-04".

var FLIGHT_RE = /^([A-Z]{3}|[A-Z][0-9]|[0-9][A-Z]|[A-Z]{2})\s*-?\s*([0-9]{1,4}[A-Z]?)(?![0-9])/

function parseQuery(text, nowSec) {
  var raw = String(text || "").trim().toUpperCase()
  if (raw === "") return { ok: false, error: "Type a flight number, like UA1" }

  var match = FLIGHT_RE.exec(raw)
  if (!match) return { ok: false, error: "That doesn't look like a flight number" }

  var number = match[1] + match[2].replace(/^0+(?=[0-9])/, "")
  var rest = raw.slice(match[0].length).trim()
  var airports = []
  var date = null

  // "MCI-AUS" is a route, not a date; split it before the general tokenizer.
  rest = rest.replace(/\b([A-Z]{3})-([A-Z]{3})\b/g, "$1 $2")
  var tokens = rest === "" ? [] : rest.split(/[\s,>→]+/)
  for (var i = 0; i < tokens.length; i++) {
    var token = tokens[i]
    if (!token || token === "-" || token === "TO" || token === "FROM" || token === "ON") continue
    if (/^[A-Z]{3}$/.test(token)) { airports.push(token); continue }
    var parsed = parseDateToken(token, nowSec)
    if (parsed) { date = parsed; continue }
    return { ok: false, error: "Didn't understand \"" + token.toLowerCase() + "\"" }
  }
  if (airports.length > 2) return { ok: false, error: "At most two airports: from and to" }

  return { ok: true, number: number, airports: airports, date: date }
}

// A calendar day as {y, m, d}, compared later against the *origin's* local
// date — the date printed on the boarding pass.
function parseDateToken(token, nowSec) {
  var now = new Date((nowSec || Date.now() / 1000) * 1000)
  var today = { y: now.getFullYear(), m: now.getMonth() + 1, d: now.getDate() }
  if (token === "TODAY") return today
  if (token === "TOMORROW") {
    var t = new Date(now.getFullYear(), now.getMonth(), now.getDate() + 1)
    return { y: t.getFullYear(), m: t.getMonth() + 1, d: t.getDate() }
  }

  var iso = /^([0-9]{4})-([0-9]{1,2})-([0-9]{1,2})$/.exec(token)
  if (iso) return validDay(+iso[1], +iso[2], +iso[3])

  var us = /^([0-9]{1,2})\/([0-9]{1,2})(?:\/([0-9]{2,4}))?$/.exec(token)
  if (us) {
    var year = us[3] ? +us[3] : today.y
    if (year < 100) year += 2000
    var day = validDay(year, +us[1], +us[2])
    // "1/3" typed in late December means the coming January.
    if (day && !us[3] && dayNumber(day) < dayNumber(today) - 7) day.y += 1
    return day
  }
  return null
}

function validDay(y, m, d) {
  if (m < 1 || m > 12 || d < 1 || d > 31) return null
  return { y: y, m: m, d: d }
}

function dayNumber(day) {
  return Math.floor(Date.UTC(day.y, day.m - 1, day.d) / 86400000)
}

function sameDay(a, b) {
  return !!a && !!b && a.y === b.y && a.m === b.m && a.d === b.d
}

// ---------------------------------------------------------------------------
// Normalizing FR24 rows

function num(value) {
  var n = Number(value)
  return value === null || value === undefined || value === "" || !isFinite(n) ? 0 : n
}

function airport(raw) {
  var a = raw || {}
  var code = a.code || {}
  var tz = a.timezone || {}
  var region = (a.position && a.position.region) || {}
  var info = a.info || {}
  return {
    iata: String(code.iata || code.icao || "???"),
    name: String(a.name || ""),
    city: String(region.city || ""),
    tzOffset: num(tz.offset),
    tzAbbr: String(tz.abbr || ""),
    terminal: info.terminal ? String(info.terminal) : "",
    gate: info.gate ? String(info.gate) : ""
  }
}

function times(raw) {
  var t = raw || {}
  var s = t.scheduled || {}, e = t.estimated || {}, r = t.real || {}, o = t.other || {}
  return {
    schedDep: num(s.departure), schedArr: num(s.arrival),
    estDep: num(e.departure), estArr: num(e.arrival) || num(o.eta),
    realDep: num(r.departure), realArr: num(r.arrival)
  }
}

// One row of flight/list.json, or the top level of a clickhandler detail,
// flattened to what the tracker reads.
function normalizeRow(raw) {
  if (!raw || typeof raw !== "object") return null
  var ident = raw.identification || {}
  var number = (ident.number && ident.number.default) || ""
  var airports = raw.airport || {}
  var status = raw.status || {}
  var generic = (status.generic && status.generic.status) || {}
  var event = (status.generic && status.generic.eventTime) || {}
  var airline = raw.airline || {}
  var aircraft = raw.aircraft || {}
  var model = aircraft.model || {}

  var row = {
    id: ident.id ? String(ident.id) : "",
    row: ident.row ? String(ident.row) : "",
    number: String(number).toUpperCase(),
    callsign: ident.callsign ? String(ident.callsign) : "",
    airline: String(airline.name || airline.short || ""),
    aircraft: String(model.text || model.code || aircraft.text || aircraft.code || ""),
    registration: String(aircraft.registration || ""),
    origin: airport(airports.origin),
    destination: airport(airports.destination),
    live: status.live === true,
    statusText: String(status.text || ""),
    generic: String(generic.text || "").toLowerCase(),
    diverted: !!generic.diverted || /divert/i.test(String(status.text || "")),
    eventTime: num(event.utc)
  }
  var t = times(raw.time)
  for (var k in t) row[k] = t[k]
  if (!row.schedDep) return null
  return row
}

function parseList(raw) {
  var data
  try { data = JSON.parse(String(raw || "")) } catch (e) { return null }
  var response = data && data.result && data.result.response
  if (!response) return null
  var rows = Array.isArray(response.data) ? response.data : []
  var out = []
  for (var i = 0; i < rows.length; i++) {
    var row = normalizeRow(rows[i])
    if (row) out.push(row)
  }
  return out
}

// The clickhandler detail adds what the list lacks: where the aircraft is now
// (to tell taxiing from parked) and gates.
function parseDetail(raw) {
  var data
  try { data = JSON.parse(String(raw || "")) } catch (e) { return null }
  if (!data || typeof data !== "object" || !data.identification) return null
  var row = normalizeRow(data)
  var trail = Array.isArray(data.trail) ? data.trail : []
  var last = trail.length > 0 ? trail[0] : null
  return {
    row: row,
    altitude: last ? num(last.alt) : 0,
    speed: last ? num(last.spd) : 0,
    heading: last ? num(last.hd) : 0,
    positionAt: last ? num(last.ts) : 0
  }
}

// ---------------------------------------------------------------------------
// Phase: the one word for where a flight is in its day.
//
//   scheduled → gate → taxiing → airborne → landed
//                 \__________ canceled / diverted
//
// "gate" and "taxiing" need the live detail; without it a flight that FR24 is
// tracking but has not taken off is "gate". A position older than
// FRESH_POSITION says nothing about whether the aircraft is moving now.

var FRESH_POSITION = 10 * MINUTE


function phaseOf(row, detail, nowSec) {
  if (!row) return "scheduled"
  if (row.generic === "canceled" || row.generic === "cancelled") return "canceled"
  if (row.diverted) return "diverted"
  if (row.realArr || row.generic === "landed") return "landed"
  if (row.realDep) return "airborne"
  if (detail && detail.positionAt) {
    if (detail.altitude > 200) return "airborne"
    var fresh = !nowSec || nowSec - detail.positionAt < FRESH_POSITION
    return fresh && detail.speed >= 5 ? "taxiing" : "gate"
  }
  if (row.live) return "gate"
  return "scheduled"
}

function phaseLabel(phase) {
  switch (phase) {
  case "gate": return "At the gate"
  case "taxiing": return "Taxiing"
  case "airborne": return "In the air"
  case "landed": return "Landed"
  case "canceled": return "Canceled"
  case "diverted": return "Diverted"
  default: return "Scheduled"
  }
}

function isActivePhase(phase) {
  return phase === "gate" || phase === "taxiing" || phase === "airborne"
}

function isTroublePhase(phase) {
  return phase === "canceled" || phase === "diverted"
}

// Best known times: what happened, else what is expected, else the timetable.
function departureTime(row) { return row ? (row.realDep || row.estDep || row.schedDep) : 0 }
function arrivalTime(row) { return row ? (row.realArr || row.estArr || row.schedArr) : 0 }

function delayMinutes(row) {
  if (!row || !row.schedDep) return 0
  var dep = row.realDep || row.estDep
  return dep ? Math.round((dep - row.schedDep) / MINUTE) : 0
}

function arrivalDelayMinutes(row) {
  if (!row || !row.schedArr) return 0
  var arr = row.realArr || row.estArr
  return arr ? Math.round((arr - row.schedArr) / MINUTE) : 0
}

// When a landed flight touched down, as precisely as FR24 will say.
function landedAt(row) {
  if (!row) return 0
  return row.realArr || (row.generic === "landed" ? (row.eventTime || row.estArr || row.schedArr) : 0)
}

// "Finished" for choosing which instance a bare flight number means: nothing
// left to watch.
function isFinished(row, nowSec) {
  var phase = phaseOf(row, null)
  if (phase === "landed") return true
  if (phase === "canceled" || phase === "diverted") return (row.schedArr || row.schedDep) < nowSec
  if (row.live) return false
  return arrivalTime(row) + STALE_AFTER < nowSec
}

function isUnderway(row) {
  if (!row || row.realArr || row.generic === "landed") return false
  return row.live || !!row.realDep
}

// ---------------------------------------------------------------------------
// Resolution: which instance of a flight number does the person mean?
//
//   - Something in the air (or rolling) right now beats anything scheduled.
//   - Otherwise the next departure that hasn't happened.
//   - If the flight number flies *different routes* inside one trip window —
//     WN302 doing MCI→AUS and then AUS→DAL — that's ambiguous, so ask.
//   - An airport or a date in the query narrows the rows first.

function routeKey(row) {
  return row.origin.iata + ">" + row.destination.iata
}

function originDay(row) {
  var d = new Date((row.schedDep + row.origin.tzOffset) * 1000)
  return { y: d.getUTCFullYear(), m: d.getUTCMonth() + 1, d: d.getUTCDate() }
}

function matchesAirports(row, airports) {
  if (!airports || airports.length === 0) return true
  if (airports.length === 2)
    return row.origin.iata === airports[0] && row.destination.iata === airports[1]
  return row.origin.iata === airports[0] || row.destination.iata === airports[0]
}

function byDeparture(a, b) { return a.schedDep - b.schedDep }

function earliestPerRoute(rows) {
  var seen = {}
  var out = []
  for (var i = 0; i < rows.length; i++) {
    var key = routeKey(rows[i])
    if (seen[key]) continue
    seen[key] = true
    out.push(rows[i])
  }
  return out
}

function describeQuery(query) {
  var text = query.number
  if (query.airports && query.airports.length) text += " " + query.airports.join("→")
  if (query.date) text += " on " + query.date.m + "/" + query.date.d
  return text
}

// -> { kind: "single", row } | { kind: "choose", options: [row...] } | { kind: "none", message }
function resolve(rows, query, nowSec) {
  if (!rows || rows.length === 0)
    return { kind: "none", message: "Flightradar24 has no flight " + query.number }

  var pool = []
  for (var i = 0; i < rows.length; i++) {
    var row = rows[i]
    if (!matchesAirports(row, query.airports)) continue
    if (query.date && !sameDay(originDay(row), query.date)) continue
    pool.push(row)
  }
  pool.sort(byDeparture)
  if (pool.length === 0)
    return { kind: "none", message: "No " + describeQuery(query) + " found" }

  // A date was given: the person picked the day, so only the route can be
  // ambiguous, and a flight that already flew that day is still a valid ask.
  if (query.date) {
    var day = earliestPerRoute(pool)
    return day.length === 1 ? { kind: "single", row: day[0] } : { kind: "choose", options: day }
  }

  var underway = [], upcoming = []
  for (var j = 0; j < pool.length; j++) {
    if (isUnderway(pool[j])) underway.push(pool[j])
    else if (!isFinished(pool[j], nowSec)) upcoming.push(pool[j])
  }

  var anchor = underway.length > 0 ? underway[0] : upcoming[0]
  if (!anchor)
    return { kind: "none", message: "No upcoming " + describeQuery(query) + " — add a date, like " + query.number + " 10/3" }

  var trip = underway.slice()
  for (var k = 0; k < upcoming.length; k++) {
    if (upcoming[k].schedDep - anchor.schedDep < TRIP_WINDOW) trip.push(upcoming[k])
  }
  trip.sort(byDeparture)

  var legs = earliestPerRoute(trip)
  return legs.length === 1 ? { kind: "single", row: legs[0] } : { kind: "choose", options: legs }
}

// ---------------------------------------------------------------------------
// Tracked flights

// Stable identity for one departure of one flight: the timetable doesn't move
// when the flight is delayed, so number + origin + scheduled departure is the
// same on every poll. FR24's own `id` only exists once the aircraft is live.
function flightKey(row) {
  return row.number + "|" + row.origin.iata + "|" + row.schedDep
}

function newTracked(row, nowSec) {
  return {
    key: flightKey(row),
    number: row.number,
    origin: row.origin.iata,
    destination: row.destination.iata,
    schedDep: row.schedDep,
    addedAt: nowSec,
    lastPolled: 0,
    lastDetail: 0,
    error: "",
    row: row,
    phase: phaseOf(row, null),
    altitude: 0,
    speed: 0,
    // What the person was last *told*, so an ETA drifting a minute a poll
    // notifies once per threshold rather than never (or every poll).
    told: { phase: phaseOf(row, null), dep: departureTime(row), arr: arrivalTime(row),
            depGate: row.origin.gate, arrGate: row.destination.gate },
    // The first poll after adding only sets the baseline: a gate or a live
    // phase learned seconds after the person typed the flight in isn't news.
    primed: false
  }
}

// Finds this departure among a fresh list response.
function findRow(rows, tracked) {
  if (!rows) return null
  for (var i = 0; i < rows.length; i++) {
    if (flightKey(rows[i]) === tracked.key) return rows[i]
  }
  // A retimed schedule moves schedDep; fall back to the same route on the
  // same origin day.
  var day = originDay(tracked.row)
  for (var j = 0; j < rows.length; j++) {
    var r = rows[j]
    if (r.origin.iata === tracked.origin && r.destination.iata === tracked.destination
        && sameDay(originDay(r), day)) return r
  }
  return null
}

// The detail carries gates the list lacks; keep whatever the list didn't say.
function mergeRow(listRow, detailRow) {
  if (!detailRow) return listRow
  if (!listRow) return detailRow
  var out = {}
  for (var k in listRow) out[k] = listRow[k]
  var keys = ["estDep", "estArr", "realDep", "realArr", "id", "callsign", "aircraft", "registration", "airline"]
  for (var i = 0; i < keys.length; i++) {
    var key = keys[i]
    if (detailRow[key] && !out[key]) out[key] = detailRow[key]
  }
  out.live = listRow.live || detailRow.live
  out.origin = withGate(listRow.origin, detailRow.origin)
  out.destination = withGate(listRow.destination, detailRow.destination)
  return out
}

function withGate(a, b) {
  var out = {}
  for (var k in a) out[k] = a[k]
  if (b && b.gate) out.gate = b.gate
  if (b && b.terminal) out.terminal = b.terminal
  return out
}

// Should this poll also ask for the live detail? Only once FR24 has an
// aircraft for it and there's still something to watch.
function wantsDetail(tracked) {
  var row = tracked.row
  if (!row || !row.id) return false
  return tracked.phase !== "landed" && !isTroublePhase(tracked.phase)
}

// How long until this flight is worth asking about again. Close to the action
// it is a minute; days out it is half an hour.
function pollInterval(tracked, nowSec) {
  var phase = tracked.phase
  if (isActivePhase(phase)) return 60
  if (phase === "landed" || isTroublePhase(phase)) return 10 * MINUTE
  var until = departureTime(tracked.row) - nowSec
  if (until < 3 * HOUR) return 2 * MINUTE
  if (until < 24 * HOUR) return 10 * MINUTE
  return 30 * MINUTE
}

function isDue(tracked, nowSec) {
  return !tracked.lastPolled || nowSec - tracked.lastPolled >= pollInterval(tracked, nowSec)
}

// When a flight falls off the list. Landed: `dropAfterHours` after touchdown.
// Canceled: the same span after it would have landed. Never heard from again:
// STALE_AFTER past its arrival.
function expiresAt(tracked, dropAfterHours) {
  var keep = Math.max(0, Number(dropAfterHours)) * HOUR
  var row = tracked.row
  if (tracked.phase === "landed") return (landedAt(row) || arrivalTime(row)) + keep
  if (tracked.phase === "canceled") return (row.schedArr || row.schedDep) + keep
  if (tracked.phase === "diverted") return arrivalTime(row) + Math.max(keep, 6 * HOUR)
  return arrivalTime(row) + STALE_AFTER
}

function isExpired(tracked, nowSec, dropAfterHours) {
  return nowSec >= expiresAt(tracked, dropAfterHours)
}

// Applies a poll and returns the notifications it earned. `tracked` is not
// mutated; the caller swaps in `next`.
//
// thresholdMinutes: how far a time must move from what was last announced
// before it is announced again.
function applyPoll(tracked, listRow, detail, nowSec, thresholdMinutes) {
  var next = {}
  for (var k in tracked) next[k] = tracked[k]
  var detailRow = detail ? detail.row : null
  var row = mergeRow(listRow || tracked.row, detailRow)
  // Gates outlive the detail response: keep the last one seen.
  row.origin = withGate(row.origin, { gate: row.origin.gate || tracked.row.origin.gate,
                                       terminal: row.origin.terminal || tracked.row.origin.terminal })
  row.destination = withGate(row.destination, { gate: row.destination.gate || tracked.row.destination.gate,
                                                 terminal: row.destination.terminal || tracked.row.destination.terminal })
  next.row = row
  next.lastPolled = nowSec
  next.error = ""
  if (detail) {
    next.lastDetail = nowSec
    next.altitude = detail.altitude
    next.speed = detail.speed
  }

  var phase = phaseOf(row, detail, nowSec)
  // Never step backwards on a stale or partial response (a detail that lost
  // its trail must not turn "taxiing" back into "scheduled").
  if (phaseRank(phase) < phaseRank(tracked.phase) && !isTroublePhase(phase)) phase = tracked.phase
  next.phase = phase

  var told = {}
  for (var t in tracked.told) told[t] = tracked.told[t]
  var events = []
  var threshold = Math.max(1, Number(thresholdMinutes) || 10) * MINUTE

  if (phase !== told.phase) {
    var phaseEvent = phaseNotification(next, told.phase)
    if (phaseEvent) events.push(phaseEvent)
    told.phase = phase
  }

  var dep = departureTime(row)
  var departed = !!row.realDep || phaseRank(phase) >= phaseRank("airborne")
  if (!departed && !isTroublePhase(phase) && Math.abs(dep - told.dep) >= threshold) {
    events.push({
      title: row.number + " departure " + (dep > told.dep ? "delayed" : "moved earlier"),
      body: "Now " + clock(dep, row.origin) + " from " + row.origin.iata
        + " (was " + clock(told.dep, row.origin) + ")" + delaySuffix(delayMinutes(row)),
      urgency: dep - row.schedDep >= HOUR ? "critical" : "normal"
    })
    told.dep = dep
  } else if (departed) {
    told.dep = dep
  }

  var arr = arrivalTime(row)
  if (phase !== "landed" && !isTroublePhase(phase) && Math.abs(arr - told.arr) >= threshold) {
    events.push({
      title: row.number + " arrival " + (arr > told.arr ? "later" : "earlier"),
      body: "Now " + clock(arr, row.destination) + " in " + row.destination.iata
        + " (was " + clock(told.arr, row.destination) + ")",
      urgency: "normal"
    })
    told.arr = arr
  } else if (phase === "landed") {
    told.arr = arr
  }

  if (!departed && row.origin.gate && row.origin.gate !== told.depGate) {
    events.push({
      title: row.number + (told.depGate ? " gate change" : " gate assigned"),
      body: "Departs " + row.origin.iata + " from " + gateText(row.origin)
        + (told.depGate ? " (was " + told.depGate + ")" : ""),
      urgency: told.depGate ? "critical" : "normal"
    })
  }
  if (row.origin.gate) told.depGate = row.origin.gate

  if (phase !== "landed" && row.destination.gate && row.destination.gate !== told.arrGate) {
    events.push({
      title: row.number + " arrival gate " + row.destination.gate,
      body: "Arrives " + row.destination.iata + " at " + gateText(row.destination)
        + (told.arrGate ? " (was " + told.arrGate + ")" : ""),
      urgency: "normal"
    })
  }
  if (row.destination.gate) told.arrGate = row.destination.gate

  next.told = told
  if (!tracked.primed) {
    next.primed = true
    events = []
  }
  return { tracked: next, events: events }
}

function phaseRank(phase) {
  switch (phase) {
  case "gate": return 1
  case "taxiing": return 2
  case "airborne": return 3
  case "landed": return 4
  case "canceled": case "diverted": return 5
  default: return 0
  }
}

function phaseNotification(tracked, previous) {
  var row = tracked.row
  var route = row.origin.iata + " → " + row.destination.iata
  switch (tracked.phase) {
  case "gate":
    return null  // FR24 picking up a transponder at the gate is not news.
  case "taxiing":
    return { title: row.number + " is taxiing", body: route + " · leaving " + row.origin.iata
      + (row.origin.gate ? " gate " + row.origin.gate : ""), urgency: "normal" }
  case "airborne":
    return { title: row.number + " took off", body: route + " · lands "
      + clock(arrivalTime(row), row.destination) + " " + row.destination.tzAbbr, urgency: "normal" }
  case "landed":
    return { title: row.number + " landed in " + (row.destination.city || row.destination.iata),
      body: route + " · " + clock(landedAt(row) || arrivalTime(row), row.destination)
        + (row.destination.gate ? " · gate " + row.destination.gate : ""), urgency: "normal" }
  case "canceled":
    return { title: row.number + " was canceled", body: route + " · was due out "
      + clock(row.schedDep, row.origin), urgency: "critical" }
  case "diverted":
    return { title: row.number + " diverted", body: route + " · " + row.statusText, urgency: "critical" }
  default:
    return null
  }
}

function delaySuffix(minutes) {
  if (minutes >= 5) return " · " + duration(minutes * MINUTE) + " late"
  if (minutes <= -5) return " · " + duration(-minutes * MINUTE) + " early"
  return ""
}

function gateText(place) {
  var parts = []
  if (place.terminal) parts.push("terminal " + place.terminal)
  if (place.gate) parts.push("gate " + place.gate)
  return parts.join(", ")
}

// ---------------------------------------------------------------------------
// Progress along the route, 0..1, for the little plane on the panel's line.

function progress(tracked, nowSec) {
  var row = tracked.row
  var phase = tracked.phase
  if (phase === "landed") return 1
  if (phase !== "airborne") return 0
  var start = row.realDep || row.estDep || row.schedDep
  var end = arrivalTime(row)
  if (!start || end <= start) return 0.5
  return Math.max(0.02, Math.min(0.98, (nowSec - start) / (end - start)))
}

// ---------------------------------------------------------------------------
// Formatting

function pad(n) { return n < 10 ? "0" + n : String(n) }

var DAYS = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
var MONTHS = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]

// "22:40" in the airport's own zone.
function clock(sec, place) {
  if (!sec) return "--:--"
  var d = new Date((sec + (place ? place.tzOffset : 0)) * 1000)
  return pad(d.getUTCHours()) + ":" + pad(d.getUTCMinutes())
}

// "Today", "Tomorrow", "Thu Oct 8" — relative to now *in the airport's zone*.
function dayLabel(sec, place, nowSec) {
  if (!sec) return ""
  var offset = place ? place.tzOffset : 0
  var d = new Date((sec + offset) * 1000)
  var n = new Date((nowSec + offset) * 1000)
  var diff = Math.round((Date.UTC(d.getUTCFullYear(), d.getUTCMonth(), d.getUTCDate())
    - Date.UTC(n.getUTCFullYear(), n.getUTCMonth(), n.getUTCDate())) / 86400000)
  if (diff === 0) return "Today"
  if (diff === 1) return "Tomorrow"
  if (diff === -1) return "Yesterday"
  return DAYS[d.getUTCDay()] + " " + MONTHS[d.getUTCMonth()] + " " + d.getUTCDate()
}

function duration(sec) {
  var total = Math.max(0, Math.round(sec / MINUTE))
  var days = Math.floor(total / 1440)
  var hours = Math.floor((total % 1440) / 60)
  var minutes = total % 60
  if (days > 0) return days + "d " + hours + "h"
  if (hours > 0) return minutes > 0 ? hours + "h " + minutes + "m" : hours + "h"
  return minutes + "m"
}

function durationText(sec) {
  return duration(sec)
}

// The short status line on a card and in the tooltip.
function statusLine(tracked, nowSec) {
  var row = tracked.row
  var phase = tracked.phase
  var dep = departureTime(row)
  var arr = arrivalTime(row)
  switch (phase) {
  case "scheduled":
  case "gate":
    var late = delayMinutes(row)
    var lead = dep > nowSec ? "Departs in " + durationText(dep - nowSec) : "Departure due"
    return (late >= 15 ? "Delayed " + durationText(late * MINUTE) + " · " : "") + lead
  case "taxiing":
    return "Taxiing at " + row.origin.iata
  case "airborne":
    return arr > nowSec ? "Lands in " + durationText(arr - nowSec) : "Landing"
  case "landed":
    var at = landedAt(row) || arr
    return "Landed " + durationText(Math.max(0, nowSec - at)) + " ago"
  case "canceled":
    return "Canceled"
  case "diverted":
    return row.statusText || "Diverted"
  }
  return ""
}

// A choice row while disambiguating: "MCI → AUS · Fri Oct 2 · 19:25 CDT".
function optionLabel(row) {
  return row.origin.iata + " → " + row.destination.iata
}

function optionDetail(row, nowSec) {
  var dep = departureTime(row)
  var text = dayLabel(dep, row.origin, nowSec) + " · departs " + clock(dep, row.origin) + " " + row.origin.tzAbbr
  if (isUnderway(row)) text += " · in progress"
  return text
}

function bestPhase(flights) {
  // Glyph priority for the bar: trouble, then motion, then waiting.
  var order = ["canceled", "diverted", "airborne", "taxiing", "gate", "landed", "scheduled"]
  var best = ""
  var bestRank = order.length
  for (var i = 0; i < flights.length; i++) {
    var rank = order.indexOf(flights[i].phase)
    if (rank !== -1 && rank < bestRank) { bestRank = rank; best = flights[i].phase }
  }
  return best
}

function barIcon(flights) {
  switch (bestPhase(flights)) {
  case "canceled": return "canceled"
  case "diverted": return "alert"
  case "airborne": return "flying"
  case "taxiing": case "gate": return "departing"
  case "landed": return "landed"
  case "scheduled": return "scheduled"
  }
  return "idle"
}

function tooltip(flights, nowSec, error) {
  if (!flights || flights.length === 0)
    return error ? error : "Flights · click to track one"
  var lines = []
  for (var i = 0; i < flights.length; i++) {
    var f = flights[i]
    lines.push(f.row.number + "  " + f.row.origin.iata + "→" + f.row.destination.iata + "  " + statusLine(f, nowSec))
  }
  if (error) lines.push(error)
  return lines.join("\n")
}

// Ordered for the panel: things happening now first, then by departure.
function sortFlights(flights) {
  var copy = flights.slice()
  copy.sort(function(a, b) {
    var aa = isActivePhase(a.phase) ? 0 : 1
    var bb = isActivePhase(b.phase) ? 0 : 1
    if (aa !== bb) return aa - bb
    return departureTime(a.row) - departureTime(b.row)
  })
  return copy
}

// ---------------------------------------------------------------------------
// Persistence

var STATE_VERSION = 1

function serializeState(state) {
  return JSON.stringify({
    version: STATE_VERSION,
    notifications: state.notifications !== false,
    flights: state.flights || []
  }, null, 2) + "\n"
}

function parseState(raw) {
  var fallback = { notifications: true, flights: [] }
  var data
  try { data = JSON.parse(String(raw || "")) } catch (e) { return fallback }
  if (!data || typeof data !== "object") return fallback
  var flights = []
  var list = Array.isArray(data.flights) ? data.flights : []
  for (var i = 0; i < list.length; i++) {
    var f = list[i]
    if (f && f.key && f.row && f.row.origin && f.row.destination && f.told) flights.push(f)
  }
  return { notifications: data.notifications !== false, flights: flights }
}
