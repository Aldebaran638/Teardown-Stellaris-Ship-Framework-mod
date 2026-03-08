
---@diagnostic disable: undefined-global
---@diagnostic disable: duplicate-set-field

client = client or {}

-- 客户端函数:渲染激光.在发射的第一帧被调用
function client.xSlotLaunchFxStart(shipBodyId, firePoint, hitPoint, weaponType)
    if shipBodyId == nil or shipBodyId == 0 then
        return
    end
    if firePoint == nil or hitPoint == nil then
        return
    end

    -- 要求：只有在 launching 状态才渲染（即使被其它地方误调用也不渲染）
    if client ~= nil and client.ships ~= nil then
        local shipData = client.ships[shipBodyId]
        local xSlot = shipData and shipData.weapons and shipData.weapons.xSlot
        if xSlot ~= nil and xSlot.state ~= "launching" then
            return
        end
    end

    if IsHandleValid ~= nil and (not IsHandleValid(shipBodyId)) then
        return
    end

    local bodyT = GetBodyTransform(shipBodyId)
    local worldFirePos = TransformToParentPoint(bodyT, firePoint)
    local worldHitPos = hitPoint

    local beamVec = VecSub(worldHitPos, worldFirePos)
    local beamLen = VecLength(beamVec)
    if beamLen < 0.001 then
        return
    end
    local beamDir = VecScale(beamVec, 1.0 / beamLen)

    local function _safeNormalize(v, fallback)
        local l = VecLength(v)
        if l < 0.0001 then
            return fallback
        end
        return VecScale(v, 1.0 / l)
    end

    local function _buildPerpBasis(forward)
        -- 构造 right/up，使其与 forward 垂直
        local upWorld = Vec(0, 1, 0)
        local right = VecCross(upWorld, forward)
        right = _safeNormalize(right, Vec(1, 0, 0))
        local up = VecCross(forward, right)
        up = _safeNormalize(up, Vec(0, 1, 0))
        return right, up
    end

    if weaponType == "tachyonLance" then
        local t = GetTime()
        local pulse = 0.5 + 0.5 * math.sin(t * 45.0)
        local right, up = _buildPerpBasis(beamDir)

        -- 主要光束（核心 + 外层辉光）
        DrawLine(worldFirePos, worldHitPos, 0.25, 0.95, 1.0, 0.95)
        DrawLine(worldFirePos, worldHitPos, 0.12, 0.75, 1.0, 0.55 + 0.25 * pulse)

        -- 外圈“电弧”感：四条轻微偏移的线
        local glowRadius = 0.03 + 0.02 * pulse
        local offsets = {
            VecScale(right, glowRadius),
            VecScale(right, -glowRadius),
            VecScale(up, glowRadius),
            VecScale(up, -glowRadius),
        }
        for i = 1, #offsets do
            local o = offsets[i]
            DrawLine(VecAdd(worldFirePos, o), VecAdd(worldHitPos, o), 0.05, 0.85, 1.0, 0.25)
        end

        -- 起点打光（命中点不额外绘制任何效果，避免与命中特效重复）
        PointLight(worldFirePos, 0.2, 0.9, 1.0, 4.0 + 3.0 * pulse)
        return
    end

    -- 未知 weaponType：渲染一条最基础的线，避免“完全没效果”难排查
    DrawLine(worldFirePos, worldHitPos, 1.0, 0.8, 0.2, 0.8)
end

-- 客户端函数:渲染激光更新与销毁.在每帧被调用
function client.xSlotLaunchFxTick(now)
    -- 目前没有任何持续更新的效果；如果后续有了需要持续更新的效果，可以在这里实现
end
