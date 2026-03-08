
---@diagnostic disable: undefined-global
---@diagnostic disable: duplicate-set-field


client = client or {}

-- 激光特效队列：每个光束独立存在
client.xSlotLaunchFxQueue = client.xSlotLaunchFxQueue or {
    nextId = 1,
    items = {
        -- [id] = { startTime=number, fire=Vec, hit=Vec, color=table, width=number, duration=number }
    }
}

-- 客户端函数:渲染激光（发射时加入队列）
function client.xSlotLaunchFxStart(shipBodyId, firePoint, hitPoint, weaponType)
    if shipBodyId == nil or shipBodyId == 0 then return end
    if firePoint == nil or hitPoint == nil then return end
    if client ~= nil and client.ships ~= nil then
        local shipData = client.ships[shipBodyId]
        local xSlot = shipData and shipData.weapons and shipData.weapons.xSlot
        if xSlot ~= nil and xSlot.state ~= "launching" then return end
    end
    if IsHandleValid ~= nil and (not IsHandleValid(shipBodyId)) then return end

    local bodyT = GetBodyTransform(shipBodyId)
    local worldFirePos = TransformToParentPoint(bodyT, firePoint)
    local worldHitPos = hitPoint

    local beamVec = VecSub(worldHitPos, worldFirePos)
    local beamLen = VecLength(beamVec)
    if beamLen < 0.001 then return end

    -- 配置参数
    local color = {0.95, 1.0, 1.0} -- 强能量蓝白色
    local width = 0.45 -- 主束宽度
    local duration = 0.18 -- 光束存在时间

    local id = client.xSlotLaunchFxQueue.nextId
    client.xSlotLaunchFxQueue.nextId = id + 1
    client.xSlotLaunchFxQueue.items[id] = {
        startTime = GetTime(),
        fire = worldFirePos,
        hit = worldHitPos,
        color = color,
        width = width,
        duration = duration,
        weaponType = weaponType,
    }
end

-- 客户端函数:激光每帧渲染与销毁
function client.xSlotLaunchFxTick(now)
    now = now or GetTime()
    for id, fx in pairs(client.xSlotLaunchFxQueue.items) do
        local age = now - fx.startTime
        if age > fx.duration then
            client.xSlotLaunchFxQueue.items[id] = nil
        else
            local fire = fx.fire
            local hit = fx.hit
            local color = fx.color
            local width = fx.width
            local t = now
            local pulse = 0.5 + 0.5 * math.sin(t * 45.0)
            local beamVec = VecSub(hit, fire)
            local beamLen = VecLength(beamVec)
            local beamDir = VecScale(beamVec, 1.0 / math.max(beamLen, 0.001))

            -- 缓缓出现插值
            local appearTime = 0.06
            local appearFrac = math.min(1.0, age / appearTime)

            -- 构造 right/up 用于电弧
            local function _safeNormalize(v, fallback)
                local l = VecLength(v)
                if l < 0.0001 then return fallback end
                return VecScale(v, 1.0 / l)
            end
            local function _buildPerpBasis(forward)
                local upWorld = Vec(0, 1, 0)
                local right = VecCross(upWorld, forward)
                right = _safeNormalize(right, Vec(1, 0, 0))
                local up = VecCross(forward, right)
                up = _safeNormalize(up, Vec(0, 1, 0))
                return right, up
            end
            local right, up = _buildPerpBasis(beamDir)

            -- 主光束（极粗，缓缓出现，中心纯白）
            DrawLine(fire, hit, width * appearFrac, 1.0, 1.0, 1.0)
            DrawLine(fire, hit, width * 0.55 * appearFrac, 0.75, 1.0, (0.55 + 0.25 * pulse) * appearFrac)

            -- 外圈电弧感：多条偏移线
            local glowRadius = (0.07 + 0.04 * pulse) * appearFrac
            local offsets = {
                VecScale(right, glowRadius),
                VecScale(right, -glowRadius),
                VecScale(up, glowRadius),
                VecScale(up, -glowRadius),
            }
            for i = 1, #offsets do
                local o = offsets[i]
                DrawLine(VecAdd(fire, o), VecAdd(hit, o), width * 0.18 * appearFrac, 0.85, 1.0, 0.25 * appearFrac)
            end

            -- 旋转螺旋线效果（缓缓出现）
            local spiralCount = 2 -- 螺旋条数
            local spiralSegments = 32
            local spiralRadius = width * 0.65 * appearFrac
            local spiralTurns = 2.5
            for s = 1, spiralCount do
                local phase = t * 3.5 + (s-1) * math.pi
                local last = nil
                for i = 0, spiralSegments do
                    local frac = i / spiralSegments
                    local along = VecAdd(fire, VecScale(beamDir, beamLen * frac))
                    local angle = phase + frac * spiralTurns * math.pi * 2
                    local offset = VecAdd(VecScale(right, math.cos(angle) * spiralRadius), VecScale(up, math.sin(angle) * spiralRadius))
                    local p = VecAdd(along, offset)
                    if last ~= nil then
                        DrawLine(last, p, width * 0.13 * appearFrac, 1.0, 1.0, 1.0, 1.0 * appearFrac)
                    end
                    last = p
                end
            end

            -- 能量冲击粒子：随机生成亮点沿主束方向前冲（缓缓出现），使用蓝色
            ParticleReset()
            ParticleColor(0.20, 0.95, 1.00, 0.10 * appearFrac, 0.35 * appearFrac, 1.00 * appearFrac)
            ParticleRadius(0.09 * appearFrac, 0.02 * appearFrac, "easeout")
            ParticleAlpha(0.9 * appearFrac, 0.0)
            ParticleGravity(0.0)
            ParticleDrag(0.15)
            ParticleEmissive(16.0 * appearFrac, 0.0)
            ParticleCollide(0.0)
            local impactCount = 6
            for i = 1, impactCount do
                local frac = math.random()
                local along = VecAdd(fire, VecScale(beamDir, beamLen * frac))
                local angle = t * 2.0 + math.random() * math.pi * 2
                local offset = VecAdd(VecScale(right, math.cos(angle) * (glowRadius + width * 0.2 * appearFrac)), VecScale(up, math.sin(angle) * (glowRadius + width * 0.2 * appearFrac)))
                local p = VecAdd(along, offset)
                local vel = VecAdd(VecScale(beamDir, (18.0 + 8.0 * math.random()) * appearFrac), VecScale(offset, 2.0 * math.random() * appearFrac))
                SpawnParticle(p, vel, (0.12 + 0.08 * math.random()) * appearFrac)
            end

            -- 起点打光（缓缓出现）
            PointLight(fire, 0.2 * appearFrac, 0.9 * appearFrac, 1.0 * appearFrac, (6.0 + 4.0 * pulse) * appearFrac)
        end
    end
end
