
-- 统一飞船数据表
-- 将多个飞船的参数放在一起，便于维护与扩展
shipData = shipData or {}

shipData.enigmaticCruiser = {
    shipType = "enigmaticCruiser", -- 飞船类型标识，用于客户端渲染选择特效
    firePosOffsetShip = Vec(0, 0, 4), -- 默认的发射点相对于飞船中心的偏移
    fireDirRelative = Vec(0, 0, 1), -- 默认的发射方向（相对飞船）
    shieldRadius = 7, -- 目标飞船护盾球半径
    shieldHP = 5000, -- 护盾HP
    armorHP = 3000, -- 装甲HP
    bodyHP = 2000, -- 机体HP
    shieldRecoveryRate = 50, -- 护盾每秒恢复量
    armorRecoveryRate = 20, -- 装甲每秒恢复量
    xSlotNum = 2, -- X位数量
}

-- 可以在此处继续添加更多武器配置，例如：
-- weaponData.plasmaCannon = { ... }
