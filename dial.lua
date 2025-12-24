package.path = package.path .. ";disk/?.lua;disk/?/init.lua"
local SG_UTILS = require("utils")

local SETTINGS_PATH = "settings.lua"
local DEFAULT_SETTINGS_CONTENT = [[return {
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
    iris_protocol = "sg_iris",
    -- rednet protocol used when receiving iris control requests
}
]]

local function load_or_create_settings()
    if fs.exists(SETTINGS_PATH) then
        local ok, config = pcall(require, "settings")
        if ok then
            return config
        end
        error(config, 0)
    end

    local handle = fs.open(SETTINGS_PATH, "w")
    if not handle then
        error("Missing settings.lua and unable to create it", 0)
    end

    handle.write(DEFAULT_SETTINGS_CONTENT)
    handle.close()

    local ok, config = pcall(require, "settings")
    if not ok then
        error(config, 0)
    end

    print("Created default settings.lua; edit it to change site, etc")
    return config
end
local SG_SETTINGS = load_or_create_settings()

local function get_client_config_side()
    local ok, cfg = pcall(require, "client_config")
    if not ok or type(cfg) ~= "table" then
        return nil
    end
    if type(cfg.side) == "string" then
        return cfg.side
    end
    return nil
end
local CLIENT_MODEM_SIDE = get_client_config_side()

local _, LOCAL_SITE = SG_UTILS.get_site(SG_SETTINGS.site)

local INF_GATE = SG_UTILS.get_inf_gate()

local INF_RS = SG_UTILS.get_inf_rs()
SG_UTILS.get_inf_mon()

local SG_ADDRESSES = SG_UTILS.filtered_addresses(require("addresses"), SG_SETTINGS.site)

local STATE = {
    connected = false,
    outbound = nil,
    timeout_remaining = nil,
    gate = nil,
    gate_id = nil,
    disconnected_early = false,
    waiting_disconnect = false,
    incoming_seconds = 0,
    pending_timeout = nil,
    countdown_deadline = nil,
    countdown_pending = false,
    countdown_pending_at = nil,
    countdown_forced = false,
    top_lines = 0,
    last_feedback = nil,
    last_feedback_at = nil,
}
local TICK_INTERVAL = 0.25 -- scheduler tick in seconds
local TIMER_SCHEDULE = {}
local ALARM_STATE = {
    modem_side = nil,
    warned_config = false,
    warned_missing = false,
    last_active = nil,
    last_sent_at = nil,
}
local ALARM_PROTOCOL = SG_SETTINGS.alarm_protocol or "sg_alarm"
local ENERGY_STATE = {
    modem_side = nil,
    warned_config = false,
    warned_missing = false,
}
local ENERGY_PROTOCOL = SG_SETTINGS.energy_protocol or "sg_aux"
local IRIS_STATE = {
    modem_side = nil,
    warned_config = false,
    warned_missing = false,
}
local IRIS_PROTOCOL = SG_SETTINGS.iris_protocol or "sg_iris"

local CANCEL_EVENT_BLACKLIST = {
    redstone = true,
    stargate_deconstructing_entity = true,
    stargate_reconstructing_entity = true,
    stargate_message = true,
    stargate_message_received = true,
}
local FEEDBACK_BLACKLIST_TYPES = {
    info = true,
}
local FEEDBACK_BLACKLIST_CODES = {}

local ctx = {
    utils = SG_UTILS,
    settings = SG_SETTINGS,
    state = STATE,
    addresses = SG_ADDRESSES,
    local_site = LOCAL_SITE,
    inf_gate = INF_GATE,
    inf_rs = INF_RS,
    alarm_state = ALARM_STATE,
    alarm_protocol = ALARM_PROTOCOL,
    energy_state = ENERGY_STATE,
    energy_protocol = ENERGY_PROTOCOL,
    iris_state = IRIS_STATE,
    iris_protocol = IRIS_PROTOCOL,
    client_modem_side = CLIENT_MODEM_SIDE,
    timer_schedule = TIMER_SCHEDULE,
    tick_interval = TICK_INTERVAL,
    tick_timer_id = nil,
    cancel_event_blacklist = CANCEL_EVENT_BLACKLIST,
    feedback_blacklist_types = FEEDBACK_BLACKLIST_TYPES,
    feedback_blacklist_codes = FEEDBACK_BLACKLIST_CODES,
}

require("dial_comm").init(ctx)
require("dial_gate").init(ctx)
require("dial_ui").init(ctx)
require("dial_timers").init(ctx)
require("dial_flow").init(ctx)
require("dial_events").init(ctx)

local reset_top = ctx.reset_top
local resume_active_wormhole = ctx.resume_active_wormhole
local send_alarm_update = ctx.send_alarm_update
local screen = ctx.screen
local start_timer = ctx.start_timer
local schedule_tick = ctx.schedule_tick
local handle_terminate = ctx.handle_terminate
local dispatch_event = ctx.dispatch_event

local function show_error(err)
    local message = tostring(err or "unknown error")
    SG_UTILS.prepare_monitor(1, true)
    if reset_top then
        reset_top()
    end
    SG_UTILS.set_text_colour(colours.red)
    SG_UTILS.update_line("! ERROR !", 1)
    SG_UTILS.reset_text_colour()
    SG_UTILS.update_line(message, 2)
    SG_UTILS.update_line("See terminal for traceback", 3)
end

local function main_loop()
    local resumed = resume_active_wormhole and resume_active_wormhole()
    if not resumed then
        if send_alarm_update then
            send_alarm_update(false)
        end
        if screen then
            screen()
        end
    elseif STATE.outbound ~= false then
        if send_alarm_update then
            send_alarm_update(false)
        end
    end
    if start_timer then
        start_timer("energy", 1)
    end
    if schedule_tick then
        schedule_tick(0)
    end
    if ctx.open_iris_modem then
        ctx.open_iris_modem()
    end
    while true do
        local event = { os.pullEventRaw() }
        if event[1] == "terminate" then
            if handle_terminate and handle_terminate() then
                break
            end
        else
            local should_stop = dispatch_event and dispatch_event(event)
            if should_stop then
                break
            end
        end
    end
end

local function handle_error(err)
    show_error(err)
    return debug.traceback(err, 2)
end

local ok, err = xpcall(main_loop, handle_error)
if not ok then
    print(err)
end
