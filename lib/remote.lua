-- norns-remote, the matron side: sends the screen, the parameters and the output
-- levels to the relay (relay.py) while a browser is connected, and runs the
-- commands the relay passes on. mod.lua loads it into the global norns_remote,
-- so the REPL can reload it without restarting the norns:
--   norns_remote = dofile(paths.code .. "norns-remote/lib/remote.lua")
local R = {}

local RELAY = {"127.0.0.1", 10112}
local IDLE = 3        -- seconds without a ping from the relay: send nothing
local KEYFRAME = 1    -- seconds: resend an unchanged screen this often
local VALUES_EVERY = 6  -- ticks (30 a second) between parameter value checks
local VU_EVERY = 2
local CHUNK = 80      -- parameters per message, to stay well under a UDP packet

-- osc.send only carries text, so the screen goes as one letter per pixel.
local LETTERS = {}
for level = 0, 15 do LETTERS[string.char(level)] = string.char(65 + level) end

local last_ping = -math.huge
local last_frame, last_sent = nil, 0
local ticks = 0
local described = nil   -- what the last parameter list described (see params_key)
local sent = {}         -- parameter index -> display string last sent
local seq = 0
local vu = {0, 0}
local vu_polls = nil

-- JSON, enough for the messages here: strings, numbers, booleans, arrays, maps.
local ESCAPES = {['"'] = '\\"', ['\\'] = '\\\\', ['\n'] = '\\n', ['\r'] = '\\r', ['\t'] = '\\t'}
local function json(v)
  local t = type(v)
  if t == "string" then
    return '"' .. v:gsub('[%c"\\]', function(c)
      return ESCAPES[c] or string.format("\\u%04x", c:byte())
    end) .. '"'
  elseif t == "number" then
    if v ~= v or v == math.huge or v == -math.huge then return "null" end
    if math.type(v) == "integer" then return tostring(v) end
    return string.format("%.6g", v)
  elseif t == "boolean" then
    return tostring(v)
  elseif t == "table" then
    local out = {}
    if next(v) == nil or #v > 0 then
      for _, item in ipairs(v) do out[#out + 1] = json(item) end
      return "[" .. table.concat(out, ",") .. "]"
    end
    for k, item in pairs(v) do out[#out + 1] = json(tostring(k)) .. ":" .. json(item) end
    return "{" .. table.concat(out, ",") .. "}"
  end
  return "null"
end

local function send(msg)
  osc.send(RELAY, "/norns-remote/json", {json(msg)})
end

-- Parameters ----------------------------------------------------------------

local VALUED = {
  [params.tNUMBER] = true, [params.tOPTION] = true, [params.tCONTROL] = true,
  [params.tFILE] = true, [params.tTAPER] = true, [params.tTEXT] = true,
  [params.tBINARY] = true,
}

local function describe(i, p)
  local d = {i = i, t = p.t, id = p.id, name = p.name or p.id or ""}
  if not params:visible(i) then d.hidden = true end
  if p.t == params.tNUMBER then
    d.min, d.max = p.min, p.max
  elseif p.t == params.tOPTION then
    d.options = p.options
  elseif p.t == params.tGROUP then
    d.n = p.n
  elseif p.t == params.tBINARY then
    d.behavior = p.behavior
  end
  return d
end

-- [what the control shows, the display string]: raw 0-1 for sliders over
-- controls and tapers, the value itself for numbers, options and toggles.
local function value(i, p)
  local ok, s = pcall(params.string, params, i)
  s = ok and tostring(s) or ""
  if p.t == params.tCONTROL or p.t == params.tTAPER then return {p:get_raw(), s} end
  if p.t == params.tNUMBER or p.t == params.tOPTION or p.t == params.tBINARY then
    return {params:get(i), s}
  end
  return {0, s}
end

-- A new script, or one that added parameters later, needs a new list.
local function params_key()
  return (norns.state.script or "") .. "#" .. params.count .. "#" .. tostring(params.params)
end

local function send_params()
  seq = seq + 1
  local all = {}
  for i = 1, params.count do
    local p = params.params[i]
    if p then all[#all + 1] = describe(i, p) end
  end
  local chunks = math.max(1, math.ceil(#all / CHUNK))
  for c = 1, chunks do
    local part = {}
    for k = (c - 1) * CHUNK + 1, math.min(c * CHUNK, #all) do part[#part + 1] = all[k] end
    send({type = "params", seq = seq, chunk = c, chunks = chunks,
          script = norns.state.shortname or "", list = part})
  end
  sent = {}
  described = params_key()
end

local function send_values()
  local changed, n = {}, 0
  for i = 1, params.count do
    local p = params.params[i]
    if p and VALUED[p.t] then
      local v = value(i, p)
      if v[2] ~= sent[i] then
        sent[i] = v[2]
        changed[tostring(i)] = v
        n = n + 1
        if n == 300 then
          send({type = "values", seq = seq, v = changed})
          changed, n = {}, 0
        end
      end
    end
  end
  if n > 0 then send({type = "values", seq = seq, v = changed}) end
end

-- Levels --------------------------------------------------------------------

-- Loading a script stops every poll (poll.clear_all), so this runs again then.
-- Right after a restart, the polls are not known yet: then it tries again.
local function start_vu()
  local found = {}
  for side, name in ipairs({"amp_out_l", "amp_out_r"}) do
    found[side] = poll.set(name, function(v) vu[side] = v end)
    if not found[side] then return end
  end
  for _, p in ipairs(found) do
    p.time = 1 / 15
    p:start()
  end
  vu_polls = found
end

local function stop_vu()
  for _, p in ipairs(vu_polls or {}) do p:stop() end
  vu_polls = nil
end

-- Called 30 times a second by mod.lua -----------------------------------------

function R.tick()
  local now = util.time()
  ticks = ticks + 1
  if ticks % VALUES_EVERY == 3 and R.twister then R.twister() end
  if now - last_ping > IDLE then
    if vu_polls then stop_vu() end
    return
  end

  -- Drawing runs on matron's screen thread; peek waits for every queued
  -- drawing call first, so it returns whole frames, never half-drawn ones.
  local frame = screen.peek(0, 0, 128, 64)
  if frame ~= last_frame or now - last_sent >= KEYFRAME then
    last_frame, last_sent = frame, now
    osc.send(RELAY, "/norns-remote/screen", {(frame:gsub(".", LETTERS))})
  end

  if described ~= params_key() then
    send_params()
    vu_polls = nil
  end
  if ticks % VALUES_EVERY == 0 then send_values() end
  if ticks % VU_EVERY == 0 then
    if not vu_polls then start_vu() end
    send({type = "vu", o = vu})
  end
end

-- Commands from the relay (OSC /norns-remote/<cmd>) ---------------------------

local function param(i)
  i = math.floor(i)
  if i >= 1 and i <= params.count then return i, params.params[i] end
end

local COMMANDS = {}

-- The relay pings once a second while a browser is connected, with 1 when
-- one has just connected: it then gets everything straight away.
function COMMANDS.ping(args)
  last_ping = util.time()
  if args[1] == 1 then
    last_frame, described = nil, nil
  end
end

-- A remote turn counts in steps, not in encoder ticks: norns needs several
-- ticks per step (2 for E2/E3, 8 for E1 in the menus), so a 1-tick turn, as
-- /remote/enc sends, does nothing. Drop any leftover ticks, then send exactly
-- the ticks for the steps asked for at the current sensitivity.
function COMMANDS.enc(args)
  local n, steps = math.floor(args[1]), math.floor(args[2])
  if n >= 1 and n <= 3 and steps ~= 0 then
    norns.encoders.tick[n] = 0
    _norns.enc(n, steps * norns.encoders.sens[n])
  end
end

function COMMANDS.set(args)
  local i, p = param(args[1])
  if not p then return end
  local v = args[2]
  if p.t ~= params.tCONTROL and p.t ~= params.tTAPER then v = math.floor(v + 0.5) end
  params:set(i, v)
end

-- By parameter id, for tools that do not track indexes, e.g.
-- /norns-remote/setid "monitor_level" -inf
function COMMANDS.setid(args)
  local id = tostring(args[1] or "")
  if params.lookup[id] then params:set(id, args[2]) end
end

function COMMANDS.raw(args)
  local i, p = param(args[1])
  if p and (p.t == params.tCONTROL or p.t == params.tTAPER) then params:set_raw(i, args[2]) end
end

function COMMANDS.delta(args)
  local i, p = param(args[1])
  if p then params:delta(i, args[2]) end
end

function COMMANDS.trig(args)
  local i, p = param(args[1])
  if p and p.t == params.tTRIGGER then p:bang() end
end

function COMMANDS.load(args)
  local path = tostring(args[1] or "")
  if path:sub(1, #paths.code) == paths.code and path:sub(-4) == ".lua" then
    norns.script.load(path)
  end
end

-- Network MIDI ---------------------------------------------------------------
-- A MIDI device that lives on another computer: its messages arrive as OSC
-- /norns-remote/midi with the bytes as arguments, and what the norns sends to
-- it goes back as /norns-remote/midi to whoever sent the last message. To the
-- norns it is an ordinary device, so MIDI learn (PARAMETERS > MAP), scripts'
-- device menus, and scripts that look for a device by name all work.
-- Hammerspoon on the Mac presents a Midi Fighter Twister this way.
local NET_ID = 9001   -- device ids from matron are small; this one never clashes
local NET_NAME = "Midi Fighter Twister"
local reply_to = nil

local function net_device()
  if not midi.devices[NET_ID] then _norns.midi.add(NET_ID, NET_NAME, "norns-remote") end
  local d = midi.devices[NET_ID]
  -- The C side cannot send to or clock a device it does not know.
  d.send = function(_, data)
    if data.type then data = midi.to_data(data) end
    if reply_to then osc.send(reply_to, "/norns-remote/midi", data) end
  end
  d.clock_receive = function() end
  -- norns restores its saved port list after the mods start, so the port
  -- that adding the device claims is gone again: claim the first free one.
  local ported = false
  for i = 1, 16 do ported = ported or midi.vports[i].name == d.name end
  for i = 1, 16 do
    if not ported and midi.vports[i].name == "none" then
      midi.vports[i].name, ported = d.name, true
    end
  end
  midi.update_devices()
  return d
end

-- Twister auto-map: knobs 1-16 play the first 16 settings of whatever script is
-- loaded, with rings showing where each one is and mapped knobs lit (unused ones
-- dark). A knob mapped with the norns' own MIDI learn (PARAMETERS > MAP) belongs
-- to that mapping instead, and scripts written for the Twister (they name it in
-- their source, as haze does) drive it themselves: the auto-map stays off.
-- Knob values arrive as absolute 0-127 (a factory Twister); only their change
-- is used, as steps of each setting's own size, and the ring value sent back
-- re-centres the knob on the setting, so a setting never runs out of knob.
local SYSTEM_GROUPS = {LEVELS = true, REVERB = true, COMPRESSOR = true, SOFTCUT = true, CLOCK = true}
local KNOB_COLOR = 70  -- Twister hue for a mapped knob
local SLOW = {[params.tNUMBER] = 3, [params.tOPTION] = 4, [params.tBINARY] = 6}  -- ticks per step
local automap = {knobs = {}}
local knob_last, knob_shown, knob_color, knob_acc = {}, {}, {}, {}

local function mappable(i, p)
  if not params:visible(i) then return false end
  if p.t == params.tBINARY then return p.behavior == "toggle" end
  return p.t == params.tCONTROL or p.t == params.tTAPER or p.t == params.tNUMBER
      or p.t == params.tOPTION
end

local function twister_aware()
  local f = norns.state.script and io.open(norns.state.script)
  if not f then return false end
  local source = f:read("a")
  f:close()
  return source:find("Midi Fighter Twister", 1, true) ~= nil
end

local function build_automap()
  local key = params_key()
  if automap.key == key then return end
  automap = {key = key, knobs = {}, aware = twister_aware()}
  local i = 1
  while i <= params.count and #automap.knobs < 16 do
    local p = params.params[i]
    if p and p.t == params.tGROUP and SYSTEM_GROUPS[p.name] then
      i = i + p.n  -- the mixer and clock are not the script's
    elseif p and mappable(i, p) then
      automap.knobs[#automap.knobs + 1] = i
    end
    i = i + 1
  end
  knob_shown, knob_color, knob_acc = {}, {}, {}
end

local function learned(knob)
  local port = midi.devices[NET_ID] and midi.devices[NET_ID].port
  local rev = port and norns.pmap.rev[port]
  return rev and rev[1] and rev[1][knob - 1] ~= nil
end

local function position(p)
  if p.t == params.tCONTROL or p.t == params.tTAPER then return p:get_raw() end
  if p.t == params.tOPTION then return p.count > 1 and (p.selected - 1) / (p.count - 1) or 0 end
  if p.t == params.tBINARY then return p.value > 0 and 1 or 0 end
  local range = p.max - p.min
  return range > 0 and (p.value - p.min) / range or 0
end

local function knob_turned(knob, value)
  build_automap()
  local last = knob_last[knob]
  knob_last[knob] = value
  local i = automap.knobs[knob]
  if automap.aware or not i or not last or learned(knob) then return end
  local d = value - last
  if d == 0 then return end
  local p = params.params[i]
  local per = SLOW[p.t]
  if not per then return params:delta(i, d) end
  local acc = (knob_acc[knob] or 0) + d
  local steps = acc >= 0 and math.floor(acc / per) or -math.floor(-acc / per)
  knob_acc[knob] = acc - steps * per
  if steps == 0 then return end
  if p.t == params.tBINARY then params:set(i, steps > 0 and 1 or 0) else params:delta(i, steps) end
end

-- Rings and colors, 5 times a second, only for what changed.
local function update_twister()
  if not reply_to then return end
  build_automap()
  if automap.aware then return end
  local d = midi.devices[NET_ID]
  for knob = 1, 16 do
    local i = automap.knobs[knob]
    local on = i and not learned(knob)
    local value = on and math.floor(position(params.params[i]) * 127 + 0.5) or 0
    if knob_shown[knob] ~= value then
      d:cc(knob - 1, value, 1)
      knob_shown[knob], knob_last[knob] = value, value
    end
    local color = on and KNOB_COLOR or 0
    if knob_color[knob] ~= color then
      d:cc(knob - 1, color, 2)
      knob_color[knob] = color
    end
  end
end
R.twister = update_twister

function COMMANDS.midi(args, from)
  if from then reply_to = from end
  local data = {}
  for k, v in ipairs(args) do data[k] = math.floor(v) end
  if #data == 0 then return end
  _norns.midi.event(NET_ID, data)
  if data[1] == 0xB0 and data[2] < 16 then knob_turned(data[2] + 1, data[3]) end
end

function R.osc(cmd, args, from)
  local f = COMMANDS[cmd]
  if f then f(args, from) end
end

net_device()

return R
