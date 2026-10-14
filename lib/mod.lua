-- norns-remote: the norns screen, controls and parameters in a browser.
-- This file only starts the relay and wires lib/remote.lua into matron; the
-- logic lives there, in the global norns_remote, so the REPL can reload it.
local mod = require 'core/mods'

local dir = paths.code .. mod.this_name .. "/"  -- this_name is only set while loading

-- Errors are printed once per kind instead of 30 times a second.
local reported = {}
local function guarded(what, f)
  local ok, err = pcall(f)
  if not ok and not reported[what .. tostring(err)] then
    reported[what .. tostring(err)] = true
    print("norns-remote " .. what .. ": " .. tostring(err))
  end
end

mod.hook.register("system_post_startup", "norns-remote", function()
  -- Start the relay. A second copy cannot bind its ports and exits at once, so
  -- this is safe when one already runs. It stays in matron's service, so
  -- SYSTEM > RESTART restarts it too.
  os.execute("setsid python3 '" .. dir .. "relay.py' > /tmp/norns-remote.log 2>&1 &")

  norns_remote = dofile(dir .. "lib/remote.lua")

  local osc_event = _norns.osc.event
  _norns.osc.event = function(path, args, from)
    if path:sub(1, 14) == "/norns-remote/" then
      guarded("osc", function() norns_remote.osc(path:sub(15), args, from) end)
      return
    end
    osc_event(path, args, from)
  end

  -- Metro 34 is one of norns' reserved system slots (31-35) that nothing else
  -- uses, so it keeps running across script changes (they free 1-30 only).
  local tick = metro[34]
  tick.time = 1 / 30
  tick.count = -1
  tick.event = function() guarded("tick", function() norns_remote.tick() end) end
  tick:start()
end)
