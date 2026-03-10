-- xSlotControl.lua
-- 独立的 x 槽控制模块（从 test2.lua 抽取）
-- 该文件包含射线判定、命中结算以及广播函数

-- 外来数据：从统一的数据表加载（默认回退值可保证兼容）
#include "weapon_data.lua"
#include "ship_data.lua"
local weaponSettings = (weaponData and weaponData.tachyonLance) or {}
-- 用户自定义数据
local firePosOffsetShip = weaponSettings.firePosOffsetShip or Vec(0, 0, 4) -- 发射点相对于飞船中心的偏移
local fireDirRelative = weaponSettings.fireDirRelative or Vec(0, 0, 1) -- 发射方向
-- 武器参数
local weaponType = weaponSettings.weaponType or "tachyonLance" -- 武器类型,用于客户端渲染时区分不同武器的特效
local maxRange = weaponSettings.maxRange or 1 -- 武器最大射程
-- 飞船参数
local shieldRadius = shipData.enigmaticCruiser.shieldRadius or 20 --  球形护盾半径


-- 服务端函数:接收来自客户端的发射请求,设置蓄力时间为非0
function server_xSlot_handleFireRequest()
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
function server.xSlot_computeHitResult(shipBodyId, firePosOffset, fireDirRelative)
    DebugWatch("server.xSlot_computeHitResult", 111111)
    local function _xSlot_dbgReturn(endPos, hitTarget, isHit, isHitStellarisBody)
        DebugWatch("_xSlot_dbgReturn", 111111)
        local endPosStr
        if endPos == nil then
            endPosStr = "nil"
        elseif VecStr ~= nil then
            endPosStr = VecStr(endPos)
        else
            endPosStr = tostring(endPos)
        end
        DebugWatch(
            "xSlot_computeHitResult",
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
        DebugWatch("_raySphereEntryT", 111111)
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
        local endPos, hitTarget, isHit, isHitStellarisBody, normal = Vec(0, 0, 0), invalidTarget, false, false, Vec(0, 1, 0)
        _xSlot_dbgReturn(endPos, hitTarget, isHit, isHitStellarisBody)
        return endPos, hitTarget, isHit, isHitStellarisBody, normal
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
    local hit, dist, normal, shape = QueryRaycast(origin, dir, maxRange)
    DebugWatch("server.xSlot_computeHitResult",3)
    if not hit then
        local endPos = VecAdd(origin, VecScale(dir, maxRange))
        local hitTarget, isHit, isHitStellarisBody = invalidTarget, false, false
        _xSlot_dbgReturn(endPos, hitTarget, isHit, isHitStellarisBody)
        return endPos, hitTarget, isHit, isHitStellarisBody, dir
    end

    local endPos = VecAdd(origin, VecScale(dir, dist))
    if shape == nil or shape == 0 then
        local hitTarget, isHit, isHitStellarisBody = invalidTarget, true, false
        _xSlot_dbgReturn(endPos, hitTarget, isHit, isHitStellarisBody)
        return endPos, hitTarget, isHit, isHitStellarisBody, normal
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
            DebugWatch("server.xSlot_computeHitResult",4)
        end

        local hitTarget, isHit, isHitStellarisBody = targetBody, true, true
        _xSlot_dbgReturn(endPos, hitTarget, isHit, isHitStellarisBody)
        return endPos, hitTarget, isHit, isHitStellarisBody, normal
    end

    local hitTarget, isHit, isHitStellarisBody = invalidTarget, true, false
    _xSlot_dbgReturn(endPos, hitTarget, isHit, isHitStellarisBody)
    return endPos, hitTarget, isHit, isHitStellarisBody, normal
end

-- 根据命中信息结算效果
-- 如果isHitStellarisBody为true则说明命中的是群星飞船,命中后服务器不做任何事情.如果isHitStellarisBody为false但isHit为true则说明命中的是非群星飞船,在命中点产生一次半径为4的爆炸.如果isHit为false则说明没有命中,不产生任何事情.
function server.xSlot_applyHitResult(endPos, hitTarget, isHit, isHitStellarisBody, weaponType)
    DebugWatch("server.xSlot_applyHitResult", 111111)
    if not isHit then
        return
    end
    if isHitStellarisBody then
        local targetShip = server.ensureShipState(hitTarget, defaultShipType)
        if targetShip == nil then
            return
        end

        local targetShipData = (shipData and shipData[targetShip.shipType]) or (shipData and shipData[defaultShipType]) or {}
        local targetWeaponData = (weaponData and weaponData[weaponType]) or (weaponData and weaponData.tachyonLance) or {}
        local damageMin = targetWeaponData.damageMin or 0
        local damageMax = targetWeaponData.damageMax or damageMin
        if damageMax < damageMin then
            damageMax = damageMin
        end

        local rolledDamage = damageMin
        if damageMax > damageMin then
            rolledDamage = math.random(damageMin, damageMax)
        end

        DebugWatch(
            "targetShipHPBefore",
            string.format(
                "shieldHP=%s armorHP=%s bodyHP=%s rolledDamage=%s weaponType=%s",
                tostring(targetShip.shieldHP or 0),
                tostring(targetShip.armorHP or 0),
                tostring(targetShip.bodyHP or 0),
                tostring(rolledDamage),
                tostring(weaponType)
            )
        )

        local function _applyLayerDamage(currentHp, damageFix)
            DebugWatch("_applyLayerDamage", 111111)
            local actualDamage = rolledDamage * (damageFix or 1)
            local nextHp = currentHp - actualDamage
            if nextHp < 0 then
                nextHp = 0
            end
            return nextHp
        end

        if (targetShip.shieldHP or 0) > 0 then
            targetShip.shieldHP = _applyLayerDamage(targetShip.shieldHP, targetWeaponData.shieldFix)
            if targetShip.shieldHP > (targetShipData.shieldHP or targetShip.shieldHP) then
                targetShip.shieldHP = targetShipData.shieldHP or targetShip.shieldHP
            end
            DebugWatch(
                "targetShipHPAfter",
                string.format(
                    "shieldHP=%s armorHP=%s bodyHP=%s damagedLayer=shield",
                    tostring(targetShip.shieldHP or 0),
                    tostring(targetShip.armorHP or 0),
                    tostring(targetShip.bodyHP or 0)
                )
            )
            return
        end

        if (targetShip.armorHP or 0) > 0 then
            targetShip.armorHP = _applyLayerDamage(targetShip.armorHP, targetWeaponData.armorFix)
            if targetShip.armorHP > (targetShipData.armorHP or targetShip.armorHP) then
                targetShip.armorHP = targetShipData.armorHP or targetShip.armorHP
            end
            DebugWatch(
                "targetShipHPAfter",
                string.format(
                    "shieldHP=%s armorHP=%s bodyHP=%s damagedLayer=armor",
                    tostring(targetShip.shieldHP or 0),
                    tostring(targetShip.armorHP or 0),
                    tostring(targetShip.bodyHP or 0)
                )
            )
            return
        end

        if (targetShip.bodyHP or 0) > 0 then
            targetShip.bodyHP = _applyLayerDamage(targetShip.bodyHP, targetWeaponData.bodyFix)
            if targetShip.bodyHP > (targetShipData.bodyHP or targetShip.bodyHP) then
                targetShip.bodyHP = targetShipData.bodyHP or targetShip.bodyHP
            end
            DebugWatch(
                "targetShipHPAfter",
                string.format(
                    "shieldHP=%s armorHP=%s bodyHP=%s damagedLayer=body",
                    tostring(targetShip.shieldHP or 0),
                    tostring(targetShip.armorHP or 0),
                    tostring(targetShip.bodyHP or 0)
                )
            )
            return
        end

        return
    end
    if endPos == nil then
        return
    end

    -- Teardown API: Explosion(pos, size) 其中 size 范围 0.5 - 4.0
    Explosion(endPos, 4.0)
end

-- 广播 开始充能
function server.xSlot_broadcastChargingStart(shipBodyId, firePosOffsetShip, weaponType)
    DebugWatch("server_broadcastChargingStart", 111111)
    -- 广播给所有客户端
    ClientCall(0, "client_ReceiveBroadcastChargingStart", shipBodyId, firePosOffsetShip, weaponType)
end

-- 广播 开始发射
-- 参数:发射刚体ID,发射点,命中点,是否命中,命中角度,是否命中群星飞船(暂定命中群星飞船就一定会触发护盾特效),武器类型
function server.xSlot_broadcastLaunchingStart(shipBodyId, firePoint, hitPoint, didHit, hitTarget, didHitStellarisBody, weaponType ,normal)
    DebugWatch("server.broadcastLaunchingStart", 111111)
    ClientCall(0, "client_ReceiveBroadcastLaunchingStart", shipBodyId, firePoint, hitPoint, didHit, hitTarget, didHitStellarisBody, weaponType, normal)
end

-- 广播 武器回到 idle
function server.xSlot_broadcastWeaponIdle(shipBodyId)
    DebugWatch("server_broadcastWeaponIdle", 111111)
    -- 广播给所有客户端：该 ship 的 xSlot 回到 idle
    ClientCall(0, "client_ReceiveBroadcastWeaponIdle", shipBodyId)
end

function server.xSlotControlTick(dt)
    DebugWatch("server.xSlotControlTick", 111111)
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
            server.xSlot_broadcastChargingStart(server.shipBody, firePosOffsetShip, weaponType)
        elseif server.weaponState == "launching" then
            -- 根据发射点和飞船朝向计算命中点,命中倾斜角以及命中信息(是否直接命中船体or命中非群星飞船)
            local endPos, hitTarget, isHit, isHitStellarisBody, normal = server.xSlot_computeHitResult(server.shipBody,firePosOffsetShip,fireDirRelative)
            -- 根据信息结算 命中效果
            server.xSlot_applyHitResult(endPos, hitTarget, isHit, isHitStellarisBody, weaponType)
            -- 广播发射信息
            server.xSlot_broadcastLaunchingStart(server.shipBody,firePosOffsetShip, endPos, isHit, hitTarget, isHitStellarisBody, weaponType, normal)
        elseif server.weaponState == "idle" then
            -- 广播 结束发射信息
            server.xSlot_broadcastWeaponIdle(server.shipBody)
        end
    end
    server.weaponStateLastTick = server.weaponState
end

