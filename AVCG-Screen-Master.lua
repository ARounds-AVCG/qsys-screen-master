-- AVCG Screen Master. Q-SYS port of the AMX screen module. A.Rounds, AV Control Group.
-- Do not start this file with a --[[ block comment.

--------------------------------------------------------------------------------
-- CONSTANTS
--------------------------------------------------------------------------------
local VERSION     = "1.0.2"
local MODULE_NAME = "AVCG-Screen Master"

local MODE = { IP = "IP", HTTP = "HTTP" }
local CONN = { TEMP = "temporary", PERM = "permanent" }

local MAX_QUEUE   = 20
local QUEUE_TICK  = 0.1
local RX_TIMEOUT  = 3.0
local TEMP_HOLD   = 3.0

local function Now()
  return os.time()
end

--------------------------------------------------------------------------------
-- PROTOCOL DATABASE
--------------------------------------------------------------------------------
local Protocols = {}

local function copy(src)
  local dst = {}
  for k, v in pairs(src) do
    if type(v) == "table" then dst[k] = copy(v) else dst[k] = v end
  end
  return dst
end

--------------------------------------------------------------------------------
-- SCREEN TECHNICS  NETWORK  (TCP 3001)
--------------------------------------------------------------------------------
Protocols["SCREEN TECHNICS:NETWORK"] = {
  make = "SCREEN TECHNICS", model = "GENERIC SCREEN",
  transport = MODE.IP, port = 3001, connect = CONN.TEMP,
  terminator = "\r", eol = "cr",
  module_id = "1",
  tx = {
    up    = "30 1",
    down  = "33 1",
    stop  = "36 1",
    query = "67 3781",
  },
  rx = {
    up          = "167,    6,",
    down        = "167,    7,",
    stop        = "167,   10,",
    moving_up   = "167,    0,",
    moving_down = "167,    1,",
  },
}

--------------------------------------------------------------------------------
-- GRANDVIEW  NETWORK  (HTTP 80)
-- Auth string taken from the original AMX module.
--------------------------------------------------------------------------------
Protocols["GRANDVIEW:NETWORK"] = {
  make = "GRANDVIEW", model = "GENERIC SCREEN",
  transport = MODE.HTTP, port = 80, connect = CONN.TEMP,
  auth = "M2MxNDQzZTYyMWZjNGFlNDJjOGM5NjMyOTY2ZDQ1ZjowZA",
  tx = {
    up   = "/Close.js?a=100",
    down = "/Open.js?a=100",
    stop = "/Stop.js?a=100",
  },
  rx = {},
}

--------------------------------------------------------------------------------
-- SORTED MODEL LIST
--------------------------------------------------------------------------------
local ModelList = {}
do
  for name in pairs(Protocols) do table.insert(ModelList, name) end
  table.sort(ModelList)
end

--------------------------------------------------------------------------------
-- STATE
--------------------------------------------------------------------------------
local Status = {
  position = "",          -- "Up" | "Down" | "Stop" | "Moving Up" | "Moving Down"
  comms_ok = false,
  last_cmd = "",
}

local Client = {
  address = "",
  port    = 0,
  status  = "disconnected",
}

local Screen = nil
local ScreenKey = ""
local Polling = true
local DebugOn = false

local Queue = {
  items    = {},
  inflight = false,
  sent     = "",
}

local LastTxAt = 0
local SuppressUI = false

--------------------------------------------------------------------------------
-- CONTROL HELPERS  (same style as Display Master)
--------------------------------------------------------------------------------
local function C(name)
  local ok, ctl = pcall(function() return Controls[name] end)
  if ok then return ctl end
  return nil
end

local function IsArray(c)
  return type(c) == "table" and c[1] ~= nil and c.EventHandler == nil
end

local function Elem(name, index)
  local c = C(name)
  if not c then return nil end
  if index then
    if IsArray(c) then return c[index] end
    if index == 1 then return c end
    return nil
  end
  return c
end

local function SetString(name, s, index)
  local el = Elem(name, index)
  if el and el.String ~= nil then el.String = tostring(s or "") end
end

local function SetBool(name, b, index)
  local el = Elem(name, index)
  if el and el.Boolean ~= nil then el.Boolean = not not b end
end

local function SetLegend(name, text, index)
  local el = Elem(name, index)
  if el then pcall(function() el.Legend = string.upper(tostring(text or "")) end) end
end

local function Bind(name, a, b)
  local index, fn
  if type(a) == "function" then fn, index = a, b else index, fn = a, b end
  if type(fn) ~= "function" then return end
  local c = C(name)
  if not c then return end
  if index then
    local el = Elem(name, index)
    if el then el.EventHandler = function(ctl) fn(ctl, index) end end
    return
  end
  if IsArray(c) then
    for i, el in ipairs(c) do el.EventHandler = function(ctl) fn(ctl, i) end end
  else
    c.EventHandler = function(ctl) fn(ctl, 1) end
  end
end

local function Pressed(ctl)
  if SuppressUI then return false end
  if not ctl then return true end
  if ctl.Boolean ~= nil then return ctl.Boolean == true end
  if ctl.Value ~= nil then return ctl.Value ~= 0 end
  return true
end

--------------------------------------------------------------------------------
-- LOGGING
--------------------------------------------------------------------------------
local function Notify(msg)
  print(string.format("[%s] %s", MODULE_NAME, msg))
  SetString("StatusText", msg)
  SetString("Status", msg)
  local log = C("EventLog")
  if log then
    local line = os.date("%H:%M:%S ") .. msg .. "\n"
    local cur = line .. (log.String or "")
    if #cur > 4000 then cur = cur:sub(1, 4000) end
    log.String = cur
  end
end

local function Debug(msg)
  if DebugOn then
    print(string.format("[%s][DBG] %s", MODULE_NAME, msg))
    SetString("DebugText", msg)
  end
end

local function ClearLogs()
  SetString("EventLog", "")
  SetString("TxLog", "")
  SetString("RxLog", "")
  SetString("DebugText", "")
  SetString("StatusText", "")
  print(string.format("[%s] logs cleared", MODULE_NAME))
end

--------------------------------------------------------------------------------
-- FEEDBACK
--------------------------------------------------------------------------------
local function PushFeedback()
  SuppressUI = true
  SetString("Position", Status.position)
  SetString("PositionFb", Status.position)
  SetBool("UpFb",    Status.position == "Up")
  SetBool("DownFb",  Status.position == "Down")
  SetBool("StopFb",  Status.position == "Stop")
  SetBool("CommsOk", Status.comms_ok)
  if Screen then
    SetString("MakeModel", Screen.make .. " " .. Screen.model)
  end
  local cs = C("ConnStatus")
  if cs then cs.String = Client.status end
  SuppressUI = false
end

--------------------------------------------------------------------------------
-- TRANSPORT
--------------------------------------------------------------------------------
local Tcp = TcpSocket.New()
Tcp.ReadTimeout = 0
Tcp.WriteTimeout = 0
Tcp.ReconnectTimeout = 0

local function IsConnected()
  return Client.status == "connected"
end

local function SendRaw(payload)
  if not payload or payload == "" then return false end
  local term = (Screen and Screen.terminator) or ""
  local frame = payload .. term
  LastTxAt = Now()
  Status.last_cmd = payload
  local dumped = frame:gsub("\r", "<CR>"):gsub("\n", "<LF>")
  SetString("TxLog", dumped)
  Debug("TX> " .. dumped)
  if Client.status ~= "connected" then return false end
  Tcp:Write(frame)
  return true
end

local ConnectNow, DisconnectNow, ProcessQueue

ConnectNow = function()
  if not Screen or Screen.transport ~= MODE.IP then return end
  if Client.address == "" or #Client.address < 7 then
    Notify("Set IP address first")
    return
  end
  if Client.status == "connected" or Client.status == "connecting" then return end
  Client.status = "connecting"
  Client.port = Screen.port
  PushFeedback()
  Debug("CONNECT " .. Client.address .. ":" .. Client.port)
  Tcp:Connect(Client.address, Client.port)
end

DisconnectNow = function()
  if Client.status ~= "disconnected" then
    Debug("DISCONNECT")
    Tcp:Disconnect()
  end
  Client.status = "disconnected"
  Queue.inflight = false
  PushFeedback()
end

--------------------------------------------------------------------------------
-- QUEUE (TCP only)
--------------------------------------------------------------------------------
local function Enqueue(cmd)
  if not cmd or cmd == "" then return end
  if #Queue.items >= MAX_QUEUE then table.remove(Queue.items, 1) end
  table.insert(Queue.items, cmd)
  Debug("QUE +" .. cmd)
  if Client.status == "disconnected" then
    ConnectNow()
  else
    ProcessQueue()
  end
end

ProcessQueue = function()
  if Queue.inflight then return end
  if #Queue.items == 0 then
    if Screen and Screen.connect == CONN.TEMP
       and Client.status == "connected"
       and (Now() - LastTxAt) > TEMP_HOLD then
      DisconnectNow()
    end
    return
  end
  if not IsConnected() then
    if Client.status == "disconnected" then ConnectNow() end
    return
  end
  local cmd = table.remove(Queue.items, 1)
  Queue.sent = cmd
  Queue.inflight = true
  if not SendRaw(cmd) then
    Queue.inflight = false
    table.insert(Queue.items, 1, cmd)
  end
end

--------------------------------------------------------------------------------
-- HTTP (Grandview)
--------------------------------------------------------------------------------
local function SendHttp(path)
  local ip = Client.address
  if ip == "" then
    Notify("No IP set")
    return
  end
  local auth = (Screen and Screen.auth) or ""
  local request = string.format(
    "GET %s HTTP/1.1\r\nHost: %s\r\nAuthorization: Basic %s\r\nConnection: close\r\n\r\n",
    path, ip, auth
  )
  local dumped = request:gsub("\r", "<CR>"):gsub("\n", "<LF>")
  SetString("TxLog", dumped)
  Debug("HTTP TX " .. path)
  local hs = TcpSocket.New()
  hs.ReadTimeout = 2
  hs.WriteTimeout = 0
  hs.EventHandler = function(s, evt, err)
    if evt == TcpSocket.Events.Connected then
      s:Write(request)
      Notify("HTTP TX " .. path)
    elseif evt == TcpSocket.Events.Data then
      local data = s:Read(s.BufferLength)
      if data then
        local rxd = tostring(data):gsub("\r", "<CR>"):gsub("\n", "<LF>")
        SetString("RxLog", rxd)
        Debug("HTTP RX " .. rxd)
      end
      s:Disconnect()
    elseif evt == TcpSocket.Events.Closed then
      Notify("HTTP done")
    elseif evt == TcpSocket.Events.Error then
      Notify("HTTP error: " .. tostring(err))
    end
  end
  hs:Connect(ip, Screen.port or 80)
end

--------------------------------------------------------------------------------
-- RX PARSER (Screen Technics)
--------------------------------------------------------------------------------
local function HandleRx(raw)
  if not raw or raw == "" then return end
  Status.comms_ok = true
  Queue.inflight = false
  local dumped = raw:gsub("\r", "<CR>"):gsub("\n", "<LF>")
  SetString("RxLog", dumped)
  Debug("RX> " .. dumped)
  Notify("RX> " .. raw)

  if not Screen or not Screen.rx then
    ProcessQueue()
    return
  end

  local rx = Screen.rx
  if rx.up and raw:find(rx.up, 1, true) then
    Status.position = "Up"
  elseif rx.down and raw:find(rx.down, 1, true) then
    Status.position = "Down"
  elseif rx.stop and raw:find(rx.stop, 1, true) then
    Status.position = "Stop"
  elseif rx.moving_up and raw:find(rx.moving_up, 1, true) then
    Status.position = "Moving Up"
  elseif rx.moving_down and raw:find(rx.moving_down, 1, true) then
    Status.position = "Moving Down"
  end

  PushFeedback()
  ProcessQueue()
end

Tcp.EventHandler = function(sock, evt, err)
  if evt == TcpSocket.Events.Connected then
    Client.status = "connected"
    Status.comms_ok = true
    Notify("CONNECTED " .. Client.address .. ":" .. Client.port)
    PushFeedback()
    ProcessQueue()
  elseif evt == TcpSocket.Events.Data then
    local data = sock:Read(sock.BufferLength)
    if data then HandleRx(data) end
  elseif evt == TcpSocket.Events.Closed then
    Client.status = "disconnected"
    Queue.inflight = false
    Notify("SOCKET CLOSED")
    PushFeedback()
  elseif evt == TcpSocket.Events.Error then
    Client.status = "disconnected"
    Queue.inflight = false
    Status.comms_ok = false
    Notify("SOCKET ERROR: " .. tostring(err))
    PushFeedback()
  elseif evt == TcpSocket.Events.Timeout then
    Client.status = "disconnected"
    Queue.inflight = false
    Notify("SOCKET TIMEOUT")
    PushFeedback()
  end
end

--------------------------------------------------------------------------------
-- HIGH-LEVEL COMMANDS
--------------------------------------------------------------------------------
local function ApplyModel(key)
  local proto = Protocols[key]
  if not proto then
    Notify("UNKNOWN SCREEN: " .. tostring(key))
    return false
  end
  ScreenKey = key
  Screen = proto
  Client.port = proto.port or 0
  SetString("Model", key)
  SetString("MakeModel", proto.make .. " " .. proto.model)
  SetString("IPPort", tostring(proto.port or 0))
  Notify("SCREEN SET IS " .. key)
  DisconnectNow()
  PushFeedback()
  return true
end

local function Direction(cmd)
  if not Screen then return end
  local tx = Screen.tx
  if Screen.transport == MODE.HTTP then
    if cmd == "UP"   then SendHttp(tx.up)   Status.position = "Up (cmd)" end
    if cmd == "DOWN" then SendHttp(tx.down) Status.position = "Down (cmd)" end
    if cmd == "STOP" then SendHttp(tx.stop) Status.position = "Stop (cmd)" end
    PushFeedback()
    return
  end
  -- TCP
  if cmd == "UP"   and tx.up   then Enqueue(tx.up) end
  if cmd == "DOWN" and tx.down then Enqueue(tx.down) end
  if cmd == "STOP" and tx.stop then Enqueue(tx.stop) end
  if cmd == "QUERY" and tx.query then Enqueue(tx.query) end
end

function Control(cmd)
  if not cmd or cmd == "" then return end
  Debug("CMD " .. cmd)

  if cmd == "DIRECTION=UP"   or cmd == "UP"   then Direction("UP")   return end
  if cmd == "DIRECTION=DOWN" or cmd == "DOWN" then Direction("DOWN") return end
  if cmd == "DIRECTION=STOP" or cmd == "STOP" then Direction("STOP") return end
  if cmd == "POSITION?" or cmd == "QUERY" then Direction("QUERY") return end

  if cmd:find("SCREEN=", 1, true) == 1 or cmd:find("DISPLAY=", 1, true) == 1 then
    local key = cmd:match("=(.+)")
    ApplyModel(key)
    return
  end
  if cmd == "SCREEN?" or cmd == "DISPLAY?" then
    Notify(ScreenKey ~= "" and ("SCREEN SET IS " .. ScreenKey) or "NO SCREEN SELECTED")
    return
  end

  if cmd:find("IP=", 1, true) == 1 then
    local ip = cmd:sub(4)
    if #ip > 6 then
      Client.address = ip
      Notify("CLIENT.IP=" .. ip)
    end
    return
  end
  if cmd:find("IP PORT=", 1, true) == 1 then
    Client.port = tonumber(cmd:sub(9)) or Client.port
    Notify("CLIENT.PORT=" .. tostring(Client.port))
    return
  end

  if cmd == "CONNECT"    then ConnectNow()    return end
  if cmd == "DISCONNECT" then DisconnectNow() return end
  if cmd == "REINIT"     then Direction("QUERY") return end

  if cmd:find("POLLING=", 1, true) == 1 then
    Polling = (tonumber(cmd:sub(9)) or 0) ~= 0
    Notify("POLLING=" .. (Polling and "1" or "0"))
    return
  end
  if cmd:find("DEBUG=", 1, true) == 1 then
    DebugOn = (tonumber(cmd:sub(7)) or 0) ~= 0
    return
  end

  if cmd == "CLEAR LOGS" then
    ClearLogs()
    return
  end

  Notify("UNKNOWN COMMAND: " .. cmd)
end

--------------------------------------------------------------------------------
-- POLLING TICK
--------------------------------------------------------------------------------
Tick = Timer.New()
Tick.EventHandler = function()
  local ok, err = pcall(function()
    ProcessQueue()
    if Queue.inflight and (Now() - LastTxAt) > RX_TIMEOUT then
      Queue.inflight = false
      Status.comms_ok = false
      Notify("COMM FAIL")
      PushFeedback()
    end
    if not Polling or not Screen then return end
    if Screen.transport == MODE.IP and Screen.tx.query
       and Client.status == "connected"
       and (Now() - LastTxAt) > 8 then
      Enqueue(Screen.tx.query)
    end
  end)
  if not ok then Notify("TICK ERR " .. tostring(err)) end
end

--------------------------------------------------------------------------------
-- BIND UI
--------------------------------------------------------------------------------
local function BindUI()
  SetLegend("Up", "Up")
  SetLegend("Down", "Down")
  SetLegend("Stop", "Stop")
  SetLegend("Clear Logs", "Clear Logs")

  local m = C("Model")
  if m then
    m.Choices = ModelList
    m.EventHandler = function(ctl)
      if SuppressUI then return end
      if ctl.String and ctl.String ~= "" and ctl.String ~= ScreenKey then
        ApplyModel(ctl.String)
      end
    end
  end

  Bind("IPAddress", function(ctl) Control("IP=" .. (ctl.String or "")) end)
  Bind("IPPort", function(ctl)
    local p = tonumber(ctl.String or ctl.Value)
    if p then Control("IP PORT=" .. tostring(p)) end
  end)

  Bind("Up",   function(ctl) if Pressed(ctl) then Control("DIRECTION=UP") end end)
  Bind("Down", function(ctl) if Pressed(ctl) then Control("DIRECTION=DOWN") end end)
  Bind("Stop", function(ctl) if Pressed(ctl) then Control("DIRECTION=STOP") end end)

  Bind("Connect",    function(ctl) if Pressed(ctl) then Control("CONNECT") end end)
  Bind("Disconnect", function(ctl) if Pressed(ctl) then Control("DISCONNECT") end end)
  Bind("Reinit",     function(ctl) if Pressed(ctl) then Control("REINIT") end end)

  Bind("PollingEnable", function(ctl)
    if SuppressUI then return end
    Control("POLLING=" .. (ctl.Boolean and "1" or "0"))
  end)
  Bind("DebugEnable", function(ctl)
    Control("DEBUG=" .. (ctl.Boolean and "1" or "0"))
  end)

  Bind("Clear Logs", function(ctl)
    if not Pressed(ctl) then return end
    ClearLogs()
    -- Momentary only. Do not leave the LED on.
    SuppressUI = true
    if ctl and ctl.Boolean ~= nil then ctl.Boolean = false end
    SuppressUI = false
  end)
end

--------------------------------------------------------------------------------
-- STARTUP
--------------------------------------------------------------------------------
BindUI()
SetString("ModuleInfo", MODULE_NAME .. "  v" .. VERSION)
SetBool("PollingEnable", Polling)
PushFeedback()
Tick:Start(QUEUE_TICK)
Notify(MODULE_NAME .. " v" .. VERSION .. " started  (" .. #ModelList .. " screens)")

do
  local ip = C("IPAddress")
  if ip and ip.String and #ip.String > 6 then Client.address = ip.String end
  local model = C("Model")
  if model and model.String and Protocols[model.String] then
    ApplyModel(model.String)
  end
end