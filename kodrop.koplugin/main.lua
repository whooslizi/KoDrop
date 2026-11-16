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

local VERSION = dofile(plugin_dir .. "/_meta.lua").version
local REPO = "whooslizi/KoSend"

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

-- redirects followed by hand: GitHub sends release assets to another https host
local function http_get(url)
    local http, ltn12, socketutil = require("socket.http"), require("ltn12"), require("socketutil")
    socketutil:set_timeout(socketutil.FILE_BLOCK_TIMEOUT, socketutil.FILE_TOTAL_TIMEOUT)
    for __ = 1, 5 do
        local body = {}
        local ___, code, headers = http.request{ url = url, redirect = false, sink = ltn12.sink.table(body) }
        if code == 301 or code == 302 or code == 307 or code == 308 then
            url = headers.location
        else
            socketutil:reset_timeout()
            return code == 200, table.concat(body), code
        end
    end
    socketutil:reset_timeout()
    return false, "", "too many redirects"
end

local function install(url)
    local ok, data, code = http_get(url)
    if not ok then return false, T(_("Download failed: %1"), tostring(code)) end
    local base = ffiUtil.realpath(plugin_dir)
    local zip, tmp, old = base .. ".zip", base .. ".new", base .. ".old"
    local f = io.open(zip, "wb")
    if not f then return false, T(_("Cannot write %1"), zip) end
    f:write(data)
    f:close()
    if lfs.attributes(tmp) then ffiUtil.purgeDir(tmp) end
    if lfs.attributes(old) then ffiUtil.purgeDir(old) end
    lfs.mkdir(tmp)

    local err
    local arc = require("ffi/archiver").Reader:new()
    if arc:open(zip) then
        for entry in arc:iterate() do
            local rel = entry.mode == "file" and entry.path:match("^kodrop%.koplugin(/.+)$")
            if rel and not arc:extractToPath(entry.path, tmp .. rel) then
                err = arc.err or _("Extraction failed")
                break
            end
        end
        arc:close()
    else
        err = _("Invalid archive")
    end
    os.remove(zip)
    if not err and not lfs.attributes(tmp .. "/main.lua") then err = _("main.lua missing from archive") end
    -- swap whole folders so a failed update never leaves a half-written plugin
    if not err and not os.rename(base, old) then err = _("Cannot replace the plugin folder") end
    if not err and not os.rename(tmp, base) then
        os.rename(old, base)
        err = _("Cannot replace the plugin folder")
    end
    if err then
        ffiUtil.purgeDir(tmp)
        return false, err
    end
    ffiUtil.purgeDir(old)
    return true
end

local function check_update()
    local checking = InfoMessage:new{ text = _("Checking for updates…") }
    UIManager:show(checking)
    UIManager:forceRePaint()
    local ok, body = http_get("https://api.github.com/repos/" .. REPO .. "/releases/latest")
    UIManager:close(checking)
    local okj, release = pcall(JSON.decode, body, JSON.decode.simple)
    if not ok or not okj or type(release) ~= "table" or not release.tag_name then
        UIManager:show(InfoMessage:new{ icon = "notice-warning", text = _("Could not check for updates.") })
        return
    end
    if release.tag_name == VERSION then
        UIManager:show(InfoMessage:new{ text = T(_("KoDrop %1 is up to date."), VERSION) })
        return
    end
    local url
    for __, asset in ipairs(release.assets or {}) do
        if asset.name == "kodrop.koplugin.zip" then url = asset.browser_download_url end
    end
    if not url then
        UIManager:show(InfoMessage:new{ icon = "notice-warning", text = _("The latest release has no kodrop.koplugin.zip.") })
        return
    end
    UIManager:show(require("ui/widget/confirmbox"):new{
        text = T(_("KoDrop %1 is available (installed: %2).\n\nUpdate now?"), release.tag_name, VERSION),
        ok_text = _("Update"),
        ok_callback = function()
            stop()
            local done, err = install(url)
            if done then
                UIManager:askForRestart(T(_("KoDrop updated to %1. Restart KOReader to finish."), release.tag_name))
            else
                UIManager:show(InfoMessage:new{ icon = "notice-warning", text = T(_("Update failed:\n%1"), err) })
            end
        end,
    })
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
        sorting_hint = "network",
        checked_func = function() return running ~= nil end,
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
                separator = true,
            },
            {
                text = T(_("Check for update (%1)"), VERSION),
                callback = function() NetworkMgr:runWhenOnline(check_update) end,
            },
        },
    }
end

return KoDrop
