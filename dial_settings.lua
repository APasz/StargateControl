return {
    site = nil,
    -- optional site override for address filtering
    rs_fast_dial = "left",
    -- side to detect redstone signal meaning to fast dial
    rs_income_alarm = nil,
    -- side to output redstone signal during incoming wormhole
    alarm_protocol = "sg_alarm",
    -- rednet protocol used when sending incoming wormhole alarms
    rs_safe_env = nil,
    -- side to detect redstone signal if the local environment is safe (set to true to force always-safe)
    timeout = 60,
    -- time until wormhole is autoclosed
    countdown_failsafe_delay = 3,
    -- seconds before outbound disconnect countdown starts if open events are missing (0 disables)
    reset_on_gate_reset = true,
    -- when true, clear local state and UI on stargate_reset events
    dialing_colour = "green",
    -- colour to use during dialing progress
    energy_modem_side = nil,
    -- side with modem to broadcast energy (nil auto-detects)
    energy_protocol = "sg_aux",
    -- rednet protocol used when sending energy updates
}
