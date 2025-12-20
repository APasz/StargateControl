return {
    monitor_scale = 1,
    -- monitor text scale
    refresh_interval = 1,
    -- seconds between updates
    reactor_name = nil,
    -- optional peripheral name; nil auto-detects
    induction_name = nil,
    -- optional induction port name; nil auto-detects
    auto_shutdown_threshold = 0.8,
    -- shut off reactor when internal energy exceeds this fraction (0-1)
    auto_start_threshold = 0.2,
    -- turn reactor back on when energy falls below this fraction (0-1)
}
