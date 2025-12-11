return {
    site = nil,
    -- optional location name for address filtering (e.g., "Earth"); falls back to computer label
    fast_dial_rs_side = "left",
    -- side to detect redstone signal meaning to fast dial
    incom_alarm_rs_side = nil,
    -- side to output redstone signal during incoming wormhole
    timeout = 60,
    -- time until wormhole is autoclosed
}
