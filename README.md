# Flights

An Omarchy shell bar widget for tracking flights. A plane sits in the bar.
Click it, type a flight number, and press Enter. The flight stays on the list
until three hours after it lands, and you get a notification whenever its
times, gates, or status change.

```
bar:    ✈                       ← breathes slowly while a tracked flight is in the air
popup:  ✈ Flights                    🔔 Notify on changes  [■]
        [ Flight number — UA1, WN302 AUS, DL1 10/3      ] [🔍]

        DL1  Delta Air Lines · Airbus A330-223             In the air
        JFK ━━━━━━━✈┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄ LHR
        20:49 20:15                                    08:50 08:14
        Departed · Today EDT · Gate B22   Gate 1 · Today BST · Arrives
        Lands in 4h 51m
```

## Which flight a number means

| You type | It tracks |
|---|---|
| `UA1` | The UA1 in the air right now. If none is airborne, the next UA1 to depart. |
| `WN302` | The panel asks which one when the number flies more than one route in a single trip, such as MCI→AUS followed by AUS→DAL. |
| `WN302 AUS` | The leg that starts or ends at AUS. |
| `WN302 MCI-AUS` | That exact leg. |
| `DL1 10/3`, `DL1 2026-10-03`, `DL1 tomorrow` | That day's departure. The date is matched in the **origin airport's** local time, which is the date printed on the boarding pass. |

Flight numbers can be written as `UA1`, `ua 1`, or `AA0100`. A daily flight
repeats every 24 hours, so it never triggers the question. The question only
comes up when one number flies different routes within 18 hours of each
other.

## What it watches

The status of each flight moves through these stages:

```
scheduled → at the gate → taxiing → in the air → landed
                 \______________ canceled / diverted
```

With **Notify on changes** turned on, you get one notification per poll for
any of the following:

- **Taxiing, takeoff, and landing.** Arriving at the gate is not announced,
  because Flightradar24 picks up a parked aircraft's transponder well before
  anything happens.
- **Departure time** moving by `changeMinutes` or more. Once the flight has
  departed, departure-time changes are no longer announced.
- **Arrival time** moving by `changeMinutes` or more. Each change is measured
  against the last time you were *told*, not the last poll. An estimate that
  drifts one minute per poll is announced once per threshold crossed instead
  of never.
- **Gates**, when one is first assigned and whenever it changes.
- **Cancellations and diversions.** These are sent as critical urgency.

The first poll after you add a flight is silent. A gate or live status that
shows up seconds after you typed the number in isn't news.

Flights leave the list `dropAfterHours` after landing (3 by default).
Canceled flights leave the same amount of time after their scheduled
arrival.

## The bar icon

The icon is a single solid plane, and it stays still. The only motion is a
slow breath, where the plane dims a little and comes back, while a tracked
flight is in the air. A canceled or diverted flight turns the plane the
theme's urgent color. Set `"animate": false` to turn off the breathing.

**Icons.** If you have Font Awesome 7 **Pro**, the widget loads it at runtime
from `iconFont`. The default path is
`~/Resources/fontawesome_font/otfs/Font Awesome 7 Pro-Solid-900.otf`. Pro is
licensed per person, so it is never copied into this repo. If that file is
missing, the widget uses Font Awesome 7 Free, which Omarchy installs. If
Free is missing too, it uses the bar's Nerd Font.


## Interactions

| Gesture | What it does |
|---|---|
| Hover the bar icon | One line per flight: number, route, status |
| Left click | Open the popup, with the cursor already in the box |
| Middle click | Re-poll every flight now |
| `Enter` in the box | Look the flight up |
| `↓` / `↑` | Move between the box and the list |
| `Enter` on a choice | Track that leg |
| `x` on a flight | Stop tracking it (an × also appears on hover) |
| `r` | Refresh everything |
| `Esc` | Dismiss the question, or close |

## Settings

Per-widget settings go inline on the widget's entry in
`~/.config/omarchy/shell.json`:

```json
{ "id": "evansbee.flights", "dropAfterHours": 2, "changeMinutes": 5 }
```

| Key | Default | Meaning |
|---|---|---|
| `dropAfterHours` | `3` | Hours a landed flight stays on the list. |
| `changeMinutes` | `10` | How far a departure or arrival time must move before it is announced again. |
| `animate` | `true` | Breathe the plane while a tracked flight is in the air. |
| `iconFont` | `"~/Resources/fontawesome_font/otfs/Font Awesome 7 Pro-Solid-900.otf"` | Font Awesome Pro font file. Set it to `""` to use the Free icons. |

The notification switch and the tracked flights are saved in
`~/.local/state/omarchy-flights/flights.json`, so they survive shell
restarts and reboots.

## Where the data comes from

The data comes from Flightradar24's public web endpoints, the same ones its
website uses, fetched with `curl`:

- `api.flightradar24.com/common/v1/flight/list.json` returns every recent and
  upcoming departure of a flight number, with timetable, estimated, and
  actual times and a status.
- `data-live.flightradar24.com/clickhandler/` returns the live aircraft once
  Flightradar24 is tracking it: position, ground speed (which distinguishes
  taxiing from parked), and gates.

No account or API key is needed. These endpoints are unofficial and
undocumented, and they reject curl's default user agent. Treat this as a
personal tool: it can break without notice if Flightradar24 changes things,
and it is not meant for heavy use.

Polling is gentle and adapts to the flight. A flight more than a day out is
checked every 30 minutes. One within 24 hours is checked every 10 minutes,
and one within 3 hours every 2 minutes. A flight at the gate, taxiing, or in
the air is checked every minute. A landed flight is checked every 10 minutes
until it drops off. Requests go out one at a time. If Flightradar24 answers
403 or 429, every poll backs off for five minutes.

## Debugging

The service answers over IPC:

```bash
omarchy-shell flights status            # every flight: phase, times, next poll
omarchy-shell flights track "WN302 AUS" # same as typing it in the box
omarchy-shell flights remove "UA1|SFO|1790833200"
omarchy-shell flights refresh           # re-poll everything now
omarchy-shell flights notify false      # the panel's switch
omarchy-shell flights testNotification  # fire a sample notification
```

Every lookup, phase change, and announcement is logged with a `flights`
prefix in the shell log (`/run/user/$UID/quickshell/by-id/*/log.log`).

## Layout

| File | What it is |
|---|---|
| `manifest.json` | Plugin manifest: `service` + `bar-widget`, defaults, settings schema |
| `Service.qml` | The tracker: polling, persistence, notifications, IPC. One per session. |
| `BarWidget.qml` | The animated bar icon, the icon font, and the popup host. One per monitor. |
| `Panel.qml` | The popup |
| `Model.js` | Parsing, resolution, phases, change detection, formatting. Qt-free. |
| `icon.svg` | The notification icon |
| `test/` | `node --test test/`, run against real Flightradar24 responses |

## Install

```bash
omarchy plugin add https://github.com/evansbee/omarchy-plugin-flights.git
omarchy plugin enable evansbee.flights
```

### Hacking on it

```bash
ln -sfn "$PWD" ~/.config/omarchy/plugins/evansbee.flights
omarchy-shell shell rescanPlugins
omarchy plugin enable evansbee.flights
```

As with any symlinked plugin, saving a file does not hot-reload the running
shell, because `inotifywait -r` does not follow symlinks. Run
`omarchy restart shell` after an edit.

## Requirements

- Omarchy with the Quickshell-based `omarchy-shell`
- `curl` and `notify-send`
- Optionally, Font Awesome 7 Pro

## License

MIT for the code. Font Awesome Pro is not included, and its own license
applies to your copy.
