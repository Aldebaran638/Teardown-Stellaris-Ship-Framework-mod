

---@diagnostic disable: undefined-global
---@diagnostic disable: duplicate-set-field


client = client or {}

-- 能量汇聚特效队列：每个亮点独立存在
client.xSlotChargingFxQueue = client.xSlotChargingFxQueue or {
    nextId = 1,
    items = {
        -- [id] = { startTime=number, pos=Vec, target=Vec, color=table, radius=number, duration=number }
    }
}

-- 初始化能量汇聚特效：在球体内随机生成若干亮点
function client.xSlotChargingFxStart(shipBodyId, firePoint, weaponType)
    if firePoint == nil then return end

    -- 计算球心（发射点世界坐标）
    local worldFirePos = firePoint
    if shipBodyId ~= nil and shipBodyId ~= 0 and IsHandleValid ~= nil and IsHandleValid(shipBodyId) then
        local bodyT = GetBodyTransform(shipBodyId)
        worldFirePos = TransformToParentPoint(bodyT, firePoint)
    end

    -- 配置参数
    local fxRadius = 1.8 -- 球体半径（更分散）
    local fxCount = 5    -- 亮点数量（更稀疏）
    local fxDuration = 0.7 -- 每个亮点存在时间
    local color = {0.95, 1.0, 1.0} -- 蓝白色（与launch一致）

    for i = 1, fxCount do
        -- 随机球内分布
        local theta = math.random() * math.pi * 2
        local phi = math.acos(2 * math.random() - 1)
        local r = math.random() * fxRadius
        local x = r * math.sin(phi) * math.cos(theta)
        local y = r * math.sin(phi) * math.sin(theta)
        local z = r * math.cos(phi)
        local pos = VecAdd(worldFirePos, Vec(x, y, z))

        local id = client.xSlotChargingFxQueue.nextId
        client.xSlotChargingFxQueue.nextId = id + 1
        client.xSlotChargingFxQueue.items[id] = {
            startTime = GetTime(),
            pos = pos,
            target = worldFirePos,
            color = color,
            radius = 0.08 + 0.04 * math.random(),
            duration = fxDuration,
        }
    end
end

-- 每帧更新能量汇聚特效队列
function client.xSlotChargingFxTick(now)
    now = now or GetTime()
    for id, fx in pairs(client.xSlotChargingFxQueue.items) do
        local age = now - fx.startTime
        if age > fx.duration then
            client.xSlotChargingFxQueue.items[id] = nil
        else
            -- 亮点向球心靠拢
            local t = math.min(1.0, age / fx.duration)
            local dir = VecSub(fx.target, fx.pos)
            local move = VecScale(dir, t)
            local curPos = VecAdd(fx.pos, move)

            -- 渲染亮点
            PointLight(curPos, fx.color[1], fx.color[2], fx.color[3], 2.0)
            ParticleReset()
            ParticleColor(fx.color[1], fx.color[2], fx.color[3], 0.10, 0.35, 1.00)
            ParticleRadius(fx.radius, 0.01, "easeout")
            ParticleAlpha(0.9, 0.0)
            ParticleGravity(0.0)
            ParticleDrag(0.1)
            ParticleEmissive(12.0, 0.0)
            ParticleCollide(0.0)
            SpawnParticle(curPos, Vec(0,0,0), fx.duration-age)
        end
    end
end