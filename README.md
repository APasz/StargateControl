# Stargate Control

CC:Tweaked/ComputerCraft scripts for driving a Stargate from a monitor UI, raising alarms on incoming connections, and keeping multiple computers in sync.

## Files
- `dial.lua` — main Stargate controller; renders the monitor menu, supports fast/slow dialing, tracks incoming/outgoing wormholes, and resumes if a wormhole is already open after reboot.
- `addresses.lua` — list of named gates. Entries can hide or require sites (see below).
- `settings.lua` — dialer config for redstone sides, timeout, and optional site hint.
- `utils.lua` — shared helpers for monitors, redstone, address formatting, dialing, and input handling.
- `alarm.lua` — siren/indicator UI driven by a redstone input with buttons to silence or toggle outputs.
- `server.lua` / `client.lua` — rednet file host/fetcher; keeps machines updated and can auto-run the primary program.
- `client_config.lua` — modem side + primary program name for `client.lua`.
- `updater.lua` — downloads the latest files from GitHub into `disk/` (for use on the rednet server disk, etc.).

## Requirements
- CC:Tweaked (or ComputerCraft) with a Stargate interface peripheral: `advanced_crystal_interface`, `crystal_interface`, or `basic_interface`.
- A monitor (color preferred). The dialer will fall back to the terminal if none is present.
- Optional redstone relay; otherwise the computer’s native redstone API is used.
- Wireless/ender modems for rednet sync; HTTP enabled if you use `updater.lua`.

## Install / Update
- Manual copy works fine, or download `updater.lua` from the repo and run `updater` on the computer that has a `disk/` directory to refresh every file from GitHub.
- To distribute over rednet, put the fresh files in `disk/` on a host computer, run `server`, and let other machines pull via `client` (see below).

## Configure
### Addresses (`addresses.lua`)
Each entry needs a `site` and `address` (7–9 numbers). Optional filters:
```lua
{ site = "Earth", galaxy = "MilkyWay", intergalaxial = { "*" }, address = { 30, 18, 9, 5, 25, 14, 31, 15, 0 } },
{ site = "Moon", galaxy = "MilkyWay", address = { 9, 1, 3, 6, 15, 4, 25, 27, 0 }, only_from = { "Earth" }, only_to = { "Earth" } },
{ site = "Vermilion", galaxy = "MilkyWay", address = { 13, 3, 17, 2, 14, 21, 32, 1, 0 }, only_from = { "Earth" }, only_to = { "Earth" }, hide_on = { "Earth" } },
```
`hide_on` removes an entry when the local site matches; `only_from` allows dialing only from matching sites; `only_to` (on the local site entry) limits which destinations that site may dial. Sites are matched case-insensitively using the dialing PC's label in format of "*_'site'" or override with `settings.site` (when unmatched or unset, filtering is disabled).

`galaxy` tags split the address list into separate networks. The dialer infers the local galaxy from the entry whose `site` matches the computer label/`settings.site`; if the local site or its galaxy is unknown, no galaxy filtering is applied. Cross-galaxy entries must opt-in on both sides via `intergalaxial = { "*", "SiteName" }`: an entry is shown if the local gate's `intergalaxial` list allows the remote site (or `*`) *and* the remote entry's `intergalaxial` list allows the local site (or `*`). Manual dialing stays universal to prevent soft-locks.

### Dialer settings (`settings.lua`)
`dial.lua` creates this file if missing with sensible defaults:
```lua
return {
    site = nil,             -- optional site name for address filtering
    fast_dial_rs_side = "left", -- redstone input: high = fast-dial symbols; nil to ignore
    incom_alarm_rs_side = nil,  -- redstone output while an incoming wormhole is active
    timeout = 60,           -- seconds before outbound wormholes auto-disconnect
}
```

### Client config (`client_config.lua`)
Created on first run of `client.lua`:
```lua
return {
    side = "back",      -- wireless/ender modem side
    primary_file = "dial", -- program to run after fetching (without .lua)
}
```

## Run the Dialer (`dial.lua`)
- Make sure `dial.lua`, `utils.lua`, `addresses.lua`, and `settings.lua` are on the controller computer (or run `client setup` to fetch them).
- Start with `dial`. The monitor shows the address list; tap a row or type its number to dial.
- Manual entry: type numbers separated by spaces/commas/dashes; 6 symbols auto-append `0` as origin.
- Fast/slow dialing is chosen by the `fast_dial_rs_side` input; the bottom-right corner shows `>` when fast-dial is active, `#` otherwise.
- Outbound wormholes display a countdown and auto-disconnect after `timeout` seconds; tap the monitor to drop early.
- Incoming wormholes paint a red banner, count open time, raise `incom_alarm_rs_side` if set, and let you tap the monitor to send `sg_disconnect` to the remote gate when supported.
- If the computer reboots while a wormhole is open, the UI resumes and shows the active connection.

## Alarm (`alarm.lua`)
- Intended for a separate computer/monitor fed by the dialer’s `incom_alarm_rs_side` (or any redstone input).
- Inputs: `side_input` (default `bottom`) starts/stops the alarm. Outputs: `side_toggle` (default `front`) for the siren plus cycling lights on `phase_sides` (`left`, `top`, `right`).
- On-screen buttons: `[ TOGGLE SIREN ]` toggles the siren output; `[ CANCEL ALARM ]` silences while the input stays high. Debounce/flash timings sit at the top of the file.

## File Sync (optional)
- `server.lua`: open a modem, host `files_request` as `SGServer`, and serve files from `disk/<name>.lua`. Keep a disk with the latest scripts on the server computer.
- `client.lua`: looks up `SGServer`, downloads the configured files, writes them atomically, and runs `primary_file` (default `dial`). Use `client setup` the first time to pull required files (`settings.lua`, `addresses.lua`, etc.); later runs can just call `client` to refresh and launch.
