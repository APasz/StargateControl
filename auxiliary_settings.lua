return {
    site = nil,
    -- optional site name to filter energy updates (falls back to computer label suffix)
    protocol = "sg_aux",
    -- optional rednet protocol filter; nil listens to any protocol
    monitor_scale = 1,
    -- monitor text scale
    receive_timeout = 5,
    -- seconds between listen heartbeats (used to refresh the modem status)
}
