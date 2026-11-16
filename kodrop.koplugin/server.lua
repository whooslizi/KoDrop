local socket = require("socket")

local CLOSED = {}
local TICK_BUDGET = 0.05
local IDLE_TIMEOUT = 60
local MAX_LINE = 8192
local MAX_HEADERS = 64

local STATUS = {
    [200] = "OK", [400] = "Bad Request", [401] = "Unauthorized", [403] = "Forbidden",
    [404] = "Not Found", [405] = "Method Not Allowed", [409] = "Conflict",
    [411] = "Length Required", [413] = "Payload Too Large", [429] = "Too Many Requests",
    [500] = "Internal Server Error", [507] = "Insufficient Storage",
}

local Conn = {}
Conn.__index = Conn

function Conn:pause(blocked)
    if coroutine.yield(blocked or false) == "abort" then error(CLOSED, 0) end
end

function Conn:recv(pattern)
    local partial = ""
    while true do
        local data, err, part
        if pattern == "*l" then
            data, err, part = self.sock:receive("*l", partial)
        else
            data, err, part = self.sock:receive(pattern)
        end
        if data then self.touched = socket.gettime() return data end
        if err ~= "timeout" then error(CLOSED, 0) end
        if pattern ~= "*l" and part ~= "" then self.touched = socket.gettime() return part end
        partial = part
        if #partial > MAX_LINE then error(CLOSED, 0) end
        self:pause(true)
    end
end

function Conn:send(data)
    local i = 1
    while i <= #data do
        local last, err, lastp = self.sock:send(data, i)
        if last then
            i = last + 1
        else
            if err ~= "timeout" then error(CLOSED, 0) end
            i = lastp + 1
            self:pause(true)
        end
        self.touched = socket.gettime()
    end
end

function Conn:head(status, headers)
    local out = { string.format("HTTP/1.0 %d %s", status, STATUS[status] or "Unknown") }
    for k, v in pairs(headers) do out[#out + 1] = k .. ": " .. v end
    out[#out + 1] = "Connection: close"
    out[#out + 1] = "Cache-Control: no-store"
    out[#out + 1] = "\r\n"
    self.headers_sent = true
    self:send(table.concat(out, "\r\n"))
end

function Conn:respond(status, ctype, body, extra)
    local h = extra or {}
    h["Content-Type"] = ctype
    h["Content-Length"] = tostring(#body)
    self:head(status, h)
    self:send(body)
end

function Conn:body(max)
    local len = tonumber(self.req.headers["content-length"] or "0")
    if not len or len < 0 then error({ status = 411, msg = "Bad Content-Length" }, 0) end
    if len > max then error({ status = 413, msg = "Body too large" }, 0) end
    local parts, got = {}, 0
    while got < len do
        local s = self:recv(len - got)
        parts[#parts + 1] = s
        got = got + #s
    end
    return table.concat(parts)
end

local function unescape(s)
    return (s:gsub("+", " "):gsub("%%(%x%x)", function(h) return string.char(tonumber(h, 16)) end))
end

local Server = {}
Server.__index = Server

function Server.new(port, handler, json_encode)
    local sock, err = socket.bind("*", port)
    if not sock then return nil, err end
    sock:settimeout(0)
    return setmetatable({
        sock = sock, handler = handler, encode = json_encode,
        conns = {}, last_activity = socket.gettime(),
    }, Server)
end

function Server:serve(c)
    local ok, err = pcall(function()
        local line = c:recv("*l")
        local method, target = line:match("^(%u+) (%S+) HTTP/1%.%d$")
        if not method then error({ status = 400, msg = "Bad request line" }, 0) end
        local headers = {}
        local count = 0
        while true do
            local h = c:recv("*l")
            if h == "" then break end
            count = count + 1
            if count > MAX_HEADERS then error({ status = 400, msg = "Too many headers" }, 0) end
            local k, v = h:match("^([^:]+):%s*(.-)%s*$")
            if k then headers[k:lower()] = v end
        end
        local path, qs = target:match("^([^?]*)%??(.*)$")
        local query = {}
        for k, v in qs:gmatch("([^&=]+)=?([^&]*)") do query[unescape(k)] = unescape(v) end
        c.req = { method = method, path = path, query = query, headers = headers }
        self.handler(c)
    end)
    if ok or err == CLOSED then return end
    local status, msg = 500, tostring(err)
    if type(err) == "table" then status, msg = err.status or 500, err.msg or "Error" end
    if status == 500 then require("logger").warn("KoDrop: request failed:", msg) end
    if not c.headers_sent then
        pcall(c.respond, c, status, "application/json", self.encode({ error = msg }))
    end
end

function Server:tick()
    local now = socket.gettime()
    for _ = 1, 8 do
        local s = self.sock:accept()
        if not s then break end
        s:settimeout(0)
        s:setoption("tcp-nodelay", true)
        local c = setmetatable({ sock = s, touched = now }, Conn)
        c.co = coroutine.create(function() self:serve(c) end)
        table.insert(self.conns, c)
    end
    local deadline = now + TICK_BUDGET
    repeat
        local progressed = false
        for i = #self.conns, 1, -1 do
            local c = self.conns[i]
            local signal = nil
            if socket.gettime() - c.touched > IDLE_TIMEOUT then signal = "abort" end
            local ok, blocked = coroutine.resume(c.co, signal)
            if not ok then require("logger").warn("KoDrop: connection crashed:", blocked) end
            if coroutine.status(c.co) == "dead" then
                c.sock:close()
                table.remove(self.conns, i)
                self.last_activity = socket.gettime()
            elseif not blocked then
                progressed = true
                self.last_activity = socket.gettime()
            end
        end
    until not progressed or socket.gettime() >= deadline
end

function Server:busy()
    return #self.conns > 0
end

function Server:close()
    -- resume with "abort" so handlers delete their .part files
    for _, c in ipairs(self.conns) do
        if coroutine.status(c.co) == "suspended" then coroutine.resume(c.co, "abort") end
        c.sock:close()
    end
    self.conns = {}
    self.sock:close()
end

return Server
