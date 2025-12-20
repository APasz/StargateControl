# Stargate Control

CC:Tweaked/ComputerCraft scripts for driving a Stargate from a monitor UI, raising alarms on incoming connections, and keeping multiple computers in sync.

## Files
- `dial.lua` — main Stargate controller; renders the monitor menu, supports fast/slow dialing, tracks incoming/outgoing wormholes, and resumes if a wormhole is already open after reboot.
- `dial_settings.lua` — template for the dialer `settings.lua`; fetched by the client when no local settings exist.
- `addresses.lua` — list of named gates. Entries can hide or require sites (see below).
- `utils.lua` — thin facade that re-exports shared helpers used across the apps.
- `address_utils.lua` — site detection, filtering, and address formatting helpers.
- `monitor_utils.lua` — monitor rendering helpers (line wrapping, colour resets, etc).
- `peripheral_utils.lua` — Stargate interface detection, resets, and redstone helpers.
- `menu_utils.lua` — layout and input helpers for the address list.
- `dialing_utils.lua` — fast/slow dialing routines.
- `alarm.lua` — siren/indicator UI driven by rednet alarm broadcasts (with optional redstone input fallback) plus buttons to silence or toggle outputs.
- `alarm_settings.lua` — template for the alarm `settings.lua`.
- `reactor.lua` — monitor UI for Extreme Reactors + Mekanism induction matrix stats.
- `reactor_settings.lua` — template for the reactor monitor `settings.lua`.
- `sync/file_list.lua` — manifest of files shared over rednet, grouped by scope (`manifest`, `shared`, `dialing`, `alarming`, `server`).
- `sync/server.lua` — rednet file host; serves files out of `disk/` using `file_list.lua`.
- `sync/client.lua` — rednet fetcher; keeps machines updated and can auto-run the primary program.
- `sync/client_config.lua` — modem side + primary program name/scope for `client.lua`.
- `sync/updater.lua` — downloads the latest files into `disk/` (for the rednet server disk) and refreshes `updater.lua` itself.

## Requirements
- CC:Tweaked (or ComputerCraft) with a Stargate interface peripheral: `advanced_crystal_interface`, `crystal_interface`, or `basic_interface`.
- A monitor (colour preferred). The dialer will fall back to the terminal if none is present.
- Optional redstone relay; otherwise the computer’s native redstone API is used.
- Wireless/ender modems for rednet sync + alarm/energy broadcasts; HTTP enabled if you use `updater.lua`.

## Install / Update
- Manual copy works fine, or fetch `sync/updater.lua` (save/run as `updater`) on the computer that has a `disk/` directory; it pulls everything listed in `sync/file_list.lua` into `disk/` and refreshes `updater.lua`. Use `updater self` to update only `updater.lua` + `file_list.lua`.
- To distribute over rednet, keep that `disk/` mounted on a host computer, run `sync/server.lua`, and let other machines pull via `sync/client.lua` (see File Sync below).

## Configure
### Addresses (`addresses.lua`)
Each entry needs a `site`, `galaxy`, and `address` (7–9 numbers). Optional filters: `hide_on`, `only_from`, `only_to`, `intergalaxial`
```lua
{ site = "Earth", galaxy = "MilkyWay", intergalaxial = { "*" }, address = { 30, 18, 9, 5, 25, 14, 31, 15, 0 } },
{ site = "Moon", galaxy = "MilkyWay", address = { 6, 7, 27, 31, 23, 18, 3, 5, 0 }, only_from = { "Earth" }, only_to = { "Earth" } },
{ site = "Vermilion", galaxy = "MilkyWay", address = { 13, 3, 17, 2, 14, 21, 32, 1, 0 }, only_from = { "Earth" }, only_to = { "Earth" }, hide_on = { "Earth" } },
```
`hide_on` removes an entry when the local site matches; `only_from` allows dialing only from matching sites; `only_to` (on the local site entry) limits which destinations that site may dial. Sites are matched case-insensitively using the dialing PC's label in format of "*_'site'" or override with `settings.site` (when unmatched or unset, filtering is disabled).

`galaxy` tags split the address list into separate networks. The dialer infers the local galaxy from the entry whose `site` matches the computer label/`settings.site`; if the local site or its galaxy is unknown, no galaxy filtering is applied. Cross-galaxy entries must opt-in on both sides via `intergalaxial = { "*", "SiteName" }`: an entry is shown if the local gate's `intergalaxial` list allows the remote site (or `*`) *and* the remote entry's `intergalaxial` list allows the local site (or `*`). Manual dialing stays universal to prevent soft-locks.

### Dialer settings (`settings.lua` / `dial_settings.lua`)
`dial.lua` creates `settings.lua` beside itself if missing; `dial_settings.lua` holds the same defaults used by `updater`/`client` when seeding a fresh install:
```lua
return {
    site = nil,               -- optional site name for address filtering
    rs_fast_dial = "left",    -- redstone input: high = fast-dial symbols; nil to ignore
    rs_income_alarm = nil,    -- optional redstone output while an incoming wormhole is active
    alarm_protocol = "sg_alarm", -- rednet protocol used for incoming-wormhole alarms
    rs_safe_env = nil,        -- side to detect redstone signal if the local environment is safe (set to true/false to force always safe/unsafe)
    timeout = 60,             -- seconds before outbound wormholes auto-disconnect
    dialing_colour = "green", -- colour to use during dialing progress
    energy_protocol = "sg_aux", -- rednet protocol used when sending energy updates
}
```

### Alarm settings (`settings.lua` / `alarm_settings.lua`)
`alarm.lua` also bootstraps a `settings.lua` if missing; `alarm_settings.lua` is the default template:
```lua
return {
    side_toggle = "front",
    side_input = nil,   -- optional redstone input fallback; nil to rely solely on rednet
    phase_sides = { "left", "top", "right" },
    flash_delay = 0.28,
    status_flash_duration = 0.25,
    status_flash_interval = 0.75,
    debounce_reads = 1,
    alarm_protocol = "sg_alarm", -- rednet protocol used for incoming-wormhole alarms
    site = nil,            -- optional site filter for alarm broadcasts
}
```

### Reactor monitor settings (`settings.lua` / `reactor_settings.lua`)
`reactor.lua` creates `settings.lua` beside itself if missing; `reactor_settings.lua` is the default template:
```lua
return {
    monitor_scale = 1,            -- monitor text scale
    refresh_interval = 1,         -- seconds between updates
    reactor_name = nil,           -- optional peripheral name; nil auto-detects
    induction_name = nil,         -- optional induction port name; nil auto-detects
    auto_shutdown_threshold = 0.8, -- shut off reactor when internal energy exceeds this fraction (0-1)
    auto_start_threshold = 0.2,    -- turn reactor back on when energy falls below this fraction (0-1)
}
```

### Client config (`client_config.lua`)
Created on first run of `client.lua`:
```lua
return {
    side = "back",      -- wireless/ender modem side
    primary_file = "dial", -- program to run after fetching (without .lua)
    scope = nil,        -- optional scope override; defaults to primary_file (dialing/alarming/server)
}
```
Run `client setup` to create/refresh this file; pass a second arg to set `primary_file` (e.g. `client setup alarm`). `setup` deletes any existing `client_config.lua` before seeding it.

## Run the Dialer (`dial.lua`)
- Make sure `dial.lua`, `utils.lua`, `addresses.lua`, and `settings.lua` are on the controller computer (or run `client setup` to fetch/seed them).
- Start with `dial`. The monitor shows the address list; tap a row or type its number to dial.
- Manual entry: type numbers separated by spaces/commas/dashes; 6 symbols auto-append `0` as origin.
- Fast/slow dialing is chosen by the `rs_fast_dial` input; the bottom-right corner shows `>` when fast-dial is active, `#` otherwise.
- Outbound wormholes display a countdown and auto-disconnect after `timeout` seconds; tap the monitor to drop early.
- Incoming wormholes paint a red banner, count open time, broadcast an alarm over rednet (`alarm_protocol` via `alarm_modem_side`/`client_config.side` or any modem), optionally raise `rs_income_alarm`, send the local env status when `rs_safe_env` is configured, and let you tap the monitor to send `sg_disconnect` to the remote gate when supported.
- The dialer shows remote env status messages during an active outgoing wormhole (when the other side reports one).
- If the computer reboots while a wormhole is open, the UI resumes and shows the active connection.

## Alarm (`alarm.lua`)
- Listens for rednet alarm broadcasts on `alarm_protocol` (modem from `modem_side`, `client_config.side`, or the first available) and can also react to `side_input` redstone if set.
- Outputs: `side_toggle` (default `front`) for the siren plus cycling lights on `phase_sides` (`left`, `top`, `right`).
- On-screen buttons: `[ TOGGLE SIREN ]` toggles the siren output; `[ CANCEL ALARM ]` silences while the input stays high.

## Reactor Monitor (`reactor.lua`)
- Auto-detects an Extreme Reactors/Bigger Reactors controller and a Mekanism induction port (or use names in `settings.lua`).
- Shows reactor state, energy, output, fuel level, fuel use/reactivity, temperatures, and matrix energy/input/output.
- Runs on a monitor if present; otherwise updates the terminal.

## File Sync (optional)
- `sync/file_list.lua`: defines scopes (`manifest`, `shared`, `dialing`, `alarming`, `server`) and the files each scope provides; edit to add your own files.
- `sync/server.lua`: open a modem, host `files_request` as `SGServer`, and serve files from `disk/<path-from-file_list>`.
- `sync/client.lua`: looks up `SGServer`, downloads the configured files, writes them atomically, and runs `primary_file` (default `dial`). Use `client setup` the first time to pull required files (`settings.lua`, `addresses.lua`, etc.), optionally with a second arg to set the primary program (`client setup alarm`); later runs can just call `client` to refresh and launch. `client_config.scope` can force a specific scope if needed.

### Multi-disk server storage
If the server disk is too small, you can split files across multiple disk drives by adding `disk = "disk2"` (or similar) to entries in `sync/file_list.lua`. The updater and server will read that field and store/serve the file from that disk directory. Keep `sync/file_list.lua` itself on the default `disk` so the server can `require` it.
