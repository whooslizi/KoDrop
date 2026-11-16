local DataStorage = require("datastorage")
local Device = require("device")
local InfoMessage = require("ui/widget/infomessage")
local InputDialog = require("ui/widget/inputdialog")
local JSON = require("json")
local LuaSettings = require("luasettings")
local NetworkListener = require("ui/network/networklistener")
local NetworkMgr = require("ui/network/manager")
local PluginShare = require("pluginshare")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local ffiUtil = require("ffi/util")
local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")
local socket = require("socket")
local _ = require("gettext")
local T = ffiUtil.template

-- dofile: names like "api" could clash with other plugins in package.loaded
local plugin_dir = debug.getinfo(1, "S").source:match("^@(.*)/[^/]*$")
local Server = dofile(plugin_dir .. "/server.lua")
local Api = dofile(plugin_dir .. "/api.lua")
local html = dofile(plugin_dir .. "/webui.lua")

local DEFAULT_PORT = 3636
local DEFAULT_ROOT = "/mnt/us"
local DEFAULT_IDLE = 15

local settings = LuaSettings:open(DataStorage:getSettingsDir() .. "/kodrop.lua")
local function port() return settings:readSetting("port") or DEFAULT_PORT end
local function root() return settings:readSetting("root") or DEFAULT_ROOT end
local function idle_minutes() return settings:readSetting("idle_minutes") or DEFAULT_IDLE end

-- module-level: the plugin is re-instantiated on FileManager/Reader switches
local running

local function firewall(op, p)
    if not Device:isKindle() then return end
    os.execute(string.format("iptables -%s INPUT -p tcp --dport %d -m conntrack --ctstate NEW,ESTABLISHED -j ACCEPT 2>/dev/null", op, p))
    os.execute(string.format("iptables -%s OUTPUT -p tcp --sport %d -m conntrack --ctstate ESTABLISHED -j ACCEPT 2>/dev/null", op, p))
end

local function stay_awake(on)
    if on then
        running.pause = PluginShare.pause_auto_suspend
        PluginShare.pause_auto_suspend = true
        UIManager:preventStandby()
        if Device:isKindle() then os.execute("lipc-set-prop com.lab126.powerd preventScreenSaver 1") end
        NetworkListener:_unscheduleActivityCheck()
    else
        PluginShare.pause_auto_suspend = running.pause
        UIManager:allowStandby()
        if Device:isKindle() and not PluginShare.keepalive then
            os.execute("lipc-set-prop com.lab126.powerd preventScreenSaver 0")
        end
        if G_reader_settings:isTrue("auto_disable_wifi") and NetworkMgr:isConnected() then
            NetworkListener:_scheduleActivityCheck()
        end
    end
end

local function local_ip()
    local ok, ip = pcall(function()
        local ni = require("ffi/netinfo"):new()
        local found
        for _, iface in ipairs(ni:retrieve()) do
            if iface.ipv4 and (iface.wireless or not found) then
                found = iface.ipv4:match("^[^ ]+")
                if iface.wireless then break end
            end
        end
        ni:free()
        return found
    end)
    return ok and ip or nil
end

local pending_refresh = {}
local function refresh_fm()
    local fm = require("apps/filemanager/filemanager").instance
    local fc = fm and fm.file_chooser
    if fc and fc.path and (pending_refresh[fc.path] or pending_refresh[ffiUtil.realpath(fc.path) or ""]) then
        fc:refreshPath()
    end
    pending_refresh = {}
end

local function safe(fn)
    return function(...)
        local ok, err = pcall(fn, ...)
        if not ok then logger.warn("KoDrop: bookkeeping failed:", err) end
    end
end
local hooks = {
    changed = function(dir)
        pending_refresh[dir] = true
        UIManager:unschedule(refresh_fm)
        UIManager:scheduleIn(1, refresh_fm)
    end,
    moved = safe(function(old, new, is_file)
        local ReadHistory, ReadCollection = require("readhistory"), require("readcollection")
        if is_file then
            require("docsettings").updateLocation(old, new)
            ReadHistory:updateItem(old, new)
            ReadCollection:updateItem(old, new)
        else
            ReadHistory:updateItemsByPath(old, new)
            ReadCollection:updateItemsByPath(old, new)
        end
    end),
    deleted = safe(function(path, is_file)
        local ReadHistory, ReadCollection = require("readhistory"), require("readcollection")
        if is_file then
            require("ui/widget/booklist").resetBookInfoCache(path)
            require("docsettings").updateLocation(path)
            ReadHistory:fileDeleted(path)
            ReadCollection:removeItem(path)
        else
            ReadHistory:folderDeleted(path)
            ReadCollection:removeItemsByPath(path)
        end
    end),
}

local stop

local function poll()
    if not running then return end
    local ok, err = pcall(running.server.tick, running.server)
    if not ok then logger.warn("KoDrop: tick failed:", err) end
    local idle = idle_minutes()
    if idle > 0 and not running.server:busy() and socket.gettime() - running.server.last_activity > idle * 60 then
        stop()
        UIManager:show(InfoMessage:new{ text = T(_("KoDrop stopped after %1 minutes without activity."), idle), timeout = 5 })
        return
    end
    UIManager:scheduleIn(running.server:busy() and 0.02 or 0.25, poll)
end

local function url()
    local ip = local_ip()
    return ip and string.format("http://%s:%d", ip, running.port)
end

local function show_address()
    if not running then return end
    local ip = local_ip()
    UIManager:show(InfoMessage:new{
        text = T(_("KoDrop is running.\n\nIP: %1\nPort: %2\n\nOpen in a browser:\n%3"),
            ip or _("not found (is Wi-Fi connected?)"), running.port,
            ip and string.format("http://%s:%d", ip, running.port) or "-"),
    })
end

local function show_qr()
    local u = running and url()
    if u then UIManager:show(require("ui/widget/qrmessage"):new{ title = "KoDrop", text = u }) end
end

local function start()
    if running then return end
    local api, err = Api.new{
        root = root(),
        protect = ffiUtil.realpath(DataStorage:getDataDir()),
        pin = settings:readSetting("pin"),
        html = html, lfs = lfs, realpath = ffiUtil.realpath, json = JSON,
        purge_dir = ffiUtil.purgeDir, hooks = hooks,
    }
    local srv
    if api then srv, err = Server.new(port(), api, JSON.encode) end
    if not srv then
        UIManager:show(InfoMessage:new{ icon = "notice-warning", text = T(_("Failed to start KoDrop:\n%1"), tostring(err)) })
        return
    end
    firewall("D", port()) -- in case a crash left one behind
    firewall("A", port())
    running = { server = srv, port = port() }
    stay_awake(true)
    UIManager:scheduleIn(0.1, poll)
    logger.info("KoDrop: listening on port", running.port)
    show_address()
end

stop = function()
    if not running then return end
    UIManager:unschedule(poll)
    running.server:close()
    firewall("D", running.port)
    stay_awake(false)
    running = nil
    logger.info("KoDrop: stopped")
end

local function restart_if_running()
    if running then stop() start() end
end

local function ask(title, value, hint, on_ok)
    local dlg
    dlg = InputDialog:new{
        title = title,
        input = value,
        input_hint = hint,
        input_type = "number",
        buttons = {{
            { text = _("Cancel"), id = "close", callback = function() UIManager:close(dlg) end },
            { text = _("OK"), is_enter_default = true, callback = function()
                local v = dlg:getInputText()
                UIManager:close(dlg)
                on_ok(v)
            end },
        }},
    }
    UIManager:show(dlg)
    dlg:onShowKeyboard()
end

local function save(key, value)
    settings:saveSetting(key, value)
    settings:flush()
    restart_if_running()
end

local KoDrop = WidgetContainer:extend{
    name = "kodrop",
    is_doc_only = false,
}

function KoDrop:init()
    self.ui.menu:registerToMainMenu(self)
end

function KoDrop:onSuspend() stop() end
function KoDrop:onExit() stop() end
function KoDrop:onRestart() stop() end

function KoDrop:onNetworkConnected()
    -- NetworkListener reschedules its Wi-Fi idle check on reconnect
    if running then UIManager:nextTick(function() NetworkListener:_unscheduleActivityCheck() end) end
end

function KoDrop:addToMainMenu(menu_items)
    menu_items.kodrop = {
        text = _("KoDrop"),
        sorting_hint = "tools",
        sub_item_table = {
            {
                text = _("Run server"),
                checked_func = function() return running ~= nil end,
                keep_menu_open = true,
                callback = function(touchmenu_instance)
                    if running then
                        stop()
                        touchmenu_instance:updateItems()
                    else
                        NetworkMgr:runWhenConnected(function()
                            start()
                            touchmenu_instance:updateItems()
                        end)
                    end
                end,
            },
            {
                text_func = function()
                    return running and (url() or T(_("Port %1 (no Wi-Fi IP)"), running.port)) or _("Address: not running")
                end,
                enabled_func = function() return running ~= nil end,
                callback = show_address,
            },
            {
                text = _("Show QR code"),
                enabled_func = function() return running ~= nil end,
                callback = show_qr,
                separator = true,
            },
            {
                text_func = function() return T(_("Port: %1"), port()) end,
                keep_menu_open = true,
                callback = function(touchmenu_instance)
                    ask(_("KoDrop port"), tostring(port()), _("1024-65535, default 3636"), function(v)
                        local n = tonumber(v)
                        if n and n >= 1024 and n <= 65535 and n == math.floor(n) then
                            save("port", n)
                            touchmenu_instance:updateItems()
                        end
                    end)
                end,
            },
            {
                text_func = function() return T(_("Root folder: %1"), root()) end,
                keep_menu_open = true,
                callback = function(touchmenu_instance)
                    UIManager:show(require("ui/widget/pathchooser"):new{
                        select_file = false,
                        show_files = false,
                        path = root(),
                        onConfirm = function(path)
                            save("root", path)
                            touchmenu_instance:updateItems()
                        end,
                    })
                end,
            },
            {
                text_func = function()
                    return settings:readSetting("pin") and _("PIN: set") or _("PIN: none")
                end,
                keep_menu_open = true,
                callback = function(touchmenu_instance)
                    ask(_("4-digit PIN (empty for none)"), settings:readSetting("pin") or "", "", function(v)
                        if v == "" then
                            save("pin", nil)
                        elseif v:match("^%d%d%d%d$") then
                            save("pin", v)
                        else
                            UIManager:show(InfoMessage:new{ text = _("The PIN must be exactly 4 digits.") })
                            return
                        end
                        touchmenu_instance:updateItems()
                    end)
                end,
            },
            {
                text_func = function()
                    local n = idle_minutes()
                    return n > 0 and T(_("Auto-stop after %1 min idle"), n) or _("Auto-stop: never")
                end,
                keep_menu_open = true,
                callback = function(touchmenu_instance)
                    ask(_("Stop after N idle minutes (0 = never)"), tostring(idle_minutes()), "15", function(v)
                        local n = tonumber(v)
                        if n and n >= 0 then
                            settings:saveSetting("idle_minutes", math.floor(n))
                            settings:flush()
                            touchmenu_instance:updateItems()
                        end
                    end)
                end,
            },
        },
    }
end

return KoDrop
