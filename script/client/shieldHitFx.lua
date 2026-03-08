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
    local p1 = (client and client.p1) or 0.10
    local p2 = (client and client.p2) or 0.50
    local p3 = (client and client.p3) or 0.18
    local p4 = (client and client.p4) or 6
    local roundTime = (client and client.shieldHitRoundTime) or 0.10
    local fxShieldRadius = shieldRadius or 7

    local shieldTotalTime = math.max(0.0, p4) * math.max(0.001, roundTime)
    local impactTotalTime = 0.25

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

                            if round == 1 then
                                SpawnParticle(fx.hitPoint, Vec(0, 0, 0), roundTime)

                                -- 冲击波粒子：命中点切平面生成多圈密集粒子，沿法线扩散
                                ParticleReset()
                                ParticleColor(0.20, 0.95, 1.00, 0.10, 0.35, 1.00)
                                ParticleRadius(0.13, 0.03, "easeout")
                                ParticleAlpha(0.85, 0.0)
                                ParticleGravity(0.0)
                                ParticleDrag(0.18)
                                ParticleEmissive(18.0, 0.0)
                                ParticleCollide(0.0)
                                -- 多圈冲击波，半径逐步增大
                                for ring=1,4 do
                                    local baseCount = 20 + ring * 6
                                    local count = baseCount + math.random(-4,4)
                                    local radius = 0.15 * ring + 0.10 * math.random()
                                    local speedFactor = 5.0 + ring * 2.0
                                    for i = 1, count do
                                        local a = ((i - 1) / count) * math.pi * 2.0
                                        local lateral = VecAdd(VecScale(t1, math.cos(a)), VecScale(t2, math.sin(a)))
                                        local p = VecAdd(fx.hitPoint, VecScale(lateral, radius))
                                        local vel = VecAdd(VecScale(lateral, speedFactor + 2.0 * math.random()), VecScale(n, 1.5 * math.random()))
                                        SpawnParticle(p, vel, 0.16 + 0.12 * math.random())
                                    end
                                end

                                -- 飞溅粒子：命中点周围随机生成，速度偏离法线
                                ParticleReset()
                                ParticleColor(0.95, 1.0, 1.0, 0.25, 0.95, 1.0)
                                ParticleRadius(0.09, 0.02, "easeout")
                                ParticleAlpha(0.9, 0.0)
                                ParticleGravity(0.0)
                                ParticleDrag(0.15)
                                ParticleEmissive(16.0, 0.0)
                                ParticleCollide(0.0)
                                local splashCount = 24
                                for i = 1, splashCount do
                                    local randDir = VecAdd(VecScale(n, 1.0), VecScale(t1, (math.random()-0.5)*1.6), VecScale(t2, (math.random()-0.5)*1.6))
                                    local randLen = VecLength(randDir)
                                    if randLen < 0.001 then randLen = 1.0 end
                                    local dir = VecScale(randDir, 1.0 / randLen)
                                    local vel = VecScale(dir, 12.0 + 8.0 * math.random())
                                    SpawnParticle(fx.hitPoint, vel, 0.16 + 0.10 * math.random())
                                end
                            else
                                local R = fxShieldRadius
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
