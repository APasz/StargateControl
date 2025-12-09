# Stargate Control

ComputerCraft/CC:Tweaked scripts for driving a Stargate from a monitor UI, with an optional siren and a small rednet-based file distributor.

## Components
- `dial.lua` — main Stargate controller; renders a monitor menu, dials addresses (fast/slow), tracks active wormholes, and auto-disconnects on a timer.
- `utils.lua` — shared helpers for monitors, redstone, address formatting, and dialing.
- `settings.lua` — user-editable config for redstone sides, timeout, and saved addresses.
- `alarm.lua` — simple siren/indicator driven by a redstone input with on-screen buttons to silence or toggle the siren.
- `server.lua` / `client.lua` — rednet file host/fetcher to keep multiple computers updated from a single source.

## Requirements
- CC:Tweaked (or ComputerCraft) with access to a Stargate interface peripheral: `advanced_crystal_interface`, `crystal_interface`, or `basic_interface`.
- A monitor (color preferred). The programs will still log to the terminal if none is present.
- Optional redstone relay; otherwise the computer’s native redstone API is used.
- Wireless/wired modems for rednet if you use the server/client updater.

## Wiring Notes
- Place the computer next to the Stargate interface (or via network cables). The code uses `peripheral.find`, so any side works.
- Attach a monitor; scale is managed automatically.
- `fast_dial_rs_side` (default `right` in `settings.lua`) is a redstone input. High = engage-symbol “fast” dialing; low/nil = rotate/slow dialing.
- `incom_alarm_rs_side` can be set to a redstone output that pulses when an incoming wormhole starts (e.g., feed into a siren computer running `alarm.lua`).

## Configure
Edit `settings.lua` before running:

```lua
return {
    fast_dial_rs_side = "right",   -- redstone input for fast-dial toggle (set to nil to ignore)
    incom_alarm_rs_side = nil,     -- redstone output for incoming-wormhole alarm (set a side or nil)
    timeout = 45,                  -- seconds before outbound wormholes auto-disconnect
    addresses = {
        { name = "Earth", address = { 30, 18, 9, 5, 25, 14, 31, 15, 0 } },
        -- add more entries here; addresses accept 7–9 numbers
    },
}
```

Tips:
- Touch the monitor or press any key while dialing to cancel.
- You can type a full address instead of choosing a preset: enter numbers separated by spaces/commas/dashes; 6 symbols automatically append `0` as origin.
- The bottom-right monitor corner shows `>` when the fast-dial input is high, `#` otherwise.

## Run the Dialer (`dial.lua`)
1) Ensure `dial.lua`, `utils.lua`, and your `settings.lua` are on the controller computer (or run `client.lua` to fetch them from the rednet server).  
2) Start the program: `dial`.  
3) Select a destination by tapping the monitor row or typing its list number; the UI shows dialing progress.  
4) Active wormholes show status + a disconnect countdown (`timeout`). Tap the monitor to drop the connection early.  
5) Incoming wormholes draw a red banner, count open time, and raise the `incom_alarm_rs_side` output if configured; tapping the monitor sends `sg_disconnect` to the remote gate when supported.
6) If the computer reboots while a wormhole is open, `dial.lua` tries to detect and resume the active state.

## Alarm (`alarm.lua`)
- Intended for a separate computer/monitor fed by the dialer’s `incom_alarm_rs_side` (or any redstone input).  
- Inputs: `side_input` (default `bottom`) starts/stops the alarm.  
- Outputs: `side_toggle` (default `front`) for a siren, plus cycling lights on `phase_sides` (`left`, `top`, `right`).  
- On-screen buttons: `[ TOGGLE SIREN ]` enables/disables the siren output without clearing the alarm input; `[ CANCEL ALARM ]` silences while the input stays high.  
- Debounce and flash timings are configurable at the top of `alarm.lua`.

## File Sync (optional)
- `server.lua`: host the programs over rednet. It reads the files from `disk/<name>.lua` (dial, alarm, utils, settings) and serves them as `SGServer` on the `files_request` protocol.  
- `client.lua`: opens a modem, looks up `SGServer`, downloads the listed files, writes them atomically, and runs `dial.lua` (falls back to local copies if the server is unreachable).  
- Adjust `modem_side` in each file to match your modem placement. Keep a disk with the latest scripts mounted on the server computer.

