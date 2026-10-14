-- norns-remote: sends the screen to the relay (relay.py) while a browser is
-- connected to it, as one letter per pixel ("A" = level 0 ... "P" = level 15),
-- because norns' osc.send only carries text. Keys come back through norns' own
-- /remote/key OSC command; knob turns through /norns-remote/enc (see below).
local mod = require 'core/mods'

local this_name = mod.this_name  -- only set while the mod file loads

local RELAY = {"127.0.0.1", 10112}
local FPS = 30
local IDLE = 3      -- seconds without a ping from the relay: stop sending
local KEYFRAME = 1  -- seconds: resend an unchanged screen this often

local LETTERS = {}
for level = 0, 15 do LETTERS[string.char(level)] = string.char(65 + level) end

local last_ping = -math.huge
local last_frame, last_sent = nil, 0

mod.hook.register("system_post_startup", "norns-remote", function()
  -- Start the relay. A second copy cannot bind its ports and exits at once, so
  -- this is safe when one already runs. It stays in matron's service, so
  -- SYSTEM > RESTART restarts it too.
  local relay = paths.code .. this_name .. "/relay.py"
  os.execute("setsid python3 '" .. relay .. "' > /tmp/norns-remote.log 2>&1 &")

  -- The relay pings once a second while a browser is connected, and with 1
  -- when one has just connected, so it gets the screen straight away.
  local osc_event = _norns.osc.event
  _norns.osc.event = function(path, args, from)
    if path == "/norns-remote/ping" then
      last_ping = util.time()
      if args[1] == 1 then last_frame = nil end
      return
    end
    -- A remote turn counts in steps, not in encoder ticks: norns needs several
    -- ticks per step (2 for E2/E3, 8 for E1 in the menus), so a 1-tick turn,
    -- as /remote/enc sends, does nothing. Drop any leftover ticks, then send
    -- exactly the ticks for the steps asked for at the current sensitivity.
    if path == "/norns-remote/enc" then
      local n, steps = math.floor(args[1]), math.floor(args[2])
      if n >= 1 and n <= 3 and steps ~= 0 then
        norns.encoders.tick[n] = 0
        _norns.enc(n, steps * norns.encoders.sens[n])
      end
      return
    end
    osc_event(path, args, from)
  end

  -- Metro 34 is one of norns' reserved system slots (31-35) that nothing else
  -- uses, so it keeps running across script changes (they free 1-30 only).
  local tick = metro[34]
  tick.time = 1 / FPS
  tick.count = -1
  tick.event = function()
    local now = util.time()
    if now - last_ping > IDLE then return end
    -- Drawing runs on matron's screen thread; peek waits for every queued
    -- drawing call first, so it returns whole frames, never half-drawn ones.
    local frame = screen.peek(0, 0, 128, 64)
    if frame == last_frame and now - last_sent < KEYFRAME then return end
    last_frame, last_sent = frame, now
    osc.send(RELAY, "/norns-remote/screen", {(frame:gsub(".", LETTERS))})
  end
  tick:start()
end)
