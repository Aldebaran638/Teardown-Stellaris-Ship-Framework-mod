-- 该脚本的body点击左键以后向前方发射快子光矛
#version 2
#include "script/include/common.lua"

---@diagnostic disable: undefined-global
---@diagnostic disable: duplicate-set-field

client = client or {}
server = server or {}

-- 仅用于本脚本的充能特效生命周期管理（不影响其它特效/系统）
client._xslotChargingFx = client._xslotChargingFx or {
    -- [shipBodyId] = { lastSeenTime = number }
}

function client._xslotChargingFxMark(shipBodyId)
    client._xslotChargingFx[shipBodyId] = client._xslotChargingFx[shipBodyId] or {}
    client._xslotChargingFx[shipBodyId].lastSeenTime = GetTime()
end

-- 如果未来在 charging 里加了“需要显式关闭”的持久资源（循环音、SetLightEnabled、SetShapeEmissiveScale 等），
-- 就把关闭逻辑放这里。当前充能特效主要是 DrawLine/PointLight（逐帧）+ 短寿命粒子（自动消失），无需清除。
function client._xslotChargingFxStop(shipBodyId)
    -- no-op for now
end

-- 充能特效 GC：只做表项清理；不主动影响任何其它系统
function client._xslotChargingFxGc(now)
    now = now or GetTime()
    for shipBodyId, fx in pairs(client._xslotChargingFx) do
        local last = fx.lastSeenTime or -math.huge
        -- 超过一小段时间没再渲染 charging，则认为已结束（或没被遍历到了），清理表项
        if now - last > 0.25 then
            client._xslotChargingFxStop(shipBodyId)
            client._xslotChargingFx[shipBodyId] = nil
        end
    end
end

-- 外来数据
local firePosOffsetShip = Vec(0,0,4) -- 发射点相对于飞船中心的偏移
local fireDirRelative = Vec(0,0,1) -- 发射方向
local weaponType = "tachyonLance" -- 武器类型,用于客户端渲染时区分不同武器的特效
local maxRange = 2000 -- 武器最大射程
local shieldRadius = 7 --  球形护盾半径

-- 命中特效队列：用于“上一轮护盾特效不会因下一轮 launching 立即消失”，而是播放到时间耗尽
client._xslotHitFx = client._xslotHitFx or {
    nextId = 1,
    items = {
        -- [id] = { kind="shield"|"impact", startTime=number, hitTarget=number|nil, hitPoint=Vec }
    }
}

function client._xslotHitFxEnqueue(kind, hitTarget, hitPoint)
    if hitPoint == nil or hitPoint == false then
        return
    end
    local id = client._xslotHitFx.nextId or 1
    client._xslotHitFx.nextId = id + 1
    client._xslotHitFx.items[id] = {
        kind = kind,
        startTime = GetTime(),
        hitTarget = hitTarget,
        hitPoint = hitPoint,
    }
end

function client._xslotHitFxUpdateAndRender(now)
    now = now or GetTime()

    local function _safeNormalize(v, fallback)
        local l = VecLength(v)
        if l < 0.0001 then
            return fallback
        end
        return VecScale(v, 1.0 / l)
    end

    local function _buildPerpBasis(n)
        local upWorld = Vec(0, 1, 0)
        local t1 = VecCross(upWorld, n)
        t1 = _safeNormalize(t1, Vec(1, 0, 0))
        local t2 = VecCross(n, t1)
        t2 = _safeNormalize(t2, Vec(0, 1, 0))
        return t1, t2
    end

    -- 参数从 client 上取（允许你运行时随意改）
    local p1 = (client and client.p1) or 0.10
    local p2 = (client and client.p2) or 0.50
    local p3 = (client and client.p3) or 0.18
    local p4 = (client and client.p4) or 6
    local roundTime = (client and client.shieldHitRoundTime) or 0.10

    local shieldTotalTime = math.max(0.0, p4) * math.max(0.001, roundTime)
    local impactTotalTime = 0.25

    for id, fx in pairs(client._xslotHitFx.items) do
        local age = now - (fx.startTime or now)

        if fx.kind == "impact" then
            if age > impactTotalTime then
                client._xslotHitFx.items[id] = nil
            else
                local t = now
                local pulse = 0.5 + 0.5 * math.sin(t * 35.0)

                PointLight(fx.hitPoint, 1.0, 0.6, 0.2, 2.0 + 4.0 * pulse)

                ParticleReset()
                ParticleColor(1.0, 0.75, 0.25, 1.0, 0.3, 0.05)
                ParticleRadius(0.10, 0.02, "easeout")
                ParticleAlpha(0.9, 0.0)
                ParticleGravity(-2.0)
                ParticleDrag(0.2)
                ParticleEmissive(6.0, 0.0)
                ParticleCollide(0.0)

                -- 只在前半段稍微喷一下，避免一直喷导致“粘住”
                if age < impactTotalTime * 0.6 then
                    for i = 1, 10 do
                        local r = Vec(math.random() - 0.5, math.random() - 0.1, math.random() - 0.5)
                        local rl = VecLength(r)
                        if rl < 0.0001 then
                            rl = 1.0
                        end
                        local dir = VecScale(r, 1.0 / rl)
                        local vel = VecScale(dir, 6.0 + 8.0 * pulse)
                        SpawnParticle(fx.hitPoint, vel, 0.08 + 0.05 * pulse)
                    end
                end
            end

        elseif fx.kind == "shield" then
            -- 播放到时间耗尽后自动消失（不会因为下一轮 launching 立刻消失）
            if age > shieldTotalTime then
                client._xslotHitFx.items[id] = nil
            else
                local hitTarget = fx.hitTarget
                if hitTarget == nil or hitTarget == 0 then
                    client._xslotHitFx.items[id] = nil
                elseif IsHandleValid ~= nil and (not IsHandleValid(hitTarget)) then
                    client._xslotHitFx.items[id] = nil
                else
                    local bodyT = GetBodyTransform(hitTarget)
                    local comLocal = GetBodyCenterOfMass(hitTarget)
                    local center = TransformToParentPoint(bodyT, comLocal)

                    local n = VecSub(fx.hitPoint, center)
                    n = _safeNormalize(n, nil)
                    if n == nil then
                        client._xslotHitFx.items[id] = nil
                    else
                        local t1, t2 = _buildPerpBasis(n)

                        local round = math.floor(age / math.max(0.001, roundTime)) + 1
                        if round > p4 then
                            client._xslotHitFx.items[id] = nil
                        else
                            ParticleReset()
                            ParticleColor(0.20, 0.95, 1.00, 0.10, 0.35, 1.00)
                            ParticleRadius(p1, p1)
                            ParticleAlpha(1.0, 0.0)
                            ParticleGravity(0.0)
                            ParticleDrag(0.0)
                            ParticleEmissive(18.0, 0.0)
                            ParticleCollide(0.0)

                            if round == 1 then
                                SpawnParticle(fx.hitPoint, Vec(0, 0, 0), roundTime)
                            else
                                local R = shieldRadius
                                local maxChord = 2.0 * R
                                local twoRSq = 2.0 * R * R
                                local maxPointsPerRing = 128

                                local d = (round - 1) * p2
                                if d <= 0.0 then
                                    d = 0.0001
                                end
                                if d < maxChord then
                                    local cosTheta = 1.0 - (d * d) / twoRSq
                                    if cosTheta > 1.0 then
                                        cosTheta = 1.0
                                    elseif cosTheta < -1.0 then
                                        cosTheta = -1.0
                                    end
                                    local sinTheta = math.sqrt(math.max(0.0, 1.0 - cosTheta * cosTheta))

                                    local circleRadius = R * sinTheta
                                    local circumference = 2.0 * math.pi * circleRadius
                                    local count = math.floor((circumference / math.max(0.001, p3)) + 0.5)
                                    if count < 6 then
                                        count = 6
                                    elseif count > maxPointsPerRing then
                                        count = maxPointsPerRing
                                    end

                                    for i = 1, count do
                                        local a = ((i - 1) / count) * math.pi * 2.0
                                        local lateral = VecAdd(VecScale(t1, math.cos(a)), VecScale(t2, math.sin(a)))
                                        local v = VecAdd(VecScale(n, cosTheta), VecScale(lateral, sinTheta))
                                        local p = VecAdd(center, VecScale(v, R))
                                        SpawnParticle(p, Vec(0, 0, 0), roundTime)
                                    end
                                end
                            end
                        end
                    end
                end
            end
        else
            -- 未知类型，丢弃
            client._xslotHitFx.items[id] = nil
        end
    end
end

function server.init()
    serverTime = 0
    -- 当前武器状态:
    -- "idle"      空闲
    -- "charging"  充能中
    -- "launching" 发射中
    server.weaponState = "idle"

    -- 上一帧武器状态(用于检测状态变化的第一帧)
    server.weaponStateLastTick = "idle"

    -- 充能所需时间
    server.chargeTime = 0.5

    -- 发射持续时间
    server.launchTime = 0

    -- 初始化当前飞船
    server.shipBody = FindBody("launcher", false)

end

function client.onBodyRegister(shipBodyId)
    client.ships[shipBodyId] = {
        id = shipBodyId,      -- 刚体唯一ID
        weapons = {
            xSlot = {
                -- 状态机
                state = "idle",        -- 飞船x槽状态(由服务器广播) idle / charging / launching
                -- 武器信息
                weaponType = nil,      -- 飞船x槽活动的武器类型(当x槽状态不为idel的时候,需要根据武器类型渲染蓄力特效以及发射特效).当x槽处于idel状态,武器类型不会被用上(x槽状态被更新后会由服务器顺带广播)
                -- 服务器广播数据
                firePoint = nil,       -- 飞船x槽发射点((x槽状态被更新后会由服务器顺带广播)
                hitPoint  = nil,       -- 飞船x槽命中点(x槽状态被更新后会由服务器顺带广播)
                hitTarget = nil,       -- 飞船x槽命中目标ID(如果没有命中或者命中的是非群星body则为无效值)(x槽状态被更新后会由服务器顺带广播)
                didHit = nil,          -- 是否命中(x槽状态被更新后会由服务器顺带广播)
                didHitStellarisBody = nil, -- 是否命中的shape所属的body是群星body(x槽状态被更新后会由服务器顺带广播)
            }
        }
    }
end

function client.init()

    -- 所有飞船的容器表
    client.ships = {}
    -- 初始化当前飞船
    client.shipBody = FindBody("launcher", false)
    -- 注册当前飞船进入用户表(未来还需要服务器广播以让所有客户端注册当前刚体)
    client.onBodyRegister(client.shipBody)

    -- 护盾命中特效参数（你可以直接改这里调效果）
    client.p1 = 0.1 -- 光点半径（固定）
    client.p2 = 0.5 -- 每一轮外扩的 chord 距离增量
    client.p3 = 0.18 -- 光点间距（圆周长度 / p3 = 点数）
    client.p4 = 6    -- 总轮数
    -- 护盾命中特效的“每一轮”持续时间（秒）
    client.shieldHitRoundTime = 0.1

end

-- 客户端函数:发射请求函数,点击左键时调用,向服务端发送发射请求
function client.fire()
    if InputPressed("lmb") then
        DebugWatch("client_fire", 111111111111111)
        ServerCall("server_handleFireRequest")
    end
end

-- 服务端函数:接收来自客户端的发射请求,设置蓄力时间为非0
function server_handleFireRequest()
    DebugWatch("server_receiveFireRequest", 111111111111111)
    if server.weaponState == "idle" then
        server.weaponState = "charging"
        server.chargeTime = 0.5
    end
end


-- x槽武器 计算命中点信息的统一函数
-- 参数:发射刚体ID 起始发射点 发射方向
-- 返回值: 激光结束点,命中目标ID(如果没有命中或者命中的是非群星body则为无效值),是否命中,是否命中的shape所属的body是群星body
-- 逻辑:
--   - 未命中任何 shape: isHit=false,isHitStellarisBody=false,hitTarget=0,endPos=最远点
--   - 命中 shape 但其父 Body 无 tag "stellarisShip": isHit=true,isHitStellarisBody=false,hitTarget=0,endPos=命中点
--   - 命中 shape 且其父 Body 有 tag "stellarisShip": isHit=true,isHitStellarisBody=true,hitTarget=该父 Body 的 handle,endPos=命中点
function server_xslot_computeHitResult(shipBodyId, firePosOffset, fireDirRelative)
    local function _xslot_dbgReturn(endPos, hitTarget, isHit, isHitStellarisBody)
        local endPosStr
        if endPos == nil then
            endPosStr = "nil"
        elseif VecStr ~= nil then
            endPosStr = VecStr(endPos)
        else
            endPosStr = tostring(endPos)
        end
        DebugWatch(
            "xslot_computeHitResult",
            string.format(
                "endPos=%s hitTarget=%s isHit=%s isHitStellarisBody=%s",
                endPosStr,
                tostring(hitTarget),
                tostring(isHit),
                tostring(isHitStellarisBody)
            )
        )
    end

    local function _raySphereEntryT(origin, dirUnit, center, radius)
        DebugWatch("origin", origin)
        DebugWatch("dirUnit", dirUnit)
        DebugWatch("center", center)
        DebugWatch("radius", radius)
        -- 求射线 p=origin+dir*t 与球 |p-center|=radius 的入射点 t（最小非负解）
        local oc = VecSub(origin, center)
        local b = 2.0 * VecDot(oc, dirUnit)
        local c = VecDot(oc, oc) - radius * radius
        local disc = b * b - 4.0 * c
        if disc < 0.0 then
            return nil
        end
        local s = math.sqrt(disc)
        local t1 = (-b - s) * 0.5
        local t2 = (-b + s) * 0.5
        if t1 >= 0.0 then
            return t1
        end
        if t2 >= 0.0 then
            return t2
        end
        return nil
    end

    -- 默认无效值约定：Body handle 用 0 代表无效
    local invalidTarget = 0

    if shipBodyId == nil or shipBodyId == 0 or firePosOffset == nil or fireDirRelative == nil then
        local endPos, hitTarget, isHit, isHitStellarisBody = Vec(0, 0, 0), invalidTarget, false, false
        _xslot_dbgReturn(endPos, hitTarget, isHit, isHitStellarisBody)
        return endPos, hitTarget, isHit, isHitStellarisBody
    end

    -- 1) 将发射点偏移转换成世界坐标
    local shipT = GetBodyTransform(shipBodyId)
    local origin = TransformToParentPoint(shipT, firePosOffset)

    -- 2) 将相对方向转换成世界方向向量，并归一化
    local dir = TransformToParentVec(shipT, fireDirRelative)
    local dirLen = VecLength(dir)
    if dirLen < 0.0001 then
        dir = TransformToParentVec(shipT, Vec(0, 0, -1))
        dirLen = VecLength(dir)
    end
    if dirLen < 0.0001 then
        dir = Vec(0, 0, -1)
        dirLen = 1.0
    end
    dir = VecScale(dir, 1.0 / dirLen)

    -- 3) 射线检测
    QueryRequire("physical")
    QueryRejectBody(shipBodyId)
    local hit, dist, _normal, shape = QueryRaycast(origin, dir, maxRange)
    DebugWatch("server_xslot_computeHitResult",3)
    if not hit then
        local endPos = VecAdd(origin, VecScale(dir, maxRange))
        local hitTarget, isHit, isHitStellarisBody = invalidTarget, false, false
        _xslot_dbgReturn(endPos, hitTarget, isHit, isHitStellarisBody)
        return endPos, hitTarget, isHit, isHitStellarisBody
    end

    local endPos = VecAdd(origin, VecScale(dir, dist))
    if shape == nil or shape == 0 then
        local hitTarget, isHit, isHitStellarisBody = invalidTarget, true, false
        _xslot_dbgReturn(endPos, hitTarget, isHit, isHitStellarisBody)
        return endPos, hitTarget, isHit, isHitStellarisBody
    end

    local targetBody = GetShapeBody(shape)
    if targetBody ~= nil and targetBody ~= 0 and HasTag(targetBody, "stellarisShip") then
        -- 命中群星飞船：把 endPos 修正为护盾球面入射点
        local bodyT = GetBodyTransform(targetBody)
        DebugWatch("bodyT",bodyT)
        local comLocal = GetBodyCenterOfMass(targetBody)
        DebugWatch("comLocal",comLocal)
        local center = TransformToParentPoint(bodyT, comLocal)
        DebugWatch("center",center)
        local entryT = _raySphereEntryT(origin, dir, center, shieldRadius)
        DebugWatch("entryT",entryT)
        if entryT ~= nil and entryT <= maxRange then
            endPos = VecAdd(origin, VecScale(dir, entryT))
            DebugWatch("server_xslot_computeHitResult",4)
        end

        local hitTarget, isHit, isHitStellarisBody = targetBody, true, true
        _xslot_dbgReturn(endPos, hitTarget, isHit, isHitStellarisBody)
        return endPos, hitTarget, isHit, isHitStellarisBody
    end

    local hitTarget, isHit, isHitStellarisBody = invalidTarget, true, false
    _xslot_dbgReturn(endPos, hitTarget, isHit, isHitStellarisBody)
    return endPos, hitTarget, isHit, isHitStellarisBody
end


-- 根据命中信息结算效果
-- 如果isHitStellarisBody为true则说明命中的是群星飞船,命中后服务器不做任何事情.如果isHitStellarisBody为false但isHit为true则说明命中的是非群星飞船,在命中点产生一次半径为4的爆炸.如果isHit为false则说明没有命中,不产生任何事情.
function server_xslot_applyHitResult(endPos,isHit,isHitStellarisBody)
    if not isHit then
        return
    end
    if isHitStellarisBody then
        return
    end
    if endPos == nil then
        return
    end

    -- Teardown API: Explosion(pos, size) 其中 size 范围 0.5 - 4.0
    Explosion(endPos, 4.0)
end

-- 广播 开始充能

function server_broadcastChargingStart(shipBodyId, firePosOffsetShip, weaponType)
    -- 广播给所有客户端
    ClientCall(0, "client_ReceiveBroadcastChargingStart", shipBodyId, firePosOffsetShip, weaponType)
end

function client_ReceiveBroadcastChargingStart(shipBodyId, firePosOffsetShip, weaponType)
    -- 确保这个body在客户端表中
    if not client.ships[shipBodyId] then
        client.ships[shipBodyId] = {
            id = shipBodyId,
            weapons = {
                xSlot = {
                    state = "idle",
                    weaponType = nil,
                    firePoint = nil,
                    hitPoint = nil,
                    hitTarget = nil,
                    didHit = nil,
                    didHitStellarisBody = nil,
                }
            }
        }
    end

    -- 更新状态机信息
    local xSlot = client.ships[shipBodyId].weapons.xSlot
    xSlot.state = "charging"
    xSlot.weaponType = weaponType
    xSlot.firePoint = firePosOffsetShip
    xSlot.hitPoint = nil  -- 蓄力阶段还没有命中
    xSlot.hitTarget = nil
    xSlot.didHit = nil
    xSlot.didHitStellarisBody = nil
end

-- 广播 开始发射
-- 参数:发射刚体ID,发射点,命中点,是否命中,命中角度,是否命中群星飞船(暂定命中群星飞船就一定会触发护盾特效),武器类型
function server.broadcastLaunchingStart(shipBodyId, firePoint, hitPoint, didHit, hitTarget, didHitStellarisBody, weaponType)
    -- 应广播:
    -- shipBodyId
    -- firePoint
    -- hitPoint
    -- didHit
    -- hitTarget
    -- didHitStellarisBody
    -- weaponType
    -- 广播给所有客户端
    ClientCall(0, "client_ReceiveBroadcastLaunchingStart", shipBodyId, firePoint, hitPoint, didHit, hitTarget, didHitStellarisBody, weaponType)
end

function client_ReceiveBroadcastLaunchingStart(shipBodyId, firePoint, hitPoint, didHit, hitTarget, didHitStellarisBody, weaponType)
    -- 确保这个body在客户端表中
    if not client.ships[shipBodyId] then
        client.ships[shipBodyId] = {
            id = shipBodyId,
            weapons = {
                xSlot = {
                    state = "idle",
                    weaponType = nil,
                    firePoint = nil,
                    hitPoint = nil,
                    hitTarget = nil,
                    didHit = nil,
                    didHitStellarisBody = nil,
                }
            }
        }
    end

    -- 更新状态机信息
    local xSlot = client.ships[shipBodyId].weapons.xSlot
    xSlot.state = "launching"
    xSlot.weaponType = weaponType
    xSlot.firePoint = firePoint
    xSlot.hitPoint = hitPoint
    xSlot.hitTarget = hitTarget
    xSlot.didHit = didHit
    xSlot.didHitStellarisBody = didHitStellarisBody
end

-- 广播 武器回到 idle
function server_broadcastWeaponIdle(shipBodyId)
    -- 广播给所有客户端：该 ship 的 xSlot 回到 idle
    ClientCall(0, "client_ReceiveBroadcastWeaponIdle", shipBodyId)
end

function client_ReceiveBroadcastWeaponIdle(shipBodyId)
    if shipBodyId == nil or shipBodyId == 0 then
        return
    end

    -- 确保这个body在客户端表中
    if not client.ships[shipBodyId] then
        client.ships[shipBodyId] = {
            id = shipBodyId,
            weapons = {
                xSlot = {
                    state = "idle",
                    weaponType = nil,
                    firePoint = nil,
                    hitPoint = nil,
                    hitTarget = nil,
                    didHit = nil,
                    didHitStellarisBody = nil,
                }
            }
        }
        return
    end

    local xSlot = client.ships[shipBodyId].weapons.xSlot
    xSlot.state = "idle"
    xSlot.weaponType = nil
    xSlot.firePoint = nil
    xSlot.hitPoint = nil
    xSlot.hitTarget = nil
    xSlot.didHit = nil
    xSlot.didHitStellarisBody = nil
end



-- 在tick中使用到的变量:
-- server.weaponState 当前武器状态("idle"/"charging"/"launching")
-- server.weaponStateLastTick 武器在上一帧的状态(用于检测状态变化的第一帧)
-- server.chargeTime 飞船充能所需时间
-- server.launchTime 飞船发射持续时间
function server_tick(dt)
    local state = server.weaponState
    DebugWatch("weaponState", state)
    ------------------------------------------------
    -- 状态持续逻辑
    ------------------------------------------------
    if state == "charging" then
        server.chargeTime = server.chargeTime - dt
        if server.chargeTime <= 0 then
            -- 结束蓄力,开始发射的第一帧
            -- 切换到发射状态
            server.weaponState = "launching"
            server.launchTime = 0.2
        end
    elseif state == "launching" then
        server.launchTime = server.launchTime - dt
        if server.launchTime <= 0 then
            -- 结束发射的第一帧
            -- 切换回空闲状态
            server.weaponState = "idle"
        end
    elseif state == "idle" then
    end
    ------------------------------------------------
    -- 状态变化检测(统一处理第一帧逻辑)
    ------------------------------------------------
    if server.weaponState ~= server.weaponStateLastTick then
        if server.weaponState == "charging" then
            -- 开始蓄力的第一帧,需要广播蓄力信息:广播发射刚体,发射点(相对于飞船)以及武器类型
            server_broadcastChargingStart(server.shipBody, firePosOffsetShip, weaponType)
        elseif server.weaponState == "launching" then
            -- 根据发射点和飞船朝向计算命中点,命中倾斜角以及命中信息(是否直接命中船体or命中非群星飞船)
            local endPos, hitTarget, isHit, isHitStellarisBody = server_xslot_computeHitResult(server.shipBody,firePosOffsetShip,fireDirRelative)
            -- 根据信息结算 命中效果
            server_xslot_applyHitResult(endPos,isHit,isHitStellarisBody)
            -- 广播发射信息
            server.broadcastLaunchingStart(server.shipBody,firePosOffsetShip, endPos, isHit, hitTarget, isHitStellarisBody, weaponType)
        elseif server.weaponState == "idle" then
            -- 广播 结束发射信息
            server_broadcastWeaponIdle(server.shipBody)
        end
    end
    server.weaponStateLastTick = server.weaponState
end

-- 客户端函数:渲染蓄力动画
function client.renderChargingEffect(shipBodyId, firePoint, weaponType)
    DebugWatch("renderChargingEffect",0)
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
    client._xslotChargingFxMark(shipBodyId)

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

-- 客户端函数:渲染激光
function client.renderLaunchingEffect(shipBodyId, firePoint, hitPoint, weaponType)
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




-- 客户端函数:渲染命中点
-- 参数:命中目标ID(如果没有命中或者命中的是非群星body则为无效值),命中点,是否命中的shape所属的body是群星body
-- 逻辑:
function client.renderHitEffect(hitTarget, hitPoint, didHitStellarisBody)
    if hitPoint == nil or hitPoint == false then
        return
    end

    if didHitStellarisBody then
        client._xslotHitFxEnqueue("shield", hitTarget, hitPoint)
    else
        client._xslotHitFxEnqueue("impact", hitTarget, hitPoint)
    end
end


function client.client_tick(dt)
    client.fire()
    DebugWatch("clientTime", 111111111111111)
    -- 遍历所有注册的飞船
    for shipBodyId, shipData in pairs(client.ships) do
        local xSlot = shipData.weapons.xSlot
        local state = xSlot.state

        -- 只在进入 launching 的第一帧触发一次命中特效（避免每帧重复入队）
        if xSlot._lastState ~= state then
            if state == "launching" then
                client.renderHitEffect(xSlot.hitTarget, xSlot.hitPoint, xSlot.didHitStellarisBody)
            end
            xSlot._lastState = state
        end

        if state == "charging" then
            -- 蓄力阶段渲染
            client.renderChargingEffect(shipBodyId, xSlot.firePoint, xSlot.weaponType)
        elseif state == "launching" then
            -- 发射阶段渲染
            client.renderLaunchingEffect(shipBodyId, xSlot.firePoint, xSlot.hitPoint, xSlot.weaponType)
        elseif state == "idle" then
            -- 静默阶段不做任何事情
        end
    end
end


-- 客户端函数:接收服务端广播的蓄力信息,调用渲染,音效播放两种函数
function client.onChargeBroadcast(startPos, endPos, didHit, didHitShield)
    client.renderChargeEffect()
end

-- 客户端函数:接收服务端广播的激光信息,调用渲染,音效播放两种函数
function client.onLaserBroadcast(startPos, endPos, didHit, didHitShield)
    client.renderChargeEffect()
end



-- 注意：client.renderHitEffect(hitTarget, hitPoint, didHitStellarisBody) 已在上方实现

-- 客户端函数:播放音效
function client.playLaserSound()

end

-- 客户端函数:渲染护盾动画
function client.renderShieldEffect()

end

-- 客户端 tick：只调用总控函数
function client.tick(dt)
    client.client_tick(dt)
    -- 命中特效独立播放：即便下一轮进入 launching，也不会让上一轮立即消失
    client._xslotHitFxUpdateAndRender(GetTime())
    -- 不改 client.client_tick 的前提下：仅对 charging 特效做一次轻量 GC（不会影响其它特效）
    client._xslotChargingFxGc(GetTime())
end

function client.draw()
end

function server.tick(dt)
    serverTime = serverTime + (dt or 0)
    DebugWatch("serverTime", serverTime)
    server_tick(dt)
end


