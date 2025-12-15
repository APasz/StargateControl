return {
    site = nil,
    -- optional site override for address filtering
    rs_fast_dial = "left",
    -- side to detect redstone signal meaning to fast dial
    rs_income_alarm = nil,
    -- side to output redstone signal during incoming wormhole
    rs_safe_env = nil,
    -- side to detect redstone signal if the local environment is safe (set to true to force always-safe)
    timeout = 60,
    -- time until wormhole is autoclosed
    dialing_colour = "green"
    -- colour to use during dialing progress
}
