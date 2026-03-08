

client = client or {}

-- 客户端初始化函数

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

-- 客户端函数:注册飞船刚体工具函数.在每个飞船刚体被创建的第一帧被调用
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

-- 客户端函数:发射请求函数,点击左键时调用,向服务端发送发射请求
function client.fire()
    if InputPressed("lmb") then
        DebugWatch("client_fire", 111111111111111)
        ServerCall("server_handleFireRequest")
    end
end

-- 接收来自客户端的充能广播 在充能的第一帧被调用
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

-- 客户端函数:接收来自客户端的发射广播 在发射的第一帧被调用
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

-- 客户端函数:接收来自客户端的空闲广播 在空闲的第一帧被调用
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

#include "xSlotChargingFx.lua" -- 充能模块渲染函数
#include "xSlotLaunchFx.lua" -- 发射模块渲染函数
#include "shieldHitFx.lua" -- 护盾命中特效模块渲染函数

function client.clientTick(dt)
    client.fire()
    DebugWatch("clientTime", 111111111111111)
    -- 遍历所有注册的飞船
    for shipBodyId, shipData in pairs(client.ships) do
        local xSlot = shipData.weapons.xSlot
        local state = xSlot.state

        -- 只在进入 launching 的第一帧触发一次命中特效（避免每帧重复入队）
        if xSlot._lastState ~= state then
            if state == "launching" then
                client.shieldHitFxStart(xSlot.hitTarget, xSlot.hitPoint, xSlot.didHitStellarisBody)
            end
            xSlot._lastState = state
        end

        if state == "charging" then
            -- 蓄力阶段渲染
            client.xSlotChargingFxStart(shipBodyId, xSlot.firePoint, xSlot.weaponType)
        elseif state == "launching" then
            -- 发射阶段渲染
            client.xSlotLaunchFxStart(shipBodyId, xSlot.firePoint, xSlot.hitPoint, xSlot.weaponType)
        elseif state == "idle" then
            -- 静默阶段不做任何事情
        end
    end
    -- 命中特效独立播放：显式把主脚本的 local shieldRadius 传给模块
    client.shieldHitFxTick(GetTime(), shieldRadius)

    -- 仅对 charging 特效做一次轻量 GC（不会影响其它特效）
    client.xSlotChargingFxTick(GetTime())

    client.xSlotLaunchFxTick(GetTime())
end