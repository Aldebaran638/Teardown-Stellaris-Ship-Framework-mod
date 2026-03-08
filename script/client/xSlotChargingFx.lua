

---@diagnostic disable: undefined-global
---@diagnostic disable: duplicate-set-field

client = client or {}



-- 仅用于本脚本的充能特效生命周期管理（不影响其它特效/系统）
client.xSlotChargingFx = client.xSlotChargingFx or {
    -- [shipBodyId] = { lastSeenTime = number }
}

function client.xSlotChargingFxMark(shipBodyId)
    client.xSlotChargingFx[shipBodyId] = client.xSlotChargingFx[shipBodyId] or {}
    client.xSlotChargingFx[shipBodyId].lastSeenTime = GetTime()
end

-- 充能特效 GC：只做表项清理；不主动影响任何其它系统
function client.xSlotChargingFxTick(now)
    now = now or GetTime()
    for shipBodyId, fx in pairs(client.xSlotChargingFx) do
        local last = fx.lastSeenTime or -math.huge
        -- 超过一小段时间没再渲染 charging，则认为已结束（或没被遍历到了），清理表项
        if now - last > 0.25 then
            client.xSlotChargingFxStop(shipBodyId)
            client.xSlotChargingFx[shipBodyId] = nil
        end
    end
end

-- 客户端函数:渲染充能动画 在充能的第一帧被调用
function client.xSlotChargingFxStart(shipBodyId, firePoint, weaponType)
    DebugWatch("xSlotChargingFxStart",0)
    if shipBodyId == nil or shipBodyId == 0 then
        return
    end
    if firePoint == nil then
        return
    end

    -- 将发射点从飞船 body 局部坐标转换为世界坐标
    -- Teardown API:
    --   bodyT = GetBodyTransform(body)
    --   worldP = TransformToParentPoint(bodyT, localP)
    if IsHandleValid ~= nil and (not IsHandleValid(shipBodyId)) then
        return
    end

    local bodyT = GetBodyTransform(shipBodyId)
    local worldFirePos = TransformToParentPoint(bodyT, firePoint)

    -- 标记本帧确实渲染过 charging（用于仅限 charging 的资源清理/诊断）
    client.xSlotChargingFxMark(shipBodyId)

    -- 武器类型分发（目前只有 tachyonLance）
    if weaponType == "tachyonLance" then
        local t = GetTime()

        -- 取飞船自身的“前方方向”（以 body 局部 -Z 为前）
        local forward = TransformToParentVec(bodyT, Vec(0, 0, -1))
        local fLen = VecLength(forward)
        if fLen < 0.0001 then
            forward = Vec(0, 0, -1)
        else
            forward = VecScale(forward, 1 / fLen)
        end

        -- 在 forward 的垂直平面里构造 right/up，用于画一个旋转光环
        local upWorld = Vec(0, 1, 0)
        local right = VecCross(upWorld, forward)
        local rLen = VecLength(right)
        if rLen < 0.0001 then
            right = Vec(1, 0, 0)
        else
            right = VecScale(right, 1 / rLen)
        end
        local up = VecCross(forward, right)
        local uLen = VecLength(up)
        if uLen < 0.0001 then
            up = Vec(0, 1, 0)
        else
            up = VecScale(up, 1 / uLen)
        end

        -- 充能强度（随时间脉冲）
        local pulse = 0.5 + 0.5 * math.sin(t * 10.0)
        local ringRadius = 0.28 + 0.16 * pulse
        local ringAlpha = 0.35 + 0.45 * pulse

        -- 发射点强光（非常明显）
        PointLight(worldFirePos, 0.15, 0.85, 1.0, 3.0 + 5.0 * pulse)

        -- 画一个旋转的环（用多段线拼出来）
        local segments = 16
        local spin = t * 2.5
        local last = nil
        for i = 0, segments do
            local a = (i / segments) * math.pi * 2.0 + spin
            local offset = VecAdd(VecScale(right, math.cos(a) * ringRadius), VecScale(up, math.sin(a) * ringRadius))
            local p = VecAdd(worldFirePos, offset)
            if last ~= nil then
                DrawLine(last, p, 0.2, 0.9, 1.0, ringAlpha)
            end
            last = p
        end

        -- 画一条“预瞄束”，让玩家一眼看出武器方向
        local previewLen = 2.5 + 1.5 * pulse
        local previewEnd = VecAdd(worldFirePos, VecScale(forward, previewLen))
        DrawLine(worldFirePos, previewEnd, 0.4, 1.0, 1.0, 0.65 + 0.25 * pulse)

        -- 生成少量发光粒子：围绕环向内收缩，同时略微往前喷
        ParticleReset()
        ParticleColor(0.25, 0.95, 1.0, 0.10, 0.25, 1.0)
        ParticleRadius(0.06, 0.01, "easeout")
        ParticleAlpha(0.9, 0.0)
        ParticleGravity(0.0)
        ParticleDrag(0.2)
        ParticleEmissive(8.0, 0.0)
        ParticleCollide(0.0)

        local pCount = 6
        for i = 1, pCount do
            local a = spin * 2.0 + (i / pCount) * math.pi * 2.0
            local o = VecAdd(VecScale(right, math.cos(a) * ringRadius), VecScale(up, math.sin(a) * ringRadius))
            local pos = VecAdd(worldFirePos, o)
            local vel = VecAdd(VecScale(o, -6.0), VecScale(forward, 2.0 + 2.0 * pulse))
            -- 粒子是“唯一可能跨帧残留”的东西：寿命做短，state 离开 charging 后会很快自然消失
            SpawnParticle(pos, vel, 0.06 + 0.06 * pulse)
        end

        -- 额外加一个 debug 十字（可选，但非常醒目）
        DebugCross(worldFirePos, 0.2, 0.9, 1.0, 0.35 + 0.35 * pulse)
        return
    end

    -- 未知武器类型：给一个最简单的可见提示，避免“无效果”难排查
    PointLight(worldFirePos, 1.0, 0.8, 0.2, 1.5)
    DebugCross(worldFirePos, 1.0, 0.8, 0.2, 0.7)
end