-- Drift Passenger. Distances are metres.
-- Bolted beside the passenger window and just above the roof. The mount
-- follows the body. Only the aim point is smoothed, and horizon lock steadies
-- the camera's up axis without taking the mount off the car.
local cfg = ac.INIConfig.scriptSettings():mapSection('SETTINGS', {
  SIDE = 0,
  LATERAL = 1.05,
  LONGITUDINAL = -0.35,
  HEIGHT = 1.55,
  LOOK_AHEAD = 6,
  AIM_HEIGHT = 0.5,
  FOV = 50,
  HORIZON_LOCK = 0.72,
  SMOOTHING = 1
})

local function clamp(v, low, high)
  return math.max(low, math.min(high, v))
end

local function number(v, fallback)
  if type(v) ~= 'number' or v ~= v or v == math.huge or v == -math.huge then
    return fallback
  end
  return v
end

local sideSign = number(cfg.SIDE, 0) >= 0.5 and 1 or -1
local lateral = clamp(number(cfg.LATERAL, 1.05), 0.4, 2.5)
local longitudinal = clamp(number(cfg.LONGITUDINAL, -0.35), -2, 2)
local height = clamp(number(cfg.HEIGHT, 1.55), 0.8, 3)
local lookAhead = clamp(number(cfg.LOOK_AHEAD, 6), 2, 20)
local aimHeight = clamp(number(cfg.AIM_HEIGHT, 0.5), 0, 2)
local fov = clamp(number(cfg.FOV, 50), 35, 95)
local horizonLock = clamp(number(cfg.HORIZON_LOCK, 0.72), 0, 1)
local aimTime = 0.08 * clamp(number(cfg.SMOOTHING, 1), 0.35, 2.5)

local function newState()
  return { generation = -1 }
end

local states = { newState(), newState() }
local generation = 0
local activeIndex

local function reset()
  generation = generation + 1
end

ac.onReplay(reset)
ac.onCarJumped(-1, function(index)
  if car and car.index == index then reset() end
end)

function script.onCarChanged()
  reset()
end

local cameraPosition = vec3()
local cameraDirection = vec3()
local cameraUp = vec3()

function script.update(dt, cameraIndex)
  if not car then return end

  local index = cameraIndex == 2 and 2 or 1
  local state = states[index]
  local clock = number(sim.time, 0)
  local step = number(sim.dt, number(dt, 0))
  local replay = sim.isReplayActive
  local replayRate = number(sim.replayPlaybackRate, 1)
  if sim.isPaused or (replay and replayRate == 0) then step = 0 end
  step = math.abs(step)
  local replayDirection = replayRate < 0 and -1 or 1

  local origin = car.transform.position
  local vx, vz = car.velocity.x, car.velocity.z
  local speed = math.sqrt(vx * vx + vz * vz)
  local resetState = activeIndex ~= index or state.generation ~= generation or state.carIndex ~= car.index
    or state.replay ~= replay or state.replayDirection ~= replayDirection or step > 0.25
  if state.lastClock then
    local dx = origin.x - state.carX
    local dy = origin.y - state.carY
    local dz = origin.z - state.carZ
    local jumpDistance = 12 + speed * math.min(step, 0.25) * 3
    resetState = resetState or clock < state.lastClock or clock - state.lastClock > 500
      or dx * dx + dy * dy + dz * dz > jumpDistance * jumpDistance
  end

  local far = index == 2
  local out = (lateral + (far and 0.2 or 0)) * sideSign
  local camH = height + (far and 0.15 or 0)
  local lx, ly, lz = car.look.x, car.look.y, car.look.z
  local sx, sy, sz = car.side.x, car.side.y, car.side.z
  local ux, uy, uz = car.up.x, car.up.y, car.up.z

  cameraPosition:set(
    origin.x + sx * out + lx * longitudinal + ux * camH,
    origin.y + sy * out + ly * longitudinal + uy * camH,
    origin.z + sz * out + lz * longitudinal + uz * camH)

  local manual = clamp(number(ac.getDesiredLookDirection(), 0), -1, 1)
  local glance = sideSign * manual * 2.5
  local ax = origin.x + lx * lookAhead + sx * glance
  local ay = origin.y + aimHeight
  local az = origin.z + lz * lookAhead + sz * glance
  if resetState or not state.ready then
    state.ax, state.ay, state.az = ax, ay, az
    state.ready = true
  elseif step > 0 then
    local blend = 1 - math.exp(-step / aimTime)
    state.ax = state.ax + (ax - state.ax) * blend
    state.ay = state.ay + (ay - state.ay) * blend
    state.az = state.az + (az - state.az) * blend
  end

  local dx = state.ax - cameraPosition.x
  local dy = state.ay - cameraPosition.y
  local dz = state.az - cameraPosition.z
  local length = math.sqrt(dx * dx + dy * dy + dz * dz)
  if length < 0.001 then
    dx, dy, dz, length = lx, ly, lz, math.sqrt(lx * lx + ly * ly + lz * lz)
    if length < 0.001 then dx, dy, dz, length = 0, 0, 1, 1 end
  end
  dx, dy, dz = dx / length, dy / length, dz / length
  cameraDirection:set(dx, dy, dz)

  local mix = 1 - horizonLock
  local upx = car.up.x * mix
  local upy = car.up.y * mix + horizonLock
  local upz = car.up.z * mix
  local projection = upx * dx + upy * dy + upz * dz
  upx, upy, upz = upx - projection * dx, upy - projection * dy, upz - projection * dz
  local upLength = math.sqrt(upx * upx + upy * upy + upz * upz)
  if upLength < 0.001 then
    upx, upy, upz = -dy * dx, 1 - dy * dy, -dy * dz
    upLength = math.sqrt(upx * upx + upy * upy + upz * upz)
    if upLength < 0.001 then
      upx, upy, upz = 1 - dx * dx, -dx * dy, -dx * dz
      upLength = math.sqrt(upx * upx + upy * upy + upz * upz)
    end
  end
  cameraUp:set(upx / upLength, upy / upLength, upz / upLength)

  ac.Camera.position = cameraPosition
  ac.Camera.direction = cameraDirection
  ac.Camera.up = cameraUp
  ac.Camera.fov = fov

  state.generation, state.carIndex = generation, car.index
  state.replay, state.replayDirection = replay, replayDirection
  state.lastClock = clock
  state.carX, state.carY, state.carZ = origin.x, origin.y, origin.z
  activeIndex = index
end
