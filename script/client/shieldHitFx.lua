-- xSlot 命中特效模块（从 test2.lua 拆分）
-- 说明：本文件通过 #include 方式插入到主脚本中，因此会共享同一个 Lua chunk。
-- 建议：像 shieldRadius 这类来自主脚本 local 的值，优先由主脚本调用时显式传参，
--      不要依赖 include 后对外层 local 的隐式可见性。

---@diagnostic disable: undefined-global
---@diagnostic disable: duplicate-set-field

client = client or {}

-- 命中特效队列：用于“上一轮护盾特效不会因下一轮 launching 立即消失”，而是播放到时间耗尽
client.shieldHitFx = client.shieldHitFx or {
    nextId = 1,
    items = {
        -- [id] = { kind="shield"|"impact", startTime=number, hitTarget=number|nil, hitPoint=Vec }
    }
}

-- 命中特效辅助函数
function client.shieldHitFxEnqueue(kind, hitTarget, hitPoint)
    if hitPoint == nil or hitPoint == false then
        return
    end
    local id = client.shieldHitFx.nextId or 1
    client.shieldHitFx.nextId = id + 1
    client.shieldHitFx.items[id] = {
        kind = kind,
        startTime = GetTime(),
        hitTarget = hitTarget,
        hitPoint = hitPoint,
    }
end

-- 命中特效更新与渲染函数：客户端帧调用函数,唯二会被其他文件调用的函数之一
function client.shieldHitFxTick(now, shieldRadius)
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
    local p1 = (client and client.p1) or 5 -- 粒子初始半径
    local p2 = (client and client.p2) or 0.50 -- 每轮环带基础位移
    local p3 = (client and client.p3) or 0.05 -- 环带粒子最小间距（影响每轮数量）
    local p4 = (client and client.p4) or 20    -- 轮数
    local roundTime = (client and client.shieldHitRoundTime) or 0.50
    local fxShieldRadius = shieldRadius or 7
    -- 新增：中心点球面持续发光半径（控制在命中点附近多近的范围内持续产生亮点）
    local centerSpawnRadius = (client and client.shieldHitCenterRadius) or 0.5
    local centerSpawnCount = (client and client.shieldHitCenterCount) or 20
    -- 每轮环带的基础粒子数（随轮数可递增）
    local baseParticleCount = (client and client.shieldHitBaseParticleCount) or 18

    local shieldTotalTime = math.max(0.0, p4) * math.max(0.001, roundTime)
    local impactTotalTime = 1

    for id, fx in pairs(client.shieldHitFx.items) do
        local age = now - (fx.startTime or now)

        if fx.kind == "impact" then
            if age > impactTotalTime then
                client.shieldHitFx.items[id] = nil
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
                client.shieldHitFx.items[id] = nil
            else
                local hitTarget = fx.hitTarget
                if hitTarget == nil or hitTarget == 0 then
                    client.shieldHitFx.items[id] = nil
                elseif IsHandleValid ~= nil and (not IsHandleValid(hitTarget)) then
                    client.shieldHitFx.items[id] = nil
                else
                    local bodyT = GetBodyTransform(hitTarget)
                    local comLocal = GetBodyCenterOfMass(hitTarget)
                    local center = TransformToParentPoint(bodyT, comLocal)

                    local n = VecSub(fx.hitPoint, center)
                    n = _safeNormalize(n, nil)
                    if n == nil then
                        client.shieldHitFx.items[id] = nil
                    else
                        local t1, t2 = _buildPerpBasis(n)

                        local round = math.floor(age / math.max(0.001, roundTime)) + 1
                        if round > p4 then
                            client.shieldHitFx.items[id] = nil
                        else
                            ParticleReset()
                            ParticleColor(0.20, 0.95, 1.00, 0.10, 0.35, 1.00)
                            ParticleRadius(p1, p1)
                            ParticleAlpha(1.0, 0.0)
                            ParticleGravity(0.0)
                            ParticleDrag(0.0)
                            ParticleEmissive(18.0, 0.0)
                            ParticleCollide(0.0)

                            -- 每轮开始或进行时：
                            -- 1) 中心点附近持续产生随机白色亮点（在命中点附近的球面/球体内随机分布）
                            for i = 1, centerSpawnCount do
                                local dirRnd = Vec(math.random()-0.5, math.random()-0.5, math.random()-0.5)
                                local l = VecLength(dirRnd)
                                if l < 0.0001 then l = 1.0 end
                                dirRnd = VecScale(dirRnd, 1.0 / l)
                                local r = math.random() * centerSpawnRadius
                                local p = VecAdd(fx.hitPoint, VecScale(dirRnd, r))
                                local vel = VecScale(dirRnd, 1.5 * (0.5 + math.random()))
                                ParticleReset()
                                ParticleColor(1.0, 1.0, 1.0, 0.6, 1.0, 1.0)
                                ParticleRadius(p1 * 0.9, p1 * 0.5, "easeout")
                                ParticleAlpha(0.95, 0.0)
                                ParticleGravity(0.0)
                                ParticleDrag(0.1)
                                ParticleEmissive(18.0, 0.0)
                                ParticleCollide(0.0)
                                SpawnParticle(p, vel, roundTime)
                            end

                            -- 2) 环带随机波纹扩散（在命中点切平面上以环带形式随机分布亮点）
                            local inner = math.max(0.0, (round - 1) * p2)
                            local outer = inner + math.max(0.01, p2 * 1.2)
                            -- 随轮数增长，环带半径会逐步增大，直到轮数结束
                            local ringCount = math.floor(baseParticleCount + (round - 1) * 4 + 0.5)
                            if ringCount < 6 then ringCount = 6 end
                            for i = 1, ringCount do
                                local a = math.random() * math.pi * 2.0
                                local r = inner + math.random() * (outer - inner)
                                local lateral = VecAdd(VecScale(t1, math.cos(a)), VecScale(t2, math.sin(a)))
                                local p = VecAdd(fx.hitPoint, VecScale(lateral, r))
                                local vel = VecAdd(VecScale(lateral, 6.0 + 4.0 * math.random()), VecScale(n, 0.6 * (0.5 + math.random())))
                                ParticleReset()
                                ParticleColor(0.1, 0, 1.0, 0.1, 0.7, 1.0)
                                ParticleRadius(p1, p1 * 0.5, "easeout")
                                ParticleAlpha(0.95, 0.0)
                                ParticleGravity(0.0)
                                ParticleDrag(0.05)
                                ParticleEmissive(18.0, 0.0)
                                ParticleCollide(0.0)
                                SpawnParticle(p, vel, roundTime)
                            end
                        end
                    end
                end
            end
        else
            -- 未知类型，丢弃
            client.shieldHitFx.items[id] = nil
        end
    end
end

-- 客户端函数:渲染命中点 特效，唯二会被其他文件调用的函数之一.在特效开始的时候被调用
function client.shieldHitFxStart(hitTarget, hitPoint, didHitStellarisBody)
    if hitPoint == nil or hitPoint == false then
        return
    end

    if didHitStellarisBody then
        client.shieldHitFxEnqueue("shield", hitTarget, hitPoint)
    else
        client.shieldHitFxEnqueue("impact", hitTarget, hitPoint)
    end
end
