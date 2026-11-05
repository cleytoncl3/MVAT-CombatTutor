--[[
    MVAT - Tutor de Combate (WoW Classic / Classic Era / Forever)
    ------------------------------------------------------------------
    Assistente 100% INFORMATIVO e VISUAL. Nao executa nenhuma acao,
    nao lanca feiticos, nao clica e nao altera barras de acao.

    Estrutura do arquivo:
      1. Configuracao / SavedVariables
      2. Camada de compatibilidade de API (Classic antigo x C_Spell novo)
      3. Livro de feiticos (somente o que ja foi aprendido)
      4. Leitura de atalhos (keybinds) independente do addon de barras
      5. Coleta de contexto de combate (auras, casts, grupo, inimigos)
      6. Construtores de regras (interrupt, dispel, buff, cura...)
      7. Tabelas de regras por classe
      8. Motor de decisao
      9. HUD flutuante (ancora propria, compativel com ElvUI)
     10. Eventos e comandos de chat (/mvat e /tutor)
]]

local ADDON_NAME = ...

---------------------------------------------------------------------------
-- 1. CONFIGURACAO
---------------------------------------------------------------------------
local DEFAULTS = {
    point = "CENTER", relPoint = "CENTER", x = 0, y = -180,
    scale = 1.0,
    locked = true,
    enabled = true,
    combatOnly = false,  -- true = so mostra em combate
    aoe = 3,             -- n. de inimigos para considerar "area / farm"
    showText = true,     -- mostra o motivo da sugestao abaixo do icone
    barOnly = true,      -- so sugere habilidades que estao nas suas barras de acao
    seal = "auto",       -- Paladino: "auto" escolhe o selo pelo contexto; ou fixe um selo
}

local DB -- preenchido no ADDON_LOADED

local UPDATE_INTERVAL = 0.10   -- avaliacao 10x por segundo (leve)
local GROUP_SCAN_INTERVAL = 0.25

---------------------------------------------------------------------------
-- 2. COMPATIBILIDADE DE API
---------------------------------------------------------------------------
local C_Spell = C_Spell
local GetTime = GetTime

-- VALORES SECRETOS (WoW Forever / motor moderno): em combate a API pode devolver
-- valores "secretos". Comparar, somar ou testar um deles gera erro de Lua, entao
-- TODA leitura passa por Pub/Is: valor secreto vira nil/false ("desconhecido") e
-- a regra que dependia dele simplesmente nao dispara.
local issecret = type(issecretvalue) == "function" and issecretvalue or function() return false end
local function Pub(v) if issecret(v) then return nil end return v end
local function Is(v) if issecret(v) then return false end return v and true or false end
local function PubAll(...)
    for i = 1, select("#", ...) do if issecret((select(i, ...))) then return end end
    return ...
end

local function UnitExists(u) return Is(_G.UnitExists(u)) end
local function UnitIsDeadOrGhost(u) return Is(_G.UnitIsDeadOrGhost(u)) end
local function UnitIsUnit(a, b) return Is(_G.UnitIsUnit(a, b)) end
local function UnitCanAttack(a, b) return Is(_G.UnitCanAttack(a, b)) end
local function UnitIsDead(u) return Is(_G.UnitIsDead(u)) end
local function UnitAffectingCombat(u) return Is(_G.UnitAffectingCombat(u)) end

-- Retorna nome localizado e icone a partir do Spell ID (funciona em ptBR e enUS)
local function SpellInfo(id)
    if C_Spell and C_Spell.GetSpellInfo then
        local info = C_Spell.GetSpellInfo(id)
        if info then return Pub(info.name), Pub(info.iconID) end
        return nil
    end
    local name, _, icon = GetSpellInfo(id)
    return Pub(name), Pub(icon)
end

-- Recarga. Em combate o Forever esconde inicio/duracao, mas "isActive" e
-- "isOnGCD" continuam LIMPOS (mesma leitura que o EllesmereUI usa no FocusKick).
-- Retorna start, duration, active, onGCD (active/onGCD = nil quando desconhecidos).
-- Recarga totalmente desconhecida conta como pronta: o jogo ainda impede o uso.
local function SpellCooldown(spell)
    if C_Spell and C_Spell.GetSpellCooldown then
        local cd = C_Spell.GetSpellCooldown(spell)
        if cd then
            return Pub(cd.startTime) or 0, Pub(cd.duration) or 0, Pub(cd.isActive), Pub(cd.isOnGCD)
        end
        return 0, 0
    end
    local start, duration = GetSpellCooldown(spell)
    return Pub(start) or 0, Pub(duration) or 0
end

-- true = usavel, false = nao, nil = desconhecido
local function SpellUsable(spell)
    local usable
    if C_Spell and C_Spell.IsSpellUsable then usable = C_Spell.IsSpellUsable(spell)
    else usable = IsUsableSpell(spell) end
    if issecret(usable) then return nil end
    return usable and true or false
end

-- true = no alcance, false = fora de alcance, nil = sem alcance ou desconhecido
local function SpellInRange(spell, unit)
    local r
    if C_Spell and C_Spell.IsSpellInRange then r = C_Spell.IsSpellInRange(spell, unit)
    else r = IsSpellInRange(spell, unit) end
    if r == nil or issecret(r) then return nil end
    return r == true or r == 1
end

-- No Forever a leitura de auras por indice nao devolve um valor secreto: ela
-- GERA ERRO ("Auras cannot be accessed when secret"). Antes de varrer auras,
-- testamos com pcall (mesma tecnica do EllesmereUI). Resultado cacheado por frame.
local restrictedStamp, restrictedValue = -1, false
local function AurasRestricted()
    local now = GetTime()
    if now == restrictedStamp then return restrictedValue end
    restrictedStamp = now
    restrictedValue = false
    if C_Secrets and C_Secrets.ShouldAurasBeSecret then
        local ok, v = pcall(C_Secrets.ShouldAurasBeSecret)
        if not ok or issecret(v) or v then restrictedValue = true; return true end
    end
    if C_UnitAuras and C_UnitAuras.GetAuraDataByIndex
        and not pcall(C_UnitAuras.GetAuraDataByIndex, "player", 1, "HELPFUL") then
        restrictedValue = true
    end
    return restrictedValue
end

-- Itera auras de uma unidade: fn(name, dispelType, source, expiration, stacks)
-- retornar true dentro de fn interrompe a iteracao. Auras secretas sao puladas.
-- Retorna false quando as auras estao bloqueadas (nada foi lido).
local function ForEachAura(unit, filter, fn)
    if AurasRestricted() then return false end
    if C_UnitAuras and C_UnitAuras.GetAuraDataByIndex then
        for i = 1, 40 do
            local ok, a = pcall(C_UnitAuras.GetAuraDataByIndex, unit, i, filter)
            if not ok then return false end
            if not a or issecret(a) then return true end
            local name = Pub(a.name)
            if name and fn(name, Pub(a.dispelName), Pub(a.sourceUnit), Pub(a.expirationTime), Pub(a.applications), Pub(a.duration)) then
                return true
            end
        end
    else
        for i = 1, 40 do
            local ok, name, _, count, dtype, _, expiration, source = pcall(UnitAura, unit, i, filter)
            if not ok then return false end
            if name == nil then return true end
            name = Pub(name)
            if name and fn(name, Pub(dtype), Pub(source), Pub(expiration), Pub(count), nil) then return true end
        end
    end
    return true
end

-- Consulta de UMA aura do jogador pelo Spell ID, permitida em combate quando o
-- jogo libera aquele feitico (C_Secrets.ShouldSpellAuraBeSecret == false).
-- true = ativa, false = ausente, nil = desconhecido.
local function PlayerAuraByID(id)
    if not (C_UnitAuras and C_UnitAuras.GetPlayerAuraBySpellID) then return nil end
    if C_Secrets and C_Secrets.ShouldSpellAuraBeSecret then
        local ok, secret = pcall(C_Secrets.ShouldSpellAuraBeSecret, id)
        if not ok or issecret(secret) or secret ~= false then return nil end
    end
    local ok, aura = pcall(C_UnitAuras.GetPlayerAuraBySpellID, id)
    if not ok or issecret(aura) then return nil end
    return aura ~= nil
end

-- Porcentagem de vida, ou nil quando a vida esta secreta
local function UnitPct(unit)
    local cur, max = Pub(UnitHealth(unit)), Pub(UnitHealthMax(unit))
    if not cur or not max or max == 0 then return nil end
    return cur / max * 100
end

---------------------------------------------------------------------------
-- 3. LIVRO DE FEITICOS
---------------------------------------------------------------------------
-- Todas as habilidades usadas pelas regras. O nome e resolvido via ID, entao
-- qualquer rank aprendido conta (o addon compara pelo nome localizado).
local ID = {
    -- Guerreiro
    PUMMEL = 6552, SHIELD_BASH = 72, SHIELD_WALL = 871, LAST_STAND = 12975, SHIELD_BLOCK = 2565,
    EXECUTE = 5308, OVERPOWER = 7384, REVENGE = 6572, BATTLE_SHOUT = 6673, SUNDER = 7386,
    HEROIC_STRIKE = 78, CLEAVE = 845, THUNDER_CLAP = 6343, WHIRLWIND = 1680, BLOODTHIRST = 23881,
    MORTAL_STRIKE = 12294, SHIELD_SLAM = 23922, REND = 772, SWEEPING = 12292, DEMO_SHOUT = 1160,
    INTIM_SHOUT = 5246, TAUNT = 355, BERSERKER_RAGE = 18499,
    -- Ladino
    KICK = 1766, GOUGE = 1776, EVASION = 5277, VANISH = 1856, SINISTER = 1752, EVISCERATE = 2098,
    SND = 5171, RIPOSTE = 14251, BLADE_FLURRY = 13877, KIDNEY = 408, ADRENALINE = 13750,
    -- Mago
    COUNTERSPELL = 2139, REMOVE_LESSER_CURSE = 475, ICE_BLOCK = 11958, FROST_NOVA = 122,
    FROSTBOLT = 116, FIREBALL = 133, FIRE_BLAST = 2136, ARCANE_EXPLOSION = 1449, BLIZZARD = 10,
    CONE_OF_COLD = 120, MANA_SHIELD = 1463, ICE_BARRIER = 11426, ARCANE_INTELLECT = 1459,
    FROST_ARMOR = 168, ICE_ARMOR = 7302, MAGE_ARMOR = 6117, EVOCATION = 12051,
    MAGE_CLEARCAST = 12536, PRESENCE_OF_MIND = 12043, PYROBLAST = 11366, ARCANE_POWER = 12042,
    COMBUSTION = 11129, SCORCH = 2948, ARCANE_MISSILES = 5143,
    -- Sacerdote
    PW_SHIELD = 17, WEAKENED_SOUL = 6788, RENEW = 139, LESSER_HEAL = 2050, HEAL = 2054,
    FLASH_HEAL = 2061, GREATER_HEAL = 2060, DISPEL_MAGIC = 527, CURE_DISEASE_P = 528,
    ABOLISH_DISEASE = 552, FADE = 586, PSYCHIC_SCREAM = 8122, SILENCE = 15487, SWP = 589,
    MIND_BLAST = 8092, MIND_FLAY = 15407, SMITE = 585, INNER_FIRE = 588, PW_FORT = 1243,
    INNER_FOCUS = 14751, HOLY_FIRE = 14914, SHADOWFORM = 15473, DESPERATE_PRAYER = 13908,
    -- Paladino
    SOR = 21084, SOTC = 21082, SOC = 20375, SOL = 20165, SOW = 20166, SOJ = 20164,
    JUDGEMENT = 20271, HOJ = 853, DIVINE_SHIELD = 642, DIVINE_PROT = 498, BOP = 1022,
    LOH = 633, HOLY_LIGHT = 635, FOL = 19750, PURIFY = 1152, CLEANSE = 4987,
    CONSECRATION = 26573, HOLY_SHIELD = 20925, EXORCISM = 879, HOW = 24275,
    BOM = 19740, BOW = 19742, BOK = 20217, BOSANC = 20911,
    DEVOTION = 465, RET_AURA = 7294, RIGHTEOUS_FURY = 25780, HOLY_SHOCK = 20473,
    HOLY_STRIKE = 679, SEAL_FURY = 1311649, HOLY_WRATH = 2812, TURN_UNDEAD = 2878,
    -- Cacador
    SERPENT = 1978, MARK = 1130, ARCANE_SHOT = 3044, MULTI = 2643, AIMED = 19434,
    RAPTOR = 2973, MONGOOSE = 1495, WING_CLIP = 2974, FEIGN = 5384, DETERRENCE = 19263,
    HAWK = 13165, MONKEY = 13163, RAPID_FIRE = 3045, MEND_PET = 136, DISENGAGE = 781,
    CONCUSSIVE = 5116, SCATTER = 19503, VOLLEY = 1510,
    -- Bruxo
    SHADOW_BOLT = 686, CORRUPTION = 172, COA = 980, IMMOLATE = 348, LIFE_TAP = 1454,
    DRAIN_LIFE = 689, DEATH_COIL = 6789, HOWL = 5484, SHADOWBURN = 17877, HELLFIRE = 1949,
    RAIN_OF_FIRE = 5740, DEMON_SKIN = 687, DEMON_ARMOR = 706, SHADOW_TRANCE = 17941,
    DRAIN_SOUL = 1120, COW = 702, COE = 1490, COS = 17862, COR = 704, COT = 1714,
    -- Xama
    EARTH_SHOCK = 8042, CURE_POISON_S = 526, CURE_DISEASE_S = 2870, PURGE = 370,
    LIGHTNING_BOLT = 403, CHAIN_LIGHTNING = 421, FLAME_SHOCK = 8050, FROST_SHOCK = 8056,
    HEALING_WAVE = 331, LHW = 8004, CHAIN_HEAL = 1064, LIGHTNING_SHIELD = 324,
    ROCKBITER = 8017, FLAMETONGUE = 8024, WINDFURY = 8232, STORMSTRIKE = 17364,
    SHAMAN_CLEARCAST = 16246, GROUNDING = 8177, SEARING = 3599, MAGMA = 8190,
    NS_SHAMAN = 16188, ELEM_MASTERY = 16166,
    -- Druida
    BASH = 5211, FERAL_CHARGE = 16979, REMOVE_CURSE = 2782, CURE_POISON_D = 8946,
    ABOLISH_POISON = 2893, BARKSKIN = 22812, FRENZIED = 22842, MOONFIRE = 8921, WRATH = 5176,
    STARFIRE = 2912, INSECT_SWARM = 5570, REJUV = 774, REGROWTH = 8936, HEALING_TOUCH = 5185,
    SWIFTMEND = 18562, MOTW = 1126, THORNS = 467, BEAR = 5487, DIRE_BEAR = 9634, CAT = 768,
    CLAW = 1082, RAKE = 1822, RIP = 1079, BITE = 22568, SHRED = 5221, MAUL = 6807,
    SWIPE = 779, DEMO_ROAR = 99, GROWL = 6795, HURRICANE = 16914, DRUID_CLEARCAST = 16870,
    TIGERS_FURY = 5217, FAERIE_FIRE = 770, FAERIE_FIRE_FERAL = 16857, NS_DRUID = 17116,
    -- Habilidades novas/trocadas do Forever (IDs do treinador)
    CHARGE = 100, VICTORY_RUSH = 402927, SLAM = 1464, BLOODRAGE = 2687, HAMSTRING = 1715, RECKLESSNESS = 1719,
    RETALIATION = 20230, INTERCEPT = 20616, BACKSTAB = 53, AMBUSH = 8676, GARROTE = 703, CHEAP_SHOT = 1833,
    RUPTURE = 1943, FEINT = 1966, MUTILATE = 1241582, ARCANE_BLAST = 1239696, ICE_LANCE = 400640,
    FROSTFIRE = 401502, BLAST_WAVE = 13018, FLAMESTRIKE = 2120, PENANCE = 1240720, PRAYER_OF_MENDING = 1240826,
    SW_DEATH = 1309595, HOLY_NOVA = 15430, BINDING_HEAL = 401937, PRAYER_OF_HEALING = 596,
    DEVOURING_PLAGUE = 2944, COUNTERATTACK = 20909, CONFLAGRATE = 17962, SEARING_PAIN = 5676, SOUL_FIRE = 6353,
    INCINERATE = 1293812, SIPHON_LIFE = 18879, FEAR = 5782, LACERATE = 414644, POUNCE = 9005, RAVAGE = 6785,
    FIRE_NOVA = 408341,
}

-- IDs alternativos (todos os ranks do treinador do Forever) para achar a habilidade mesmo se o ID principal
-- nao existir no cliente. Gerado a partir dos dados do WhatsTraining (Camelot) e do ForeverAuras.
local ALT = {
    CHARGE = {100, 6178, 11578},
    VICTORY_RUSH = {402927},
    SLAM = {1464, 8820, 11604, 11605, 1240193},
    BLOODRAGE = {2687},
    HAMSTRING = {1715, 7372, 7373},
    RECKLESSNESS = {1719},
    RETALIATION = {20230},
    INTERCEPT = {20616, 20617},
    BACKSTAB = {53, 2589, 2590, 2591, 8721, 11279, 11280, 11281},
    AMBUSH = {8676, 8724, 8725, 11267, 11268, 11269},
    GARROTE = {703, 8631, 8632, 8633, 11289, 11290},
    CHEAP_SHOT = {1833},
    RUPTURE = {1943, 8639, 8640, 11273, 11274, 11275},
    FEINT = {1966, 6768, 8637, 11303},
    MUTILATE = {1241582, 1241584},
    ARCANE_BLAST = {1239696, 1239697, 1239699, 1239700},
    ICE_LANCE = {400640, 1240044, 1240045, 1240046, 1240047},
    FROSTFIRE = {401502, 1237312, 1237313},
    BLAST_WAVE = {13018, 13019, 13020, 13021},
    FLAMESTRIKE = {2120, 2121, 8422, 8423, 10215, 10216},
    PENANCE = {1240720, 1240721, 1316995},
    PRAYER_OF_MENDING = {1240826, 1240827},
    SW_DEATH = {1309595, 1309633, 1309635, 1309636},
    HOLY_NOVA = {15430, 15431, 27799, 27800, 27801},
    BINDING_HEAL = {401937, 402837, 1240770, 1240771, 1240772, 1240773, 1240774},
    PRAYER_OF_HEALING = {596, 996, 10960, 10961},
    DEVOURING_PLAGUE = {2944, 19276, 19277, 19278, 19279, 19280},
    COUNTERATTACK = {20909, 20910, 1242634},
    CONFLAGRATE = {17962, 18930, 18931, 18932, 1293818},
    SEARING_PAIN = {5676, 17919, 17920, 17921, 17922, 17923},
    SOUL_FIRE = {6353, 17924},
    INCINERATE = {1293812, 1293813},
    SIPHON_LIFE = {18879, 18880, 18881},
    FEAR = {5782, 6213, 6215},
    LACERATE = {414644, 1235826, 1235827},
    POUNCE = {9005, 9823, 9827},
    RAVAGE = {6785, 6787, 9866, 9867},
    FIRE_NOVA = {408341, 408342, 408343, 408344, 408345},
    ABOLISH_POISON = {2893},
    AIMED = {19434, 20900, 20901, 20902, 20903, 20904},
    ARCANE_EXPLOSION = {1449, 8437, 8438, 8439, 10201, 10202},
    ARCANE_INTELLECT = {1459, 1460, 1461, 10156, 10157},
    ARCANE_MISSILES = {5143, 5144, 5145, 8416, 8417, 10211, 10212},
    ARCANE_SHOT = {3044, 14281, 14282, 14283, 14284, 14285, 14286, 14287},
    BARKSKIN = {22812},
    BASH = {5211, 6798, 8983},
    BATTLE_SHOUT = {6673, 5242, 6192, 11549, 11550, 11551},
    BITE = {22568, 22827, 22828, 22829},
    BLIZZARD = {10, 6141, 8427, 10185, 10186, 10187},
    BLOODTHIRST = {23892, 23893, 23894},
    BOK = {20217},
    BOM = {19740, 19834, 19835, 19836, 19837, 19838},
    BOP = {1022, 5599, 10278},
    BOW = {19742, 19850, 19852, 19853, 19854},
    CHAIN_HEAL = {1064, 10622, 10623},
    CHAIN_LIGHTNING = {421, 930, 2860, 10605},
    CLAW = {3029, 5201, 9849, 9850},
    CLEANSE = {4987},
    CLEAVE = {845, 7369, 11608, 11609, 20569},
    COA = {980, 1014, 6217, 11711, 11712, 11713},
    CONCUSSIVE = {5116},
    CONE_OF_COLD = {120, 8492, 10159, 10160, 10161},
    CONSECRATION = {26573, 20116, 20922, 20923, 20924},
    COR = {704, 7658, 7659, 11717},
    CORRUPTION = {172, 6222, 6223, 7648, 11671, 11672},
    COT = {1714, 11719},
    COUNTERSPELL = {2139},
    COW = {702, 1108, 6205, 7646, 11707, 11708},
    CURE_DISEASE_P = {528},
    CURE_DISEASE_S = {2870},
    CURE_POISON_S = {526},
    DEATH_COIL = {6789, 17925, 17926},
    DEMON_ARMOR = {706, 1086, 11733, 11734, 11735},
    DEMON_SKIN = {696},
    DEMO_ROAR = {99, 1735, 9490, 9747, 9898},
    DEMO_SHOUT = {1160, 6190, 11554, 11555, 11556},
    DESPERATE_PRAYER = {19236, 19238, 19240, 19241, 19242, 19243},
    DEVOTION = {465, 10290, 643, 10291, 1032, 10292, 10293},
    DIRE_BEAR = {9634},
    DISENGAGE = {781, 14272, 14273},
    DISPEL_MAGIC = {527, 988},
    DIVINE_PROT = {498, 5573},
    DIVINE_SHIELD = {642, 1020},
    DRAIN_LIFE = {689, 699, 709, 7651, 11699, 11700},
    DRAIN_SOUL = {1120, 8288, 8289, 11675},
    EARTH_SHOCK = {8042, 8044, 8045, 8046, 10412, 10413, 10414},
    EVASION = {5277},
    EVISCERATE = {6760, 6761, 6762, 8623, 8624, 11299, 11300},
    EVOCATION = {12051},
    EXECUTE = {5308, 20658, 20660, 20661, 20662},
    EXORCISM = {879, 5614, 5615, 10312, 10313, 10314},
    FADE = {586, 9578, 9579, 9592, 10941, 10942},
    FAERIE_FIRE = {770, 778, 9749, 9907},
    FIREBALL = {143, 145, 3140, 8400, 8401, 8402, 10148, 10149, 10150, 10151},
    FIRE_BLAST = {2136, 2137, 2138, 8412, 8413, 10197, 10199},
    FLAMETONGUE = {8024, 8027, 8030, 16339, 16341, 16342},
    FLAME_SHOCK = {8050, 8052, 8053, 10447, 10448},
    FLASH_HEAL = {2061, 9472, 9473, 9474, 10915, 10916, 10917},
    FOL = {19750, 19939, 19940, 19941, 19942, 19943},
    FRENZIED = {22842},
    FROSTBOLT = {116, 205, 837, 7322, 8406, 8407, 8408, 10179, 10180, 10181},
    FROST_ARMOR = {7300, 7301},
    FROST_NOVA = {122, 865, 6131, 10230},
    FROST_SHOCK = {8056, 8058, 10472, 10473},
    GOUGE = {1776, 1777, 8629, 11285, 11286},
    GREATER_HEAL = {2060, 10963, 10964, 10965},
    GROUNDING = {8177},
    HAWK = {13165, 14318, 14319, 14320, 14321, 14322},
    HEAL = {2054, 2055, 6063, 6064},
    HEALING_TOUCH = {5186, 5187, 5188, 5189, 6778, 8903, 9758, 9888, 9889},
    HEALING_WAVE = {332, 547, 913, 939, 959, 8005, 10395, 10396},
    HELLFIRE = {1949, 11683, 11684},
    HEROIC_STRIKE = {284, 285, 1608, 11564, 11565, 11566, 11567},
    HOJ = {853, 5588, 5589, 10308},
    HOLY_FIRE = {14914, 15262, 15263, 15264, 15265, 15266, 15267, 15261},
    HOLY_LIGHT = {639, 647, 1026, 1042, 3472, 10328, 10329},
    HOLY_SHIELD = {20927, 20928},
    HOLY_SHOCK = {20473, 20929, 20930},
    HOLY_STRIKE = {679, 678, 1866, 680, 2495, 5569, 10332, 10333},
    HOLY_WRATH = {2812, 10318},
    HOW = {24275, 24274, 24239},
    HOWL = {5484, 17928},
    HURRICANE = {16914, 17401, 17402},
    ICE_ARMOR = {7302, 7320, 10219, 10220},
    ICE_BARRIER = {13031, 13032, 13033},
    IMMOLATE = {348, 707, 1094, 2941, 11665, 11667, 11668},
    INNER_FIRE = {588, 7128, 602, 1006, 10951, 10952},
    INSECT_SWARM = {24974, 24975, 24976, 24977},
    INTIM_SHOUT = {5246},
    JUDGEMENT = {20271},
    KICK = {1766, 1767, 1768, 1769},
    KIDNEY = {408, 8643},
    LESSER_HEAL = {2052, 2053},
    LHW = {8004, 8008, 8010, 10466, 10467, 10468},
    LIFE_TAP = {1454, 1455, 1456, 11687, 11688, 11689},
    LIGHTNING_BOLT = {529, 548, 915, 943, 6041, 10391, 10392, 15207, 15208},
    LIGHTNING_SHIELD = {324, 325, 905, 945, 8134, 10431, 10432},
    LOH = {633, 2800, 10310},
    MAGE_ARMOR = {6117, 22782, 22783},
    MAGMA = {8190, 10585, 10586, 10587},
    MANA_SHIELD = {1463, 8494, 8495, 10191, 10192, 10193},
    MARK = {1130, 14323, 14324, 14325},
    MAUL = {6808, 6809, 8972, 9745, 9880, 9881},
    MEND_PET = {136, 3111, 3661, 3662, 13542, 13543, 13544},
    MIND_BLAST = {8092, 8102, 8103, 8104, 8105, 8106, 10945, 10946, 10947},
    MIND_FLAY = {17311, 17312, 17313, 17314, 18807},
    MONGOOSE = {1495, 14269, 14270, 14271},
    MOONFIRE = {8921, 8924, 8925, 8926, 8927, 8928, 8929, 9833, 9834, 9835},
    MORTAL_STRIKE = {21551, 21552, 21553},
    MOTW = {1126, 5232, 6756, 5234, 8907, 9884, 9885},
    MULTI = {2643},
    OVERPOWER = {7384, 7887, 11584, 11585},
    PSYCHIC_SCREAM = {8122, 8124, 10888, 10890},
    PUMMEL = {6552, 6554},
    PURGE = {370, 8012},
    PURIFY = {1152},
    PW_FORT = {1243, 1244, 1245, 2791, 10937, 10938},
    PW_SHIELD = {17, 592, 600, 3747, 6065, 6066, 10898, 10899, 10900, 10901},
    PYROBLAST = {12505, 12522, 12523, 12524, 12525, 12526, 18809},
    RAIN_OF_FIRE = {5740, 6219, 11677, 11678},
    RAKE = {1822, 1823, 1824, 9904},
    RAPID_FIRE = {3045},
    RAPTOR = {14260, 14261, 14262, 14263, 14264, 14265, 14266},
    REGROWTH = {8936, 8938, 8939, 8940, 8941, 9750, 9856, 9857, 9858},
    REJUV = {774, 1058, 1430, 2090, 2091, 3627, 8910, 9839, 9840, 9841},
    REMOVE_CURSE = {2782},
    REMOVE_LESSER_CURSE = {475},
    REND = {772, 6546, 6547, 6548, 11572, 11573, 11574},
    RENEW = {139, 6074, 6075, 6076, 6077, 6078, 10927, 10928, 10929},
    RET_AURA = {7294, 10298, 10299, 10300, 10301},
    REVENGE = {6572, 6574, 7379, 11600, 11601},
    RIGHTEOUS_FURY = {25780},
    RIP = {9492, 9493, 9752, 9894, 9896},
    ROCKBITER = {8017, 8018, 8019, 10399, 16314, 16315, 16316},
    SCORCH = {2948, 8444, 8445, 8446, 10205, 10206, 10207},
    SEAL_FURY = {1311649, 1311656, 20163, 20419, 20421, 20422, 20423},
    SEARING = {6363, 6364, 6365, 10437, 10438},
    SERPENT = {1978, 13549, 13550, 13551, 13552, 13553, 13554, 13555},
    SHADOWBURN = {18867, 18868, 18869, 18870, 18871},
    SHADOW_BOLT = {695, 705, 1088, 1106, 7641, 11659, 11660, 11661},
    SHIELD_BASH = {72, 1671, 1672},
    SHIELD_BLOCK = {2565},
    SHIELD_SLAM = {23923, 23924, 23925},
    SHIELD_WALL = {871},
    SHRED = {5221, 6800, 8992, 9829, 9830},
    SINISTER = {1757, 1758, 1759, 1760, 8621, 11293, 11294},
    SMITE = {591, 598, 984, 1004, 6060, 10933, 10934},
    SND = {5171, 6774},
    SOC = {20915, 20918, 20919, 20920},
    SOL = {20165, 20347, 20348, 20349},
    SOR = {20287, 20288, 20289, 20290, 20291, 20292, 20293},
    SOTC = {21082, 20162, 20305, 20306, 20307, 20308},
    SOW = {20166, 20356, 20357},
    STARFIRE = {2912, 8949, 8950, 8951, 9875, 9876},
    SUNDER = {7405, 8380, 11596, 11597},
    SWIPE = {779, 780, 769, 9754, 9908},
    SWP = {589, 594, 970, 992, 2767, 10892, 10893, 10894},
    THORNS = {467, 782, 1075, 8914, 9756, 9910},
    THUNDER_CLAP = {6343, 8198, 8204, 8205, 11580, 11581},
    TURN_UNDEAD = {2878, 5627, 10326},
    VANISH = {1856, 1857},
    VOLLEY = {1510, 14294, 14295},
    WHIRLWIND = {1680},
    WINDFURY = {8232, 8235, 10486, 16362},
    WING_CLIP = {2974, 14267, 14268},
    WRATH = {5177, 5178, 5179, 5180, 6780, 8905, 9912},
}

local N, ICON = {}, {}   -- N[key] = nome localizado, ICON[key] = textura
local known = {}         -- known[nomeLocalizado] = true
local RANKID = {}        -- RANKID[key] = Spell ID do rank que o jogador aprendeu

-- Pelo nome, o jogo devolve o maior rank aprendido (para consultar a aura certa)
local function ResolveRankIDs()
    wipe(RANKID)
    if not (C_Spell and C_Spell.GetSpellInfo) then return end
    for key, name in pairs(N) do
        if known[name] then
            local ok, info = pcall(C_Spell.GetSpellInfo, name)
            local sid = ok and info and Pub(info.spellID)
            if type(sid) == "number" then RANKID[key] = sid end
        end
    end
end

-- Habilidades que estao nas SUAS barras (por nome localizado). So faz sentido
-- sugerir o que voce consegue apertar; com as barras vazias o filtro e ignorado.
local barNames, barCount = {}, 0
local function OnBar(name)
    return not DB or not DB.barOnly or barCount == 0 or barNames[name] == true
end

-- Resolve o nome localizado de cada habilidade pelo ID principal e, se o cliente
-- nao o conhecer, pelos IDs alternativos (ranks do treinador do Forever).
local function ResolveNames()
    for key, id in pairs(ID) do
        local name, icon = SpellInfo(id)
        if not name and ALT[key] then
            for _, alt in ipairs(ALT[key]) do
                name, icon = SpellInfo(alt)
                if name then break end
            end
        end
        if name then N[key], ICON[key] = name, icon end
    end
end

local function AddKnown(name) if name then known[name] = true end end

-- Varre o Spellbook: so sugere o que o jogador JA aprendeu no nivel atual.
local function ScanSpellbook()
    wipe(known)
    if C_SpellBook and C_SpellBook.GetNumSpellBookSkillLines and Enum and Enum.SpellBookSpellBank then
        local bank = Enum.SpellBookSpellBank.Player
        for t = 1, C_SpellBook.GetNumSpellBookSkillLines() do
            local line = C_SpellBook.GetSpellBookSkillLineInfo(t)
            if line then
                for i = line.itemIndexOffset + 1, line.itemIndexOffset + line.numSpellBookItems do
                    AddKnown(C_SpellBook.GetSpellBookItemName(i, bank))
                end
            end
        end
    else
        local book = BOOKTYPE_SPELL or "spell"
        for t = 1, GetNumSpellTabs() do
            local _, _, offset, num = GetSpellTabInfo(t)
            for i = offset + 1, offset + num do
                AddKnown(GetSpellBookItemName(i, book))
            end
        end
    end
end

local function Known(key)
    local name = N[key]
    return name ~= nil and known[name] == true
end

-- Pronto para uso: aprendido, usavel (mana/recurso/reativo/postura), fora de
-- recarga (ignora o GCD) e no alcance da unidade, quando aplicavel.
-- Habilidades reativas (so ficam disponiveis apos esquiva/aparo/alvo < 20%).
-- Sem confirmacao de "usavel" elas nunca sao sugeridas pela regra comum; o
-- brilho de proc da Blizzard continua sugerindo-as quando acendem.
local REACTIVE = { EXECUTE = true, OVERPOWER = true, REVENGE = true, RIPOSTE = true,
                   MONGOOSE = true, HOW = true, VICTORY_RUSH = true, COUNTERATTACK = true, CONFLAGRATE = true }

local function Ready(key, unit)
    local name = N[key]
    if not name or not known[name] then return false end
    if not OnBar(name) then return false end
    local usable = SpellUsable(name)
    if usable == false then return false end
    if usable == nil and REACTIVE[key] then return false end
    local start, duration, active, onGCD = SpellCooldown(name)
    if active == true and onGCD ~= true then return false end  -- em recarga (limpo)
    if start > 0 and duration > 1.6 and (start + duration - GetTime()) > 0.25 then return false end
    if unit and unit ~= "player" and UnitExists(unit) and SpellInRange(name, unit) == false then
        return false
    end
    return true
end

-- So a recarga (sem exigir "usavel"/alcance): usada pelos alertas de cast.
local function OffCooldown(key)
    local name = N[key]
    if not name or not known[name] then return false end
    if not OnBar(name) then return false end
    local start, duration, active, onGCD = SpellCooldown(name)
    if active == true and onGCD ~= true then return false end
    if start > 0 and duration > 1.6 and (start + duration - GetTime()) > 0.25 then return false end
    return true
end

---------------------------------------------------------------------------
-- 4. LEITURA DE ATALHOS (KEYBINDS)
---------------------------------------------------------------------------
-- Le o mapa de bindings do jogo. Nao depende de nenhum addon de barras:
--  a) binding direto do feitico ("SPELL Nome")
--  b) slot de acao onde o feitico esta -> comando de binding da Blizzard
--  c) comandos usados por ElvUI / Bartender4 / Dominos para o mesmo slot
local keyCache = {}

local SLOT_COMMANDS = {
    -- { primeiroSlot, ultimoSlot, comando Blizzard, n. da barra ElvUI }
    { 1, 12, "ACTIONBUTTON", 1 },
    { 13, 24, nil, 2 },
    { 25, 36, "MULTIACTIONBAR3BUTTON", 3 },
    { 37, 48, "MULTIACTIONBAR4BUTTON", 4 },
    { 49, 60, "MULTIACTIONBAR2BUTTON", 5 },
    { 61, 72, "MULTIACTIONBAR1BUTTON", 6 },
    { 73, 120, "ACTIONBUTTON", nil },     -- barras de postura/forma/furtividade
}

local function FirstKey(...)
    for i = 1, select("#", ...) do
        local cmd = select(i, ...)
        if cmd then
            local key = GetBindingKey(cmd)
            if key then return key end
        end
    end
end

local function KeyForSlot(slot)
    for _, r in ipairs(SLOT_COMMANDS) do
        if slot >= r[1] and slot <= r[2] then
            local btn = (slot - r[1]) % 12 + 1
            local elvBar = r[4]
            return FirstKey(
                r[3] and (r[3] .. btn),
                elvBar and ("ELVUIBAR" .. elvBar .. "BUTTON" .. btn),
                elvBar and ("CLICK ElvUI_Bar" .. elvBar .. "Button" .. btn .. ":LeftButton"),
                "CLICK BT4Button" .. slot .. ":Keybind",
                "CLICK BT4Button" .. slot .. ":LeftButton",
                "CLICK DominosActionButton" .. slot .. ":HOTKEY",
                "CLICK DominosActionButton" .. slot .. ":LeftButton")
        end
    end
end

-- Formata "SHIFT-2" -> "Shift+2", "CTRL-F1" -> "Ctrl+F1"
local function FormatKey(key)
    if not key then return "" end
    key = key:gsub("SHIFT%-", "Shift+"):gsub("CTRL%-", "Ctrl+"):gsub("ALT%-", "Alt+")
             :gsub("META%-", "Cmd+"):gsub("NUMPAD", "Num"):gsub("BUTTON", "Mouse")
             :gsub("MOUSEWHEELUP", "RodaCima"):gsub("MOUSEWHEELDOWN", "RodaBaixo")
    return key
end

local function SlotSpellName(slot)
    local actionType, id = PubAll(GetActionInfo(slot))
    if actionType == "spell" and id then
        return (SpellInfo(id))
    elseif actionType == "macro" and id then
        local s = Pub(GetMacroSpell(id))
        if type(s) == "number" then return (SpellInfo(s)) end
        return s
    end
end

local function RebuildKeyCache()
    wipe(keyCache)
    wipe(barNames)
    barCount = 0
    for slot = 1, 120 do
        if Is(HasAction(slot)) then
            local name = SlotSpellName(slot)
            if name then
                if not barNames[name] then barNames[name] = true; barCount = barCount + 1 end
                if not keyCache[name] then
                    local key = KeyForSlot(slot)
                    if key then keyCache[name] = key end
                end
            end
        end
    end
end

local function GetKeybind(key)
    local name = N[key]
    if not name then return "" end
    local direct = GetBindingKey("SPELL " .. name)
    return FormatKey(direct or keyCache[name])
end

---------------------------------------------------------------------------
-- 5. CONTEXTO DE COMBATE
---------------------------------------------------------------------------
local c = {}                     -- contexto reaproveitado (sem lixo por frame)
local playerBuffs, playerDebuffs, targetMine, targetAny = {}, {}, {}, {}
local groupUnits = {}
local dispelScan = {}            -- [tipo] = unidade com debuff daquele tipo
local lowest = { unit = nil, pct = 100 }
local injuredCount = 0
local lastGroupScan = 0

-- Auras secretas: quando o jogo esconde as auras, "buff ausente" nao pode ser
-- concluido. auraSecret[unit] = true faz as regras de "falta X" ficarem mudas.
local auraSecret = {}
local auraDur = {}                   -- [nome] = duracao total observada (ex.: duracao real do selo)

-- CONTEXTO DO PERSONAGEM (equipamento) e do ALVO, lidos fora de combate, quando os
-- valores ainda sao legiveis, e guardados. Em combate o jogo os esconde.
local gear = { shield = false, twoHand = false, speed = 2.0 }
local tcache = {}                    -- tipo/classificacao do alvo atual (limpo ao trocar de alvo)

local function RefreshGear()
    local function itemInfo(slot)
        local id = GetInventoryItemID("player", slot)
        if type(id) ~= "number" then return nil end
        local f = (C_Item and C_Item.GetItemInfoInstant) or GetItemInfoInstant
        if not f then return nil end
        local ok, _, _, _, loc, _, classID, subID = pcall(f, id)
        if not ok then return nil end
        return loc, classID, subID
    end
    local mainLoc, mainClass, mainSub = itemInfo(16)
    gear.twoHand = mainLoc == "INVTYPE_2HWEAPON"
    gear.dagger = mainClass == 2 and mainSub == 15     -- adaga: Furtividade/Esfaquear funcionam melhor
    gear.shield = (itemInfo(17)) == "INVTYPE_SHIELD"
    local sp = UnitAttackSpeed and Pub((UnitAttackSpeed("player")))
    if type(sp) == "number" and sp > 0 then gear.speed = sp end
end

local function CollectAuras(unit, filter, store, mineOnly, tag)
    wipe(store)
    if not UnitExists(unit) then return end
    local now = GetTime()
    local readable = ForEachAura(unit, filter, function(name, _, source, expiration, _, duration)
        if not mineOnly or source == "player" or source == "pet" then
            local remain = (expiration and expiration > 0) and (expiration - now) or 999
            if not store[name] or store[name] < remain then store[name] = remain end
            if duration and duration > 0 then auraDur[name] = duration end
        end
    end)
    if tag then auraSecret[tag] = not readable end
end

local function RefreshGroupUnits()
    wipe(groupUnits)
    groupUnits[1] = "player"
    if Is(IsInRaid()) then
        for i = 1, Pub(GetNumGroupMembers()) or 0 do
            local u = "raid" .. i
            if not UnitIsUnit(u, "player") then groupUnits[#groupUnits + 1] = u end
        end
    elseif Is(IsInGroup()) then
        for i = 1, Pub(GetNumSubgroupMembers()) or 0 do groupUnits[#groupUnits + 1] = "party" .. i end
    end
end

-- Varre o grupo (4x por segundo): debuffs dissipaveis e aliado mais ferido.
local function ScanGroup()
    RefreshGroupUnits()
    wipe(dispelScan)
    lowest.unit, lowest.pct = nil, 100
    injuredCount = 0
    for _, u in ipairs(groupUnits) do
        if UnitExists(u) and not UnitIsDeadOrGhost(u) and Is(UnitIsConnected(u)) and Is(UnitIsVisible(u)) then
            local pct = UnitPct(u)  -- nil = vida secreta: aliado ignorado para cura
            if pct and pct < 80 then injuredCount = injuredCount + 1 end
            if pct and pct < lowest.pct then lowest.unit, lowest.pct = u, pct end
            ForEachAura(u, "HARMFUL", function(name, dtype)
                if dtype and dtype ~= "" and not dispelScan[dtype] then
                    dispelScan[dtype] = { unit = u, name = name }
                end
            end)
        end
    end
end

local function UnitInMyGroup(unit)
    if not UnitExists(unit) then return false end
    return UnitIsUnit(unit, "player") or Is(UnitInParty(unit)) or Pub(UnitInRaid(unit)) ~= nil
end

-- Cast do alvo. Campos secretos viram "desconhecido": sem duracao assume 1s,
-- sem a flag de interrupcao assume interrompivel (o jogo recusa se nao for).
local function ReadTargetCast()
    if not c.hostile then return nil end
    -- issecret antes de qualquer comparacao: comparar um valor secreto gera erro
    local name, _, _, _, endMS, _, _, notInt = UnitCastingInfo("target")
    if not issecret(name) and name == nil then
        name, _, _, _, endMS, _, notInt = UnitChannelInfo("target")
    end
    if not issecret(name) and name == nil then return nil end
    local cast = c.castData
    cast.name = Pub(name) or "feitico do inimigo"
    endMS = Pub(endMS)
    cast.remaining = endMS and (endMS / 1000 - GetTime()) or 1
    cast.unknownInt = issecret(notInt)   -- se secreto, o painel de cast decide so pela transparencia
    notInt = Pub(notInt)
    cast.interruptible = not notInt
    cast.onGroup = UnitInMyGroup("targettarget")
    cast.onMe = UnitExists("targettarget") and UnitIsUnit("targettarget", "player")
    return cast
end

-- Habilidades corpo a corpo usadas como "sonda" de alcance (funcionam em qualquer unidade)
local MELEE_PROBES = { "SINISTER", "HEROIC_STRIKE", "CLAW", "MAUL", "RAPTOR", "STORMSTRIKE", "JUDGEMENT" }

local function Near(unit)
    for _, key in ipairs(MELEE_PROBES) do
        if Known(key) then
            local r = SpellInRange(N[key], unit)
            if r ~= nil then return r end
        end
    end
    -- CheckInteractDistance e restrito em combate: so e usado fora dele.
    if not InCombatLockdown() then
        local ok, r = pcall(CheckInteractDistance, unit, 3)
        if ok and r ~= nil and not issecret(r) then return r and true or false end
    end
    return UnitExists(unit .. "target") and UnitIsUnit(unit .. "target", "player")
end

-- Conta inimigos em combate pelas placas de nome (o log de combate e proibido
-- para addons no Forever).
local function CountEnemies()
    local total, near = 0, 0
    for i = 1, 40 do
        local u = "nameplate" .. i
        if UnitExists(u) and UnitCanAttack("player", u) and not UnitIsDead(u) and UnitAffectingCombat(u) then
            total = total + 1
            if Near(u) then near = near + 1 end
        end
    end
    return total, near
end

local CREATURE_UNDEAD = { ["Undead"] = true, ["Morto-vivo"] = true, ["Morta-viva"] = true }
local CREATURE_DEMON  = { ["Demon"] = true, ["Demônio"] = true, ["Demonio"] = true }
local CREATURE_HUMANOID = { ["Humanoid"] = true, ["Humanoide"] = true }

-- SELO ATIVO. Fora de combate vem das auras (exato). Em combate o jogo esconde as
-- auras, entao vale o estado rastreado: o selo que VOCE lancou + a duracao real
-- observada (sealDur). No Forever o Julgamento nao consome mais o selo.
local SEAL_KEYS = { "SEAL_FURY", "SOC", "SOR", "SOTC", "SOJ", "SOL", "SOW" }
local sealState = { key = nil, expires = 0 }
local lastCast = { key = nil, t = 0, at = {}, self = {}, cp = 0,
    -- pontos de combo: cada gerador soma, cada finalizador zera (GetComboPoints fica secreto em combate)
    cpb = { SINISTER = 1, BACKSTAB = 1, AMBUSH = 1, GARROTE = 1, CHEAP_SHOT = 1, GOUGE = 1, MUTILATE = 2,
            CLAW = 1, RAKE = 1, SHRED = 1, POUNCE = 1, RAVAGE = 1 },
    cpf = { EVISCERATE = 1, SND = 1, RUPTURE = 1, KIDNEY = 1, RIP = 1, BITE = 1 },
    -- duracao dos DoTs (s): as sequencias so mandam reaplicar se o DoT ja caiu
    dur = { CORRUPTION = 14, IMMOLATE = 12, SERPENT = 12, MOONFIRE = 10, INSECT_SWARM = 11, RAKE = 8, SWP = 16,
            FLAME_SHOCK = 10, REND = 12, RIP = 9, COA = 22, SIPHON_LIFE = 26 } }   -- ultima skill sua e o instante de cada uma (DoTs sem auras)
local sealDur = 30

local function UpdateSealFromAuras()
    if auraSecret.player then return end
    local now, found = GetTime(), nil
    for _, k in ipairs(SEAL_KEYS) do
        local n = N[k]
        if n and playerBuffs[n] then
            found = k
            sealState.expires = now + playerBuffs[n]
            if auraDur[n] then sealDur = auraDur[n] end
            break
        end
    end
    sealState.key = found
    if not found then sealState.expires = 0 end
end

local function BuildContext()
    c.now = GetTime()
    c.inCombat = UnitAffectingCombat("player")
    -- Valores desconhecidos (secretos) recebem um padrao "neutro" que nao
    -- dispara regras: vida 100%, recurso 0, mana 100%.
    c.hp = UnitPct("player") or 100
    c.hpKnown = UnitPct("player") ~= nil
    local maxPow, pow = Pub(UnitPowerMax("player")), Pub(UnitPower("player"))
    c.power = pow or 0
    c.powerKnown = pow ~= nil          -- false em combate no Forever: as regras assumem que ha recurso
    c.powerPct = (pow and maxPow and maxPow > 0) and (pow / maxPow * 100) or 0
    local maxMana, mana = Pub(UnitPowerMax("player", 0)), Pub(UnitPower("player", 0))
    c.manaPct = (mana and maxMana and maxMana > 0) and (mana / maxMana * 100) or 100
    c.cp = Pub(GetComboPoints("player", "target")) or lastCast.cp or 0
    c.grouped = Is(IsInGroup())
    c.stealth = Is(IsStealthed and IsStealthed())

    c.target = UnitExists("target")
    -- Se o jogo esconder se o alvo e atacavel, em combate assumimos que o alvo
    -- e o inimigo (o jogo recusa a habilidade se nao for).
    local atk = _G.UnitCanAttack("player", "target")
    c.hostileSecret = c.target and issecret(atk)
    if c.hostileSecret then c.hostile = c.inCombat and not UnitIsDead("target")
    else c.hostile = c.target and atk and not UnitIsDead("target") end
    c.thp = c.target and UnitPct("target") or 100
    -- tipo/classificacao do alvo: lidos quando legiveis (ao selecionar o alvo, fora de
    -- combate) e guardados em tcache; em combate o jogo os esconde.
    if c.target then
        local cls = Pub(UnitClassification("target"))
        if cls then tcache.elite = (cls == "elite" or cls == "worldboss" or cls == "rareelite") end
        if Pub(UnitLevel("target")) == -1 then tcache.elite = true end
        local ct = Pub(UnitCreatureType("target"))
        if ct then tcache.ctype = ct end
    end
    c.elite = c.target and tcache.elite or false
    c.melee = c.hostile and Near("target")
    local ctype = c.target and tcache.ctype or nil
    c.ctype = ctype
    c.undeadOrDemon = ctype and (CREATURE_UNDEAD[ctype] or CREATURE_DEMON[ctype]) or false
    c.humanoid = ctype and CREATURE_HUMANOID[ctype] or false
    c.threat = (c.hostile and UnitThreatSituation and Pub(UnitThreatSituation("player", "target"))) or 0
    c.targetOnAlly = c.hostile and UnitExists("targettarget") and not UnitIsUnit("targettarget", "player")
                     and UnitInMyGroup("targettarget")

    CollectAuras("player", "HELPFUL", playerBuffs, false, "player")
    CollectAuras("player", "HARMFUL", playerDebuffs)
    CollectAuras("target", "HARMFUL", targetMine, true, "target")
    CollectAuras("target", "HARMFUL", targetAny)
    UpdateSealFromAuras()

    c.castData = c.castData or {}
    -- isolados com pcall: se o jogo bloquear um deles, o resto (procs) segue funcionando
    local okCast, cast = pcall(ReadTargetCast)
    c.cast = okCast and cast or nil
    local okEn, en, near = pcall(CountEnemies)
    c.enemies, c.near = okEn and en or 0, okEn and near or 0
    c.aoe = c.enemies >= DB.aoe
    c.meleeAoe = c.near >= DB.aoe

    if c.inCombat and not c.prevCombat then c.combatStart = c.now end
    if c.inCombat ~= c.prevCombat then lastGroupScan = 0 end -- rescan na entrada/saida de combate
    c.prevCombat = c.inCombat
    if c.now - lastGroupScan > GROUP_SCAN_INTERVAL then
        lastGroupScan = c.now
        ScanGroup()
    end
    c.dispel = dispelScan
    c.lowest, c.lowestPct, c.injured = lowest.unit, lowest.pct, injuredCount
    c.petHp = UnitExists("pet") and UnitPct("pet") or 100
end

-- Ajudantes de leitura de estado (por chave do ID).
-- Buff/OnTarget = "tenho certeza que ESTA ativo".
-- Lacks/NotOnTarget = "tenho certeza que NAO esta" (falso se as auras estao secretas).
-- Com as auras bloqueadas, os buffs do jogador ainda podem ser consultados um a
-- um pelo Spell ID do rank que o jogador tem (quando o jogo libera aquele feitico).
local function Buff(key)
    if not N[key] then return false end
    if auraSecret.player then return PlayerAuraByID(RANKID[key] or ID[key]) == true end
    return playerBuffs[N[key]]
end
local function Debuff(key) return N[key] and playerDebuffs[N[key]] end
local function OnTarget(key) return N[key] and targetMine[N[key]] end         -- debuff MEU no alvo
local function OnTargetAny(key) return N[key] and targetAny[N[key]] end       -- debuff de qualquer um
local function Lacks(key)
    if not N[key] then return true end   -- feitico inexistente neste cliente: nao pode estar ativo
    if auraSecret.player then return PlayerAuraByID(RANKID[key] or ID[key]) == false end
    return not playerBuffs[N[key]]
end
local function NotOnTarget(key) return not auraSecret.target and not OnTarget(key) end
local function NotOnTargetAny(key) return not auraSecret.target and not OnTargetAny(key) end
-- DoT/debuff meu no alvo ausente? Com auras legiveis: exato. Em combate (auras secretas): pelo
-- tempo desde que EU o lancei (dur = duracao em segundos). Zera ao trocar de alvo.
local function DotDown(key, dur)
    if not N[key] then return false end
    if not auraSecret.target then return not OnTarget(key) end
    local t = lastCast.at[key]
    return t == nil or (GetTime() - t) > dur
end
-- Buff meu em mim ausente? Auras legiveis: exato. Auras secretas: pela consulta por Spell ID
-- e, se ela tambem for bloqueada, pelo tempo desde que EU o lancei (dur em segundos).
local function BuffDown(key, dur)
    if not N[key] then return false end
    if not auraSecret.player then return not playerBuffs[N[key]] end
    local r = PlayerAuraByID(RANKID[key] or ID[key])
    if r ~= nil then return r == false end
    local t = lastCast.self[key]
    return t == nil or (GetTime() - t) > dur
end
local function AnyOnTarget(...) for i = 1, select("#", ...) do if OnTarget((select(i, ...))) then return true end end end

-- true = tem, false = nao tem, nil = desconhecido (auras secretas)
local function UnitHasAura(unit, key, filter)
    local name, found = N[key], false
    if not name then return false end
    local readable = ForEachAura(unit, filter, function(n) if n == name then found = true; return true end end)
    if not readable then
        if unit == "player" or UnitIsUnit(unit, "player") then return PlayerAuraByID(ID[key]) end
        return nil
    end
    return found
end
local function UnitLacksAura(unit, key, filter) return UnitHasAura(unit, key, filter) == false end

-- Forma/postura ativa pela barra de formas (nao depende de auras, que podem
-- estar secretas). Retorna o nome localizado da forma ou nil.
local function ActiveFormName()
    local n = Pub(GetNumShapeshiftForms and GetNumShapeshiftForms()) or 0
    for i = 1, n do
        local _, active, _, sid = GetShapeshiftFormInfo(i)
        if Is(active) then
            sid = Pub(sid)
            return sid and (SpellInfo(sid)) or nil
        end
    end
end
local function InForm(...)
    local form = ActiveFormName()
    if not form then return false end
    for i = 1, select("#", ...) do if N[(select(i, ...))] == form then return true end end
    return false
end

local function TargetHasMagicBuff()
    local found = false
    ForEachAura("target", "HELPFUL", function(_, dtype) if dtype == "Magic" then found = true; return true end end)
    return found
end

---------------------------------------------------------------------------
-- 6. CONSTRUTORES DE REGRAS
---------------------------------------------------------------------------
-- Cada regra: { pick = {chaves...}, cat = categoria, unit = unidade|func,
--               when = func(c, unit) -> bool, msg = texto|func }
-- A primeira regra (na ordem) cuja condicao for verdadeira E cuja habilidade
-- estiver aprendida e pronta e exibida.

-- pick pode ser: "CHAVE", { "CHAVE1", "CHAVE2" } ou uma funcao(c) que devolve a lista
-- (escolha dinamica, ex.: qual selo usar conforme o alvo e a arma).
local function R(cat, pick, when, msg, unit)
    local pickFn
    if type(pick) == "string" then pick = { pick }
    elseif type(pick) == "function" then pickFn, pick = pick, {} end
    return { cat = cat, pick = pick, pickFn = pickFn, when = when, msg = msg, unit = unit }
end

local function UnitLabel(unit)
    if not unit or unit == "player" then return "voce" end
    return Pub(UnitName(unit)) or "aliado"
end

-- Interrupcao: alvo hostil castando algo interrompivel
local function Interrupt(pick)
    return R("INTERRUPT", pick, function(c)
        return c.cast and c.cast.interruptible and not c.cast.unknownInt and c.cast.remaining > 0.15
    end, function(c) return "Interrompa: " .. c.cast.name end, "target")
end

-- Dissipar: tipos = { "Poison", "Disease", "Curse", "Magic" }
local function Dispel(pick, types)
    local rule = R("DISPEL", pick, nil, nil, nil)
    rule.unit = function(c)
        for _, t in ipairs(types) do
            local d = c.dispel[t]
            if d then rule._d = d; return d.unit end
        end
    end
    rule.when = function(c, unit) return unit ~= nil end
    rule.msg = function() return "Remova " .. rule._d.name .. " de " .. UnitLabel(rule._d.unit) end
    return rule
end

-- Buff proprio ausente. "family" = buffs equivalentes (qualquer um satisfaz)
local function SelfBuff(pick, family, inCombatToo)
    family = family or (type(pick) == "table" and pick or { pick })
    return R("BUFF", pick, function(c)
        if c.inCombat and not inCombatToo then return false end
        -- so sugere com certeza de que NENHUM buff da familia esta ativo
        for _, k in ipairs(family) do if not Lacks(k) then return false end end
        return true
    end, "Buff ausente", "player")
end

-- Cura no aliado mais ferido (inclui voce)
local function HealLowest(pick, threshold, extra)
    return R("HEAL", pick, function(c, unit)
        return unit and c.lowestPct < threshold and (not extra or extra(c, unit))
    end, function(c) return string.format("Cure %s (%d%%)", UnitLabel(c.lowest), c.lowestPct) end,
    function(c) return c.lowest end)
end

local function Emergency(pick, hpBelow, extra, msg)
    return R("EMERGENCY", pick, function(c)
        return c.inCombat and c.hp < hpBelow and (not extra or extra(c))
    end, msg or "Vida baixa! Use agora")
end

-- Cast pesado nao-interrompivel vindo em voce -> defensiva
local function BigCastDefense(pick, msg)
    return R("DEFENSIVE", pick, function(c)
        return c.cast and c.cast.onMe and (not c.cast.interruptible or c.elite) and c.cast.remaining < 2
    end, msg or function(c) return "Mitigue: " .. c.cast.name end)
end

local function Taunt(pick, isTank)
    return R("TAUNT", pick, function(c) return c.grouped and isTank(c) and c.targetOnAlly end,
        function() return "Alvo atacando " .. (Pub(UnitName("targettarget")) or "aliado") .. "! Provoque" end, "target")
end

-- Habilidade ofensiva sobre o alvo hostil
local function Hit(cat, pick, when, msg)
    return R(cat, pick, function(c, u) return c.hostile and (not when or when(c, u)) end, msg, "target")
end

---------------------------------------------------------------------------
-- 7. REGRAS POR CLASSE
---------------------------------------------------------------------------
local CLASS_RULES = {}

CLASS_RULES.WARRIOR = function()
    local function tank() return Pub(GetShapeshiftForm()) == 2 end -- Postura Defensiva
    return {
        Emergency("SHIELD_WALL", 25),
        Emergency("LAST_STAND", 30),
        Emergency("INTIM_SHOUT", 35, function(c) return c.near >= 2 end, "Cercado! Medo em area"),
        Interrupt({ "PUMMEL", "SHIELD_BASH" }),
        BigCastDefense("SHIELD_BLOCK"),
        Taunt("TAUNT", tank),
        SelfBuff("BATTLE_SHOUT", nil, true),
        Hit("COMBO", "CHARGE", function(c) return not c.inCombat end, "Abertura: Investida"),
        Hit("COMBO", "VICTORY_RUSH", nil, "Vitoria Rapida: cura 10% da vida (ate 20s apos matar)"),
        R("COMBO", "BLOODRAGE", function(c) return c.inCombat and c.hp > 60 and (c.now - (c.combatStart or c.now)) < 8 end,
            "Inicio da luta: Ira Sangrenta (gera Raiva)", "player"),
        Hit("COMBO", "EXECUTE", nil, "Alvo < 20%: Executar!"),
        Hit("COMBO", "OVERPOWER", nil, "Alvo esquivou: Sobrepujar!"),
        Hit("COMBO", "REVENGE", nil, "Bloqueio/Esquiva: Revanche!"),
        R("AOE", "SWEEPING", function(c) return c.inCombat and c.meleeAoe end, "Varios mobs: ative Golpes Amplos"),
        Hit("AOE", "WHIRLWIND", function(c) return c.near >= 2 end,
            function() return Buff("SWEEPING") and "COMBO Golpes Amplos -> Redemoinho" or "Varios mobs: Redemoinho" end),
        Hit("AOE", "THUNDER_CLAP", function(c) return c.meleeAoe and DotDown("THUNDER_CLAP", 18) end, "Area: Trovoada"),
        Hit("AOE", "DEMO_SHOUT", function(c) return c.meleeAoe and DotDown("DEMO_SHOUT", 25) end, "Area: Grito Desmoralizante"),
        Hit("AOE", "CLEAVE", function(c) return c.near >= 2 and (not c.powerKnown or c.power >= 40) end, "Raiva sobrando: Cutilada"),
        Hit("ROTATION", "SHIELD_SLAM", nil, "Golpe de Escudo"),
        Hit("ROTATION", { "BLOODTHIRST", "MORTAL_STRIKE" }, nil, "Golpe principal"),
        Hit("ROTATION", "SLAM", nil, "Golpe Poderoso (recarga 15s)"),
        R("ROTATION", "RECKLESSNESS", function(c) return c.hostile and c.inCombat and c.elite end, "Elite/chefe: Temeridade", "player"),
        Hit("ROTATION", "SUNDER", function(c) return tank() and DotDown("SUNDER", 25) end, "Gere ameaca: Fender Armadura"),
        Hit("ROTATION", "REND", function(c) return c.thp > 30 and DotDown("REND", 12) end, "Aplique Dilacerar"),
        Hit("ROTATION", "HEROIC_STRIKE", function(c) return not c.powerKnown or c.power >= 50 end, "Raiva alta: Golpe Heroico"),
    }
end

CLASS_RULES.ROGUE = function()
    return {
        Emergency("VANISH", 15, nil, "Quase morto: Sumir"),
        Emergency("EVASION", 50, function(c) return c.threat >= 2 or not c.grouped end, "Apanhando: Evasao"),
        Interrupt("KICK"),
        Interrupt("GOUGE"),
        Hit("INTERRUPT", "KIDNEY", function(c) return c.cast and not c.cast.unknownInt and c.cp >= 1 end, "Sem Chute: Golpe nos Rins"),
        R("AOE", "BLADE_FLURRY", function(c) return c.inCombat and c.near >= 2 end, "Varios mobs: Rajada de Laminas"),
        Hit("COMBO", function() return gear.dagger and { "AMBUSH", "CHEAP_SHOT", "GARROTE" } or { "CHEAP_SHOT", "GARROTE", "AMBUSH" } end,
            function(c) return c.stealth and not c.inCombat end, "Furtivo: abertura (Emboscada exige adaga)"),
        Hit("COMBO", "RIPOSTE", nil, "Aparou! Ripostar"),
        Hit("COMBO", "SND", function(c) return c.cp >= 2 and BuffDown("SND", 24) and c.thp > 25 end,
            "Pontos de combo: ative Picar"),
        Hit("COMBO", "RUPTURE", function(c) return c.cp >= 4 and c.elite and DotDown("RUPTURE", 12) end, "Elite: Ruptura (sangramento)"),
        Hit("COMBO", "EVISCERATE", function(c) return c.cp >= 5 or (c.cp >= 2 and c.thp < 15) end,
            function(c) return c.cp .. " pontos: Eviscerar!" end),
        R("ROTATION", "ADRENALINE", function(c) return c.inCombat and c.elite end, "Elite/chefe: Adrenalina"),
        Hit("ROTATION", function()
            local facingMe = UnitExists("targettarget") and UnitIsUnit("targettarget", "player")
            if gear.dagger and not facingMe then return { "BACKSTAB", "SINISTER" } end
            return { "SINISTER", "BACKSTAB" }
        end, nil, "Gere pontos: Esfaquear (por tras, adaga) / Golpe Sinistro"),
    }
end

CLASS_RULES.MAGE = function()
    local function filler()
        if Known("ARCANE_BLAST") then return { "ARCANE_BLAST", "FROSTBOLT", "FIREBALL" } end   -- especializacao Arcana
        if Known("PYROBLAST") or Known("COMBUSTION") or not Known("FROSTBOLT") then return { "FIREBALL", "FROSTBOLT" } end
        return { "FROSTBOLT", "FIREBALL" }
    end
    local fill = filler()
    return {
        Emergency("ICE_BLOCK", 20),
        R("EMERGENCY", "FROST_NOVA", function(c) return c.inCombat and c.melee and c.hp < 70 end,
            "Inimigo colado: Nova Congelante e afaste-se"),
        Interrupt("COUNTERSPELL"),
        Dispel("REMOVE_LESSER_CURSE", { "Curse" }),
        R("DEFENSIVE", "ICE_BARRIER", function(c) return c.inCombat and c.hp < 80 and Lacks("ICE_BARRIER") end, "Escudo: Barreira de Gelo"),
        R("DEFENSIVE", "MANA_SHIELD", function(c) return c.inCombat and c.hp < 40 and Lacks("MANA_SHIELD") end, "Vida baixa: Escudo de Mana"),
        R("COMBO", "EVOCATION", function(c) return c.inCombat and c.manaPct < 12 end, "Sem mana: Evocacao"),
        Hit("COMBO", "PYROBLAST", function() return Buff("PRESENCE_OF_MIND") end, "COMBO Presenca da Mente -> Piroblasto"),
        R("COMBO", "ARCANE_EXPLOSION", function(c) return Buff("MAGE_CLEARCAST") and c.meleeAoe end, "COMBO Clarividencia -> Explosao Arcana gratis"),
        Hit("COMBO", fill, function() return Buff("MAGE_CLEARCAST") end, "COMBO Clarividencia -> feitico forte gratis"),
        R("COMBO", "PRESENCE_OF_MIND", function(c) return c.hostile and c.inCombat end, "Prepare: Presenca da Mente (depois Piroblasto)"),
        R("COMBO", { "ARCANE_POWER", "COMBUSTION" }, function(c) return c.hostile and c.inCombat and c.elite end, "Elite/chefe: ative cooldown de dano"),
        R("AOE", "FROST_NOVA", function(c) return c.inCombat and c.meleeAoe and DotDown("FROST_NOVA", 8) end, "FARM: Nova Congelante -> Explosao Arcana"),
        R("AOE", "BLAST_WAVE", function(c) return c.meleeAoe and c.hostile end, "Mobs colados: Onda Explosiva (dano + lentidao)"),
        R("AOE", "CONE_OF_COLD", function(c) return c.meleeAoe and c.hostile end, "Area: Cone de Gelo"),
        R("AOE", "ARCANE_EXPLOSION", function(c) return c.meleeAoe end, "Mobs agrupados: Explosao Arcana"),
        R("AOE", "BLIZZARD", function(c) return c.enemies >= DB.aoe + 1 and not c.meleeAoe end, "Mobs a distancia: Nevasca"),
        Hit("ROTATION", "PYROBLAST", function(c) return not c.inCombat end, "Abertura: Piroblasto"),
        Hit("ROTATION", "FIRE_BLAST", function(c) return c.thp < 30 or c.melee end, "Instantaneo: Impacto de Fogo"),
        Hit("ROTATION", fill, nil, "Dano principal"),
        SelfBuff("ARCANE_INTELLECT"),
        SelfBuff({ "MAGE_ARMOR", "ICE_ARMOR", "FROST_ARMOR" }),
    }
end

CLASS_RULES.PRIEST = function()
    local function canShield(c, u) return UnitLacksAura(u, "WEAKENED_SOUL", "HARMFUL") and UnitLacksAura(u, "PW_SHIELD", "HELPFUL") end
    return {
        Emergency("DESPERATE_PRAYER", 30),
        R("EMERGENCY", "PW_SHIELD", function(c) return c.inCombat and c.hp < 50 and canShield(c, "player") end, "Vida baixa: Escudo em voce", "player"),
        Emergency("PSYCHIC_SCREAM", 40, function(c) return c.near >= 1 end, "Cercado: Grito Psiquico"),
        R("DEFENSIVE", "FADE", function(c) return c.grouped and c.threat >= 2 end, "Voce puxou aggro: Desvanecer"),
        Interrupt("SILENCE"),
        Dispel("DISPEL_MAGIC", { "Magic" }),
        Dispel({ "ABOLISH_DISEASE", "CURE_DISEASE_P" }, { "Disease" }),
        HealLowest("PW_SHIELD", 40, canShield),
        HealLowest({ "FLASH_HEAL", "HEAL", "LESSER_HEAL" }, 40),
        R("COMBO", { "GREATER_HEAL", "HEAL" }, function(c, u) return Buff("INNER_FOCUS") and u and c.lowestPct < 70 end,
            "COMBO Foco Interior -> cura grande gratis", function(c) return c.lowest end),
        HealLowest("PENANCE", 55),
        HealLowest({ "GREATER_HEAL", "HEAL", "LESSER_HEAL" }, 60),
        HealLowest("RENEW", 85, function(c, u) return UnitLacksAura(u, "RENEW", "HELPFUL") end),
        R("HEAL", "PRAYER_OF_MENDING", function(c) return c.grouped and c.inCombat and (not c.target or (not c.hostileSecret and not c.hostile)) end,
            "Prayer of Mending (10s): jogue no tanque ou aliado"),
        Hit("COMBO", "MIND_BLAST", function() return Buff("INNER_FOCUS") end, "COMBO Foco Interior -> Explosao Mental"),
        SelfBuff("SHADOWFORM", nil, true),
        R("AOE", "HOLY_NOVA", function(c) return c.meleeAoe and c.manaPct > 30 end, "Varios inimigos colados: Nova Sagrada"),
        Hit("ROTATION", "SWP", function(c) return DotDown("SWP", 16) and c.thp > 20 end, "Aplique Palavra Sombria: Dor"),
        Hit("ROTATION", "HOLY_FIRE", function(c) return not c.inCombat end, "Abertura: Fogo Sagrado"),
        Hit("ROTATION", "MIND_BLAST", nil, "Explosao Mental"),
        Hit("ROTATION", "PENANCE", nil, "Penance (12s): dano Sagrado no inimigo"),
        Hit("ROTATION", "SW_DEATH", function(c) return c.hpKnown and c.hp >= 60 end, "Shadow Word: Death (18s): tira 30% da sua vida se o alvo sobreviver"),
        Hit("ROTATION", { "MIND_FLAY", "SMITE" }, nil, "Dano continuo"),
        SelfBuff("PW_FORT"),
        SelfBuff("INNER_FIRE"),
    }
end

-- Nomes aceitos em /mvat selo <nome>
local SEAL_PREF = {
    auto = "auto",
    fury = "SEAL_FURY", furia = "SEAL_FURY",
    righteousness = "SOR", retidao = "SOR",
    crusader = "SOTC", cruzado = "SOTC",
    command = "SOC", comando = "SOC",
    light = "SOL", luz = "SOL",
    wisdom = "SOW", sabedoria = "SOW",
    justice = "SOJ", justica = "SOJ",
}
local paladin = {}   -- exposto para /mvat debug

-- PALADINO (regras do WoW Forever, segundo as notas de mudancas dos proprios addons):
--  * Selo da Furia e "o selo de tanque": cada golpe soma dano Sagrado e, com escudo, um absorvedor.
--  * O Julgamento NAO consome mais o selo (recarga 10s, alcance 10m); julgar a Furia provoca o alvo.
--  * Golpe Sagrado: golpe base do Ret, recarga 10s (arma + dano Sagrado).
CLASS_RULES.PALADIN = function()
    local function tankMode() return gear.shield or Buff("RIGHTEOUS_FURY") end

    -- segundos restantes do selo (auras fora de combate; rastreio por casts em combate)
    local function sealLeft()
        if not sealState.key then return nil end
        local left = sealState.expires - GetTime()
        return left > 0 and left or nil
    end

    local function ok(k) return Known(k) and OnBar(N[k]) end

    -- Escolhe o melhor selo ENTRE OS QUE VOCE TEM e estao na sua barra.
    local function chooseSeal(c)
        local pref = DB.seal and DB.seal ~= "auto" and SEAL_PREF[DB.seal]
        if pref and pref ~= "auto" and ok(pref) then
            return pref, "fixado por voce (/mvat selo auto desfaz)"
        end
        if ok("SEAL_FURY") and tankMode() then
            return "SEAL_FURY", gear.shield and "escudo equipado: o selo de tanque (dano + absorcao)"
                or "Furia Justa ativa: o selo de tanque"
        end
        -- Selo da Justica (impede a fuga) nao e escolhido sozinho: metade dos mobs sao
        -- humanoides e custaria dano. Use /mvat selo justica quando um alvo ficar fugindo.
        if ok("SOW") and c.manaPct < 35 then
            return "SOW", "mana baixa: Sabedoria devolve mana"
        end
        if ok("SOC") and (gear.twoHand or gear.speed >= 2.6) then
            return "SOC", "arma lenta/duas maos: o Comando bate mais forte"
        end
        if ok("SOR") then
            return "SOR", string.format("dano confiavel para a sua arma (%.1fs)", gear.speed)
        end
        if ok("SOC") then return "SOC", "melhor selo de dano disponivel" end
        for _, k in ipairs({ "SOTC", "SEAL_FURY", "SOL", "SOW", "SOJ" }) do
            if ok(k) then return k, "unico selo disponivel na sua barra" end
        end
    end
    paladin.choose, paladin.tankMode, paladin.sealLeft = chooseSeal, tankMode, sealLeft

    local function sealPicks(c) return c.sealPick and { c.sealPick } or {} end

    return {
        Emergency("DIVINE_SHIELD", 20, nil, "Quase morto: Escudo Divino"),
        Emergency("LOH", 12, nil, "Ultimo recurso: Imposicao das Maos"),
        Emergency("DIVINE_PROT", 25),
        R("EMERGENCY", "BOP", function(c, u) return c.inCombat and u and u ~= "player" and c.lowestPct < 20 end,
            function(c) return "Salve " .. UnitLabel(c.lowest) .. ": Bencao de Protecao" end, function(c) return c.lowest end),
        Interrupt("HOJ"),
        Dispel({ "CLEANSE", "PURIFY" }, { "Poison", "Disease" }),
        Dispel("CLEANSE", { "Magic" }),
        HealLowest("HOLY_SHOCK", 50),
        HealLowest("HOLY_LIGHT", 45),
        HealLowest("FOL", 75),
        -- 1) sem selo (ou acabando): aplica o melhor selo para o contexto
        R("COMBO", sealPicks, function(c)
            if not (c.hostile or c.inCombat) then return false end
            local k, why = chooseSeal(c)
            c.sealPick, c.sealWhy = k, why
            if not k then return false end
            local left = sealLeft()
            return left == nil or (left < 3 and c.inCombat)
        end, function(c)
            local nm = N[c.sealPick] or ""
            if sealLeft() then return "Renove o selo (" .. nm .. "): " .. c.sealWhy end
            return "Sem selo - " .. nm .. ": " .. c.sealWhy
        end, "player"),
        -- 2) antes da luta, com outro selo ativo: sugere trocar se o contexto pede outro
        R("COMBO", sealPicks, function(c)
            if c.inCombat or not c.hostile then return false end
            local k, why = chooseSeal(c)
            c.sealPick, c.sealWhy = k, why
            return k ~= nil and sealState.key ~= nil and sealState.key ~= k
        end, function(c) return "Troque para " .. (N[c.sealPick] or "") .. ": " .. c.sealWhy end, "player"),
        -- 3) Julgamento (nao gasta o selo no Forever) e Golpe Sagrado, ambos com recarga de 10s
        Hit("COMBO", "JUDGEMENT", function() return sealLeft() ~= nil end, function()
            return "Julgamento: nao gasta o selo (recarga 10s)" .. (sealState.key == "SEAL_FURY" and " - provoca o alvo" or "")
        end),
        Hit("ROTATION", "HOLY_STRIKE", nil, "Golpe Sagrado (recarga 10s): arma + dano Sagrado"),
        Hit("COMBO", "HOW", nil, "Alvo < 20%: Martelo da Colera"),
        R("AOE", "CONSECRATION", function(c)
            return (c.meleeAoe or (tankMode() and c.enemies >= 2)) and c.manaPct > 30
        end, "Varios mobs: Consagracao"),
        R("ROTATION", "HOLY_SHIELD", function(c) return c.inCombat and tankMode() and Lacks("HOLY_SHIELD") end, "Tanque: Escudo Sagrado"),
        Hit("ROTATION", "EXORCISM", function(c) return c.undeadOrDemon end, "Morto-vivo/Demonio: Exorcismo"),
        Hit("ROTATION", "HOLY_WRATH", function(c) return c.undeadOrDemon and c.enemies >= 2 end, "Varios mortos-vivos/demonios: Colera Sagrada"),
        R("BUFF", "RIGHTEOUS_FURY", function(c) return not c.inCombat and gear.shield and Lacks("RIGHTEOUS_FURY") end,
            "Escudo equipado: ative Furia Justa (ameaca de tanque)", "player"),
        R("BUFF", function() return tankMode() and { "DEVOTION", "RET_AURA" } or { "RET_AURA", "DEVOTION" } end,
            function(c) return not c.inCombat and Lacks("DEVOTION") and Lacks("RET_AURA") end,
            function() return tankMode() and "Aura ausente: Devocao (tanque)" or "Aura ausente: Retribuicao (dano)" end, "player"),
        R("BUFF", { "BOK", "BOM", "BOW" }, function(c)
            return not c.inCombat and Lacks("BOK") and Lacks("BOM") and Lacks("BOW")
        end, "Bencao ausente", "player"),
    }
end

CLASS_RULES.HUNTER = function()
    return {
        R("EMERGENCY", "FEIGN", function(c) return c.inCombat and c.grouped and c.threat >= 2 and c.hp < 60 end, "Aggro em voce: Fingir de Morto"),
        Emergency("DETERRENCE", 35, function(c) return c.melee end, "Apanhando corpo a corpo: Dissuasao"),
        R("HEAL", "MEND_PET", function(c) return c.inCombat and c.petHp < 40 end, "Pet morrendo: Curar Ajudante", "pet"),
        Hit("INTERRUPT", "SCATTER", function(c) return c.cast and c.cast.interruptible and not c.cast.unknownInt end, function(c) return "Interrompa: " .. c.cast.name end),
        R("BUFF", "HAWK", function(c) return c.hostile and not c.melee and Lacks("HAWK") end, "Combate a distancia: Aspecto do Falcao", "player"),
        Hit("COMBO", "MONGOOSE", function(c) return c.melee end, "Alvo esquivou: Mordida do Mangusto"),
        Hit("COMBO", "COUNTERATTACK", function(c) return c.melee end, "Aparou! Contra-ataque"),
        Hit("ROTATION", "WING_CLIP", function(c) return c.melee and DotDown("WING_CLIP", 7) and not c.grouped end, "Colado: Cortar Asas e afaste-se"),
        Hit("ROTATION", "RAPTOR", function(c) return c.melee end, "Corpo a corpo: Golpe do Raptor"),
        Hit("ROTATION", "MARK", function(c) return DotDown("MARK", 100) and (c.elite or c.thp > 60) end, "Marque o alvo"),
        Hit("AOE", { "VOLLEY", "MULTI" }, function(c) return c.aoe end, "Varios mobs: dano em area"),
        R("ROTATION", "RAPID_FIRE", function(c) return c.hostile and c.inCombat and c.elite end, "Elite/chefe: Disparo Rapido"),
        Hit("ROTATION", "SERPENT", function(c) return DotDown("SERPENT", 12) and c.thp > 30 end, "Aplique Picada da Serpente"),
        Hit("ROTATION", "AIMED", function(c) return not c.melee end, "Tiro Mirado"),
        Hit("ROTATION", "MULTI", function(c) return not c.melee end, "Tiro Multiplo"),
        Hit("ROTATION", "ARCANE_SHOT", function(c) return not c.melee end, "Tiro Arcano"),
    }
end

CLASS_RULES.WARLOCK = function()
    local CURSES = { "COA", "COE", "COS", "COR", "COW", "COT" }
    local function anyCurse() return AnyOnTarget(unpack(CURSES)) end
    return {
        Emergency("DEATH_COIL", 35, nil, "Vida baixa: Espiral da Morte (cura)"),
        Emergency("HOWL", 40, function(c) return c.near >= 2 end, "Cercado: Uivo do Terror"),
        Interrupt("DEATH_COIL"),
        Hit("COMBO", "SHADOW_BOLT", function() return Buff("SHADOW_TRANCE") end, "COMBO Transe Sombrio -> Seta Sombria instantanea!"),
        Hit("COMBO", "SHADOWBURN", function(c) return c.thp < 20 end, "Finalize: Queimadura Sombria"),
        Hit("COMBO", "DRAIN_SOUL", function(c) return c.thp < 12 and (Pub(GetItemCount(6265)) or 99) < 5 end, "Alvo morrendo: Drenar Alma (fragmento)"),
        R("COMBO", "LIFE_TAP", function(c) return c.manaPct < 25 and c.hp > 60 end, "Mana baixa, vida alta: Toque da Vida", "player"),
        Hit("ROTATION", "DRAIN_LIFE", function(c) return c.hp < 45 end, "Recupere vida: Drenar Vida"),
        Hit("AOE", "RAIN_OF_FIRE", function(c) return c.aoe and not c.meleeAoe end, "Varios mobs: Chuva de Fogo"),
        R("AOE", "HELLFIRE", function(c) return c.meleeAoe and c.hp > 50 end, "Mobs colados: Fogo do Inferno"),
        Hit("ROTATION", "SOUL_FIRE", function(c) return not c.inCombat and c.elite end, "Abertura em elite: Fogo da Alma (usa fragmento)"),
        Hit("ROTATION", "COA", function(c) return DotDown("COA", 22) and c.thp > 30 end, "Aplique o Bane da Agonia"),
        Hit("ROTATION", { "COE", "COW" }, function(c) return DotDown("COE", 100) and DotDown("COW", 100) and c.thp > 30 end,
            "Aplique uma Maldicao (separada do Bane)"),
        Hit("ROTATION", "CORRUPTION", function(c) return DotDown("CORRUPTION", 14) and c.thp > 20 end, "Aplique Corrupcao"),
        Hit("ROTATION", "SIPHON_LIFE", function(c) return DotDown("SIPHON_LIFE", 26) and c.thp > 30 end, "Aplique Dreno de Vida (cura voce)"),
        Hit("ROTATION", "IMMOLATE", function(c) return DotDown("IMMOLATE", 12) and c.thp > 30 end, "Aplique Imolar"),
        Hit("COMBO", "CONFLAGRATE", nil, "Imolar no alvo: Conflagrar"),
        Hit("ROTATION", "SHADOW_BOLT", nil, "Seta Sombria"),
        SelfBuff({ "DEMON_ARMOR", "DEMON_SKIN" }),
    }
end

CLASS_RULES.SHAMAN = function()
    local function weaponMissing() local mh = GetWeaponEnchantInfo(); return mh ~= nil and not issecret(mh) and not mh end
    local function noFireTotem()
        if not GetTotemInfo then return false end
        local has = GetTotemInfo(1)
        return not issecret(has) and not has
    end
    -- totem de fogo no chao: lido fora de combate; em combate vale o que VOCE colocou ha pouco
    local function fireTotemUp()
        if GetTotemInfo then
            local has = GetTotemInfo(1)
            if not issecret(has) and (has == true or (type(has) == "number" and has > 0)) then return true end
        end
        local t = lastCast.self.SEARING or lastCast.self.MAGMA
        return t ~= nil and (GetTime() - t) < 30
    end
    return {
        R("EMERGENCY", "NS_SHAMAN", function(c) return c.inCombat and c.lowestPct < 30 end, "Emergencia: Rapidez da Natureza -> Onda Curativa"),
        R("COMBO", "HEALING_WAVE", function(c, u) return Buff("NS_SHAMAN") and u and c.lowestPct < 60 end,
            "COMBO Rapidez da Natureza -> Onda Curativa instantanea", function(c) return c.lowest end),
        Interrupt("EARTH_SHOCK"),
        R("DEFENSIVE", "GROUNDING", function(c) return c.cast and c.cast.onGroup end, "Feitico vindo: Totem de Aterramento"),
        Dispel("CURE_POISON_S", { "Poison" }),
        Dispel("CURE_DISEASE_S", { "Disease" }),
        HealLowest({ "LHW", "HEALING_WAVE" }, 40),
        HealLowest("CHAIN_HEAL", 75, function(c) return c.injured >= 3 end),
        HealLowest("HEALING_WAVE", 60),
        Hit("DISPEL", "PURGE", function() return TargetHasMagicBuff() end, "Inimigo com buff magico: Expurgar"),
        R("BUFF", { "WINDFURY", "FLAMETONGUE", "ROCKBITER" }, function(c) return weaponMissing() end, "Encante a arma", "player"),
        SelfBuff("LIGHTNING_SHIELD", nil, true),
        Hit("COMBO", "CHAIN_LIGHTNING", function(c) return (Buff("SHAMAN_CLEARCAST") or Buff("ELEM_MASTERY")) and c.enemies >= 2 end, "COMBO Clarividencia -> Cadeia de Raios"),
        Hit("COMBO", "LIGHTNING_BOLT", function() return Buff("SHAMAN_CLEARCAST") or Buff("ELEM_MASTERY") end, "COMBO Clarividencia -> Raio"),
        R("COMBO", "ELEM_MASTERY", function(c) return c.hostile and c.inCombat and c.elite end, "Elite/chefe: Dominio Elemental"),
        Hit("ROTATION", "STORMSTRIKE", nil, "Ataque de Tempestade"),
        R("AOE", "MAGMA", function(c) return c.meleeAoe and noFireTotem() end, "Varios mobs: totem de fogo em area"),
        Hit("AOE", "FIRE_NOVA", function(c) return c.enemies >= 2 and fireTotemUp() end, "Fire Nova (10s): explode em volta do totem de fogo"),
        Hit("AOE", "CHAIN_LIGHTNING", function(c) return c.enemies >= 2 end, "Varios mobs: Cadeia de Raios"),
        R("ROTATION", "SEARING", function(c) return c.hostile and c.inCombat and noFireTotem() end, "Totem Calcinante"),
        Hit("ROTATION", "FLAME_SHOCK", function(c) return DotDown("FLAME_SHOCK", 10) and c.thp > 30 end, "Aplique Choque Flamejante"),
        Hit("ROTATION", "EARTH_SHOCK", function(c) return c.melee and c.manaPct > 50 end, "Choque Terreno"),
        Hit("ROTATION", "LIGHTNING_BOLT", function(c) return not c.melee or not c.inCombat end, "Raio"),
    }
end

CLASS_RULES.DRUID = function()
    local function bear() return InForm("BEAR", "DIRE_BEAR") end
    local function cat() return InForm("CAT") end
    local function caster() return not bear() and not cat() end
    return {
        Emergency("BARKSKIN", 40),
        R("EMERGENCY", "FRENZIED", function(c) return c.inCombat and bear() and c.hp < 40 end, "Urso ferido: Regeneracao Frenetica"),
        R("EMERGENCY", "NS_DRUID", function(c) return c.inCombat and c.lowestPct < 30 and caster() end, "Emergencia: Rapidez da Natureza -> Toque de Cura"),
        R("COMBO", "HEALING_TOUCH", function(c, u) return Buff("NS_DRUID") and u and c.lowestPct < 60 end,
            "COMBO Rapidez da Natureza -> Toque de Cura instantaneo", function(c) return c.lowest end),
        Interrupt({ "FERAL_CHARGE", "BASH" }),
        Dispel("REMOVE_CURSE", { "Curse" }),
        Dispel({ "ABOLISH_POISON", "CURE_POISON_D" }, { "Poison" }),
        HealLowest("SWIFTMEND", 40, function(c, u) return UnitHasAura(u, "REJUV", "HELPFUL") or UnitHasAura(u, "REGROWTH", "HELPFUL") end),
        HealLowest("REGROWTH", 45, function() return caster() end),
        HealLowest("HEALING_TOUCH", 55, function() return caster() end),
        HealLowest("REJUV", 85, function(c, u) return caster() and UnitLacksAura(u, "REJUV", "HELPFUL") end),
        Taunt("GROWL", bear),
        -- Urso (tank)
        Hit("COMBO", "MAUL", function() return bear() and Buff("DRUID_CLEARCAST") end, "COMBO Clarividencia -> Espancar gratis"),
        Hit("AOE", "DEMO_ROAR", function(c) return bear() and c.near >= 2 and NotOnTargetAny("DEMO_ROAR") end, "Area: Rugido Desmoralizante"),
        Hit("AOE", "SWIPE", function(c) return bear() and c.near >= 2 end, "Varios mobs: Golpe Giratorio"),
        Hit("ROTATION", "LACERATE", function(c) return bear() and DotDown("LACERATE", 12) end, "Lacerar (sangramento de urso, acumula)"),
        Hit("ROTATION", "MAUL", function(c) return bear() and (not c.powerKnown or c.power >= 15) end, "Espancar"),
        -- Gato (dano)
        Hit("COMBO", { "POUNCE", "RAVAGE" }, function(c) return cat() and c.stealth and not c.inCombat end,
            "Rondar: abertura (Ravage por tras, Pounce atordoa)"),
        Hit("COMBO", "SHRED", function() return cat() and Buff("DRUID_CLEARCAST") end, "COMBO Clarividencia -> Retalhar (por tras)"),
        Hit("COMBO", "RIP", function(c) return cat() and c.cp >= 5 and DotDown("RIP", 9) and c.thp > 40 end, "5 pontos: Rasgar"),
        Hit("COMBO", "BITE", function(c) return cat() and (c.cp >= 5 or (c.cp >= 3 and c.thp < 20)) end, function(c) return c.cp .. " pontos: Mordida Feroz" end),
        R("ROTATION", "TIGERS_FURY", function(c) return cat() and c.hostile and c.inCombat and BuffDown("TIGERS_FURY", 5) and (not c.powerKnown or c.power >= 80) end, "Furia do Tigre"),
        Hit("ROTATION", "RAKE", function(c) return cat() and DotDown("RAKE", 8) end, "Aplique Rasgadura"),
        Hit("ROTATION", "CLAW", function() return cat() end, "Gere pontos: Garra"),
        -- Conjurador / Equilibrio
        Hit("COMBO", "STARFIRE", function() return caster() and Buff("DRUID_CLEARCAST") end, "COMBO Clarividencia -> Fogo Estelar gratis"),
        R("AOE", "HURRICANE", function(c) return caster() and c.enemies >= DB.aoe + 1 end, "Varios mobs: Furacao"),
        Hit("ROTATION", "FAERIE_FIRE", function(c) return caster() and c.elite and DotDown("FAERIE_FIRE", 35) end, "Elite: Fogo Feerico"),
        Hit("ROTATION", "MOONFIRE", function(c) return caster() and DotDown("MOONFIRE", 10) end, "Aplique Fogo Lunar"),
        Hit("ROTATION", "INSECT_SWARM", function(c) return caster() and DotDown("INSECT_SWARM", 11) and c.thp > 30 end, "Aplique Enxame de Insetos"),
        Hit("ROTATION", "STARFIRE", function(c) return caster() and c.thp > 40 end, "Fogo Estelar"),
        Hit("ROTATION", "WRATH", function() return caster() end, "Ira"),
        R("BUFF", "MOTW", function(c) return not c.inCombat and caster() and Lacks("MOTW") end, "Buff ausente", "player"),
        R("BUFF", "THORNS", function(c) return not c.inCombat and caster() and Lacks("THORNS") end, "Buff ausente", "player"),
    }
end

---------------------------------------------------------------------------
-- 8. MOTOR DE DECISAO
---------------------------------------------------------------------------
local CATEGORY = {
    EMERGENCY = { 1.00, 0.15, 0.15, "EMERGENCIA" },
    INTERRUPT = { 1.00, 0.55, 0.00, "INTERROMPER" },
    DEFENSIVE = { 0.90, 0.30, 0.90, "DEFESA" },
    DISPEL    = { 0.65, 0.35, 1.00, "DISSIPAR" },
    HEAL      = { 0.20, 1.00, 0.30, "CURA" },
    TAUNT     = { 1.00, 0.85, 0.20, "PROVOCAR" },
    COMBO     = { 1.00, 0.82, 0.00, "COMBO" },
    AOE       = { 0.20, 0.80, 1.00, "AREA / FARM" },
    ROTATION  = { 0.85, 0.85, 0.85, "DANO" },
    BUFF      = { 0.30, 0.90, 0.90, "BUFF" },
}

local rules = {}
local playerClass

-- PROCS: o brilho que a propria Blizzard coloca numa habilidade (Sobrepujar,
-- Executar, Revanche, procs de talento...). Os eventos SPELL_ACTIVATION_OVERLAY
-- continuam liberados no Forever, entao esta e a fonte principal em combate.
local glowing = {}   -- [spellID] = true enquanto a Blizzard destaca o feitico
local procSeen = 0   -- procs recebidos no combate atual (para o diag)

local function ProcKey(sid)
    local key = "PROC_" .. sid
    if not N[key] then
        local name, icon = SpellInfo(sid)
        if not name then return nil end
        N[key], ICON[key] = name, icon
    end
    return key
end

local function GlowingProcKey()
    local ISO = C_SpellActivationOverlay and C_SpellActivationOverlay.IsSpellOverlayed
    for sid in pairs(glowing) do
        local key = ProcKey(sid)
        local still = true
        if ISO then
            local ok, on = pcall(ISO, sid)
            if ok and not issecret(on) and not on then still = false end
        end
        if not still then glowing[sid] = nil
        elseif key and Known(key) then return key end
    end
end

local PROC_RULE = { cat = "COMBO", pick = {}, proc = true,
    msg = "Proc ativo! A Blizzard destacou esta habilidade" }

-- COMBOS PELA SUA ULTIMA SKILL. Os seus proprios casts continuam legiveis em
-- combate (UNIT_SPELLCAST_SUCCEEDED do "player"), entao "usei A -> use B" funciona
-- mesmo com auras e buffs escondidos. { de, para, janela(s), mensagem, unidade }
local castSeen, castReadable = 0, 0
local nameToKey

local SEQUENCES = {
    MAGE = {
        { "PRESENCE_OF_MIND", "PYROBLAST", 15, "Presenca da Mente usada: Piroblasto!", "target" },
        { "FROST_NOVA", "ICE_LANCE", 5, "Nova Congelante usada: Ice Lance no alvo congelado", "target" },
        { "FROST_NOVA", "ARCANE_EXPLOSION", 6, "Nova Congelante usada: Explosao Arcana" },
        { "COMBUSTION", { "FIREBALL", "SCORCH" }, 30, "Combustao ativa: continue com fogo", "target" },
    },
    WARRIOR = {
        { "SWEEPING", "WHIRLWIND", 10, "Golpes Amplos usados: Redemoinho", "target" },
        { "THUNDER_CLAP", "DEMO_SHOUT", 5, "Trovoada usada: Grito Desmoralizante" },
    },
    ROGUE = {
        { "GOUGE", "SINISTER", 5, "Inimigo atordoado: ataque seguro", "target" },
        { "VANISH", "SINISTER", 8, "Furtivo: abra com Golpe Sinistro", "target" },
    },
    PRIEST = {
        { "INNER_FOCUS", { "GREATER_HEAL", "HEAL" }, 10, "Foco Interior usado: cura grande gratis" },
        { "PW_SHIELD", "RENEW", 6, "Escudo usado: Renovar" },
    },
    PALADIN = {
        { { "SEAL_FURY", "SOC", "SOR", "SOTC", "SOL", "SOW", "SOJ" }, "JUDGEMENT", 28, "Selo ativo: Julgamento (nao gasta o selo)", "target" },
        { "JUDGEMENT", "HOLY_STRIKE", 4, "Julgamento feito: Golpe Sagrado", "target" },
    },
    HUNTER = {
        { "MARK", "SERPENT", 8, "Marca usada: Picada da Serpente", "target" },
        { "SERPENT", "ARCANE_SHOT", 6, "Picada usada: Tiro Arcano", "target" },
    },
    WARLOCK = {
        { { "COA", "COE", "COW", "COR", "COS", "COT" }, "CORRUPTION", 10, "Maldicao usada: Corrupcao", "target" },
        { "CORRUPTION", "IMMOLATE", 10, "Corrupcao usada: Imolar", "target" },
        { "IMMOLATE", "SHADOW_BOLT", 10, "Imolar usado: Seta Sombria", "target" },
    },
    SHAMAN = {
        { "ELEM_MASTERY", { "CHAIN_LIGHTNING", "LIGHTNING_BOLT" }, 15, "Dominio Elemental: raio forte", "target" },
        { "NS_SHAMAN", "HEALING_WAVE", 10, "Rapidez da Natureza: Onda Curativa instantanea" },
    },
    DRUID = {
        { "NS_DRUID", "HEALING_TOUCH", 10, "Rapidez da Natureza: Toque de Cura instantaneo" },
        { "FAERIE_FIRE", "MOONFIRE", 8, "Fogo Feerico usado: Fogo Lunar", "target" },
        { "MOONFIRE", "INSECT_SWARM", 8, "Fogo Lunar usado: Enxame de Insetos", "target" },
        { "INSECT_SWARM", "STARFIRE", 10, "Enxame usado: Fogo Estelar", "target" },
    },
}

local function AfterRule(def)
    local from, to, window, msg, unit = def[1], def[2], def[3], def[4], def[5]
    local set = {}
    for _, k in ipairs(type(from) == "table" and from or { from }) do set[k] = true end
    return R("COMBO", to, function()
        if not (lastCast.key and set[lastCast.key] and (GetTime() - lastCast.t) <= window) then return false end
        local d = type(to) == "string" and lastCast.dur[to]
        return not d or DotDown(to, d)
    end, msg, unit)
end

local function OnPlayerCast(sid)
    castSeen = castSeen + 1
    sid = Pub(sid)
    if type(sid) ~= "number" then return end
    castReadable = castReadable + 1
    local name = SpellInfo(sid)
    if not name then return end
    if not nameToKey then
        nameToKey = {}
        for key, n in pairs(N) do
            if not key:find("^PROC_") then nameToKey[n] = key end
        end
    end
    local key = nameToKey[name]
    if key then
        lastCast.key, lastCast.t = key, GetTime()
        lastCast.at[key] = lastCast.t     -- debuffs no alvo (zera ao trocar de alvo)
        lastCast.self[key] = lastCast.t   -- buffs em voce
        if lastCast.cpb[key] then lastCast.cp = math.min(5, lastCast.cp + lastCast.cpb[key])
        elseif lastCast.cpf[key] then lastCast.cp = 0 end
        -- selo lancado por voce: rastreia qual e ate quando (o jogo esconde as auras em combate)
        for _, sk in ipairs(SEAL_KEYS) do
            if key == sk then sealState.key, sealState.expires = key, GetTime() + sealDur end
        end
    end
end

local function LoadClassRules()
    local _, class = UnitClass("player")
    playerClass = class
    local builder = CLASS_RULES[class]
    rules = builder and builder() or {}
    nameToKey = nil
    -- procs e combos por sequencia entram antes de combos/rotacao
    -- (depois de emergencia/interrupt/cura)
    local at = #rules + 1
    for i, rule in ipairs(rules) do
        if rule.cat == "COMBO" or rule.cat == "AOE" or rule.cat == "ROTATION" or rule.cat == "BUFF" then at = i; break end
    end
    table.insert(rules, at, PROC_RULE)
    for i, def in ipairs(SEQUENCES[class] or {}) do
        table.insert(rules, at + i, AfterRule(def))
    end
end

local function ResolveUnit(rule)
    local u = rule.unit
    if type(u) == "function" then return u(c) end
    return u
end

-- Retorna regra, chave escolhida e unidade da primeira sugestao valida.
local function Evaluate()
    for _, rule in ipairs(rules) do
        if rule.proc then
            local key = next(glowing) and GlowingProcKey()
            if key and Ready(key) then return rule, key end
        else
            local unit = ResolveUnit(rule)
            if (unit == nil and not rule.unit) or (unit and UnitExists(unit)) then
                if not rule.when or rule.when(c, unit) then
                    local picks = rule.pickFn and rule.pickFn(c, unit) or rule.pick
                    for _, key in ipairs(picks) do
                        if Known(key) and Ready(key, unit) then return rule, key, unit end
                    end
                end
            end
        end
    end
end

---------------------------------------------------------------------------
-- 9. HUD FLUTUANTE (ancora propria e independente)
---------------------------------------------------------------------------
local ICON_SIZE = 56
local hud = CreateFrame("Frame", "MVAT_HUD", UIParent, BackdropTemplateMixin and "BackdropTemplate" or nil)
hud:SetSize(ICON_SIZE, ICON_SIZE)
hud:SetFrameStrata("HIGH")
hud:SetClampedToScreen(true)
hud:SetMovable(true)
hud:RegisterForDrag("LeftButton")
hud:Hide()

hud.border = hud:CreateTexture(nil, "BACKGROUND")
hud.border:SetPoint("TOPLEFT", -3, 3)
hud.border:SetPoint("BOTTOMRIGHT", 3, -3)
hud.border:SetColorTexture(1, 1, 1, 1)

hud.icon = hud:CreateTexture(nil, "ARTWORK")
hud.icon:SetAllPoints()
hud.icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)

hud.key = hud:CreateFontString(nil, "OVERLAY")
hud.key:SetFont(STANDARD_TEXT_FONT, 18, "THICKOUTLINE")
hud.key:SetPoint("BOTTOMRIGHT", -2, 3)
hud.key:SetTextColor(1, 1, 1)

hud.label = hud:CreateFontString(nil, "OVERLAY")
hud.label:SetFont(STANDARD_TEXT_FONT, 11, "OUTLINE")
hud.label:SetPoint("BOTTOM", hud, "TOP", 0, 6)

hud.reason = hud:CreateFontString(nil, "OVERLAY")
hud.reason:SetFont(STANDARD_TEXT_FONT, 12, "OUTLINE")
hud.reason:SetPoint("TOP", hud, "BOTTOM", 0, -6)
hud.reason:SetWidth(260)
hud.reason:SetJustifyH("CENTER")

-- Pulso ao trocar de sugestao
hud.pulse = hud:CreateAnimationGroup()
local grow = hud.pulse:CreateAnimation("Scale")
grow:SetScale(1.18, 1.18); grow:SetDuration(0.10); grow:SetOrder(1)
local shrink = hud.pulse:CreateAnimation("Scale")
shrink:SetScale(1 / 1.18, 1 / 1.18); shrink:SetDuration(0.12); shrink:SetOrder(2)

-- Fundo visivel apenas quando destravado (modo de posicionamento)
hud.mover = hud:CreateTexture(nil, "BACKGROUND", nil, -1)
hud.mover:SetPoint("TOPLEFT", -40, 30)
hud.mover:SetPoint("BOTTOMRIGHT", 40, -40)
hud.mover:SetColorTexture(0, 0.6, 1, 0.25)
hud.mover:Hide()

hud:SetScript("OnDragStart", function(self) if not DB.locked then self:StartMoving() end end)
hud:SetScript("OnDragStop", function(self)
    self:StopMovingOrSizing()
    local point, _, relPoint, x, y = self:GetPoint()
    DB.point, DB.relPoint, DB.x, DB.y = point, relPoint, x, y
end)

local function ApplyLayout()
    hud:ClearAllPoints()
    hud:SetPoint(DB.point, UIParent, DB.relPoint, DB.x, DB.y)
    hud:SetScale(DB.scale)
    for _, f in ipairs(hud.panels or {}) do f:SetScale(DB.scale) end
    hud:EnableMouse(not DB.locked)          -- travado = clique atravessa o HUD
    hud.mover:SetShown(not DB.locked)
    hud.reason:SetShown(DB.showText)
end

---------------------------------------------------------------------------
-- 9b. PAINEL DE CAST (funciona mesmo com tudo "secreto" em combate)
---------------------------------------------------------------------------
-- O Forever deixa addons MOSTRAR valores secretos (SetTexture, SetText) e
-- controlar a transparencia por um booleano secreto (SetAlphaFromBoolean), mas
-- nao deixa COMPARAR nem decidir com eles. E exatamente assim que o cast bar e o
-- aviso de interrupcao do EllesmereUI funcionam. O painel faz o mesmo:
--   * icone + nome do cast do inimigo  -> SetTexture/SetText (valores secretos)
--   * icone de INTERROMPER             -> transparencia = "cast e interrompivel?"
--   * icone de DEFESA                  -> transparencia = "cast e em mim E nao interrompivel?"
-- O que o codigo decide com dados LIMPOS: o cast existe (type(...) ~= "nil"), a
-- sua habilidade existe e esta fora de recarga (isActive).
-- Filhos de UIParent (nao do HUD): continuam visiveis mesmo se o icone principal estiver oculto.
hud.panels = {}
local cast = CreateFrame("Frame", "MVAT_CastPanel", UIParent)
cast:SetSize(1, 1)
cast:SetFrameStrata("HIGH")
cast:SetPoint("BOTTOM", hud, "TOP", 0, 26)
cast:Hide()
hud.panels[#hud.panels + 1] = cast

local function MakeSlot(size)
    local f = CreateFrame("Frame", nil, cast)
    f:SetSize(size, size)
    f.border = f:CreateTexture(nil, "BACKGROUND")
    f.border:SetPoint("TOPLEFT", -2, 2); f.border:SetPoint("BOTTOMRIGHT", 2, -2)
    f.icon = f:CreateTexture(nil, "ARTWORK")
    f.icon:SetAllPoints(); f.icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
    f.key = f:CreateFontString(nil, "OVERLAY")
    f.key:SetFont(STANDARD_TEXT_FONT, 13, "THICKOUTLINE")
    f.key:SetPoint("BOTTOMRIGHT", -1, 2)
    f.title = f:CreateFontString(nil, "OVERLAY")
    f.title:SetFont(STANDARD_TEXT_FONT, 10, "OUTLINE")
    f.title:SetPoint("BOTTOM", f, "TOP", 0, 3)
    return f
end

cast.enemy = MakeSlot(34)    -- o que o inimigo esta castando
cast.enemy:SetPoint("LEFT", cast, "CENTER", 4, 0)
cast.enemy.border:SetColorTexture(1, 0.3, 0.1, 0.9)
cast.enemy.title:SetText("INIMIGO"); cast.enemy.title:SetTextColor(1, 0.4, 0.2)
cast.name = cast:CreateFontString(nil, "OVERLAY")
cast.name:SetFont(STANDARD_TEXT_FONT, 12, "OUTLINE")
cast.name:SetPoint("LEFT", cast.enemy, "RIGHT", 6, 0)
cast.name:SetWidth(150); cast.name:SetJustifyH("LEFT")

cast.kick = MakeSlot(34)     -- interromper
cast.kick:SetPoint("RIGHT", cast, "CENTER", -4, 0)
cast.kick.border:SetColorTexture(1, 0.55, 0, 0.95)
cast.kick.title:SetText("INTERROMPER"); cast.kick.title:SetTextColor(1, 0.6, 0)

cast.def = MakeSlot(34)      -- defesa
cast.def:SetPoint("RIGHT", cast.kick, "LEFT", -10, 0)
cast.def.border:SetColorTexture(0.9, 0.3, 0.9, 0.95)
cast.def.title:SetText("DEFESA"); cast.def.title:SetTextColor(0.95, 0.5, 0.95)

-- Habilidades de interrupcao e de defesa por classe (primeira conhecida e fora de recarga)
local KICKS = {
    WARRIOR = { "PUMMEL", "SHIELD_BASH" }, ROGUE = { "KICK" }, MAGE = { "COUNTERSPELL" },
    PRIEST = { "SILENCE" }, PALADIN = { "HOJ" }, HUNTER = { "SCATTER" },
    WARLOCK = { "DEATH_COIL" }, SHAMAN = { "EARTH_SHOCK" }, DRUID = { "BASH" },
}
local DEFENSES = {
    WARRIOR = { "SHIELD_BLOCK", "SHIELD_WALL" }, ROGUE = { "EVASION" }, MAGE = { "ICE_BLOCK", "ICE_BARRIER", "MANA_SHIELD" },
    PRIEST = { "PW_SHIELD", "FADE" }, PALADIN = { "DIVINE_PROT", "DIVINE_SHIELD" }, HUNTER = { "DETERRENCE" },
    WARLOCK = { "DEATH_COIL" }, SHAMAN = { "GROUNDING" }, DRUID = { "BARKSKIN" },
}

local function FirstReady(list)
    for _, k in ipairs(list or {}) do
        if Known(k) and OffCooldown(k) then return k end
    end
end

local function SetAlphaFromBool(frame, bool, whenTrue, whenFalse)
    -- bool pode ser SECRETO: so a API nativa o le (nunca comparamos)
    local ev = C_CurveUtil and C_CurveUtil.EvaluateColorValueFromBoolean
    if ev then
        local ok = pcall(function() frame:SetAlpha(ev(bool, whenTrue, whenFalse)) end)
        if ok then return end
    end
    if frame.SetAlphaFromBoolean and pcall(frame.SetAlphaFromBoolean, frame, bool, whenTrue, whenFalse) then
        return
    end
    frame:SetAlpha(1)   -- sem API: mostra sempre (melhor avisar a mais do que nada)
end

local castState = { active = false, started = 0, count = 0, readable = nil, nameReadable = nil, last = {} }
local encState = { warning = 0, timeline = 0, valid = false, validTimeline = false }

-- Le o cast do unit. type(x) funciona mesmo com valor secreto.
local function ReadCast(unit)
    local name, _, tex, _, _, _, castID, notInt, sid = UnitCastingInfo(unit)
    if type(name) == "nil" then
        name, _, tex, _, _, _, notInt, sid = UnitChannelInfo(unit)
        castID = nil
    end
    if type(name) == "nil" then return nil end
    return name, tex, notInt, sid
end

local function HideCastPanel()
    if castState.active then castState.active = false end
    cast:Hide()
end

-- Chamado a cada ciclo de atualizacao (barato): maquina de estados sobre
-- "existe um cast no alvo?", que e um dado limpo.
local function CastTick()
    local unit = "target"
    if not UnitExists(unit) or UnitIsDeadOrGhost("player") then HideCastPanel(); return end
    local friendly = _G.UnitCanAttack("player", unit)
    if not issecret(friendly) and not friendly then HideCastPanel(); return end  -- aliado castando: ignora
    local name, tex, notInt, sid = ReadCast(unit)
    if name == nil then HideCastPanel(); return end

    -- primeiro quadro desse cast: pinta e mede o que esta legivel
    local fresh = not castState.active
    castState.active = true
    if fresh then
        castState.count = castState.count + 1
        castState.started = GetTime()
        castState.nameReadable = not issecret(name)
        castState.intReadable = not issecret(notInt)
        castState.meReadable = PlayerIsSpellTarget ~= nil and not issecret(PlayerIsSpellTarget(unit))
    end

    pcall(cast.enemy.icon.SetTexture, cast.enemy.icon, tex)        -- aceita valor secreto
    pcall(cast.name.SetText, cast.name, name)                       -- aceita valor secreto

    -- INTERROMPER: so se eu tenho a habilidade e ela esta fora de recarga (limpo);
    -- a transparencia segue "e interrompivel?" (secreto).
    local kickKey = FirstReady(KICKS[playerClass])
    if kickKey then
        cast.kick.icon:SetTexture(ICON[kickKey] or 134400)
        cast.kick.key:SetText(GetKeybind(kickKey))
        cast.kick:Show()
        SetAlphaFromBool(cast.kick, notInt, 0, 1)                   -- notInt=true -> some
    else
        cast.kick:Hide()
    end

    -- DEFESA: so se o cast e EM MIM e NAO e interrompivel (ambos secretos).
    local defKey = FirstReady(DEFENSES[playerClass])
    local atMe = PlayerIsSpellTarget and PlayerIsSpellTarget(unit)
    if defKey and type(atMe) ~= "nil" then
        cast.def.icon:SetTexture(ICON[defKey] or 134400)
        cast.def.key:SetText(GetKeybind(defKey))
        cast.def:Show()
        local ev = C_CurveUtil and C_CurveUtil.EvaluateColorValueFromBoolean
        local ok = ev and pcall(function() cast.def:SetAlpha(ev(atMe, ev(notInt, 1, 0), 0)) end)
        if not ok then SetAlphaFromBool(cast.def, atMe, 1, 0) end
    else
        cast.def:Hide()
    end

    cast:Show()
end

---------------------------------------------------------------------------
-- 9c. AVISO DE ENCONTRO (ENCOUNTER_WARNING) - so se o cliente enviar
---------------------------------------------------------------------------
-- E o sistema que o DBM/BigWigs usam em Midnight: texto, icone e severidade do
-- aviso do chefe. Texto/icone sao secretos (so exibimos); severidade e duracao
-- sao limpas. No Forever o DBM nao liga esses eventos; aqui ligamos se existirem.
local banner = CreateFrame("Frame", "MVAT_Banner", UIParent)
banner:SetSize(1, 1)
banner:SetFrameStrata("HIGH")
banner:SetPoint("TOP", hud, "BOTTOM", 0, -44)
banner:Hide()
hud.panels[#hud.panels + 1] = banner
banner.icon = banner:CreateTexture(nil, "ARTWORK")
banner.icon:SetSize(30, 30); banner.icon:SetPoint("RIGHT", banner, "CENTER", -4, 0)
banner.icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
banner.text = banner:CreateFontString(nil, "OVERLAY")
banner.text:SetFont(STANDARD_TEXT_FONT, 14, "THICKOUTLINE")
banner.text:SetPoint("LEFT", banner, "CENTER", 2, 0)
banner.text:SetWidth(240); banner.text:SetJustifyH("LEFT")
local bannerUntil = 0

local SEV_COLOR = { [0] = { 1, 1, 0.4 }, [1] = { 1, 0.6, 0.1 }, [2] = { 1, 0.15, 0.15 } }

local function ShowEncounterWarning(info)
    if type(info) ~= "table" then return end
    encState.warning = encState.warning + 1
    local sev = info.severity
    if issecret(sev) or type(sev) ~= "number" then sev = 1 end
    local col = SEV_COLOR[sev] or SEV_COLOR[1]
    local text = info.text
    -- o texto do aviso pode ter %s para o conjurador/alvo; formatar tambem aceita secretos
    local ok, formatted = pcall(string.format, text, info.casterName or "", info.targetName or "")
    pcall(banner.text.SetText, banner.text, ok and formatted or text)
    banner.text:SetTextColor(col[1], col[2], col[3])
    pcall(banner.icon.SetTexture, banner.icon, info.iconFileID)
    local dur = info.duration
    if issecret(dur) or type(dur) ~= "number" or dur <= 0 or dur > 15 then dur = 4 end
    bannerUntil = GetTime() + dur
    banner:Show()
end

local function BannerTick()
    if banner:IsShown() and GetTime() > bannerUntil then banner:Hide() end
end

local current -- chave exibida no momento

local function ShowSuggestion(key, cat, text)
    local col = CATEGORY[cat] or CATEGORY.ROTATION
    hud.icon:SetTexture(ICON[key] or 134400)
    hud.border:SetColorTexture(col[1], col[2], col[3], 0.9)
    hud.label:SetText(col[4])
    hud.label:SetTextColor(col[1], col[2], col[3])
    hud.key:SetText(GetKeybind(key))
    hud.reason:SetText(text or N[key] or "")
    if current ~= key then
        current = key
        hud.pulse:Stop(); hud.pulse:Play()
    end
    hud:Show()
end

local function HideSuggestion()
    current = nil
    if DB.locked then hud:Hide()
    else
        hud.icon:SetTexture(134400) -- "?" para posicionar
        hud.key:SetText("")
        hud.label:SetText("MVAT - arraste para mover")
        hud.label:SetTextColor(0.2, 0.8, 1)
        hud.reason:SetText("/mvat lock para travar")
        hud.border:SetColorTexture(0.2, 0.8, 1, 0.9)
        hud:Show()
    end
end

local testUntil = 0
local combatSnap = { seen = false, active = false, shown = 0 } -- o que estava legivel no ultimo combate

local function DoUpdate()
    if UnitIsDeadOrGhost("player") or Is(UnitOnTaxi("player")) or (Is(IsMounted()) and not UnitAffectingCombat("player")) then
        HideSuggestion(); return
    end
    BuildContext()
    if c.inCombat then
        if not combatSnap.active then -- inicio de um novo combate
            combatSnap.active, combatSnap.seen, combatSnap.shown = true, true, 0
            combatSnap.target, combatSnap.casts, combatSnap.castSecret = nil, 0, nil
            combatSnap.usable = nil
            procSeen = 0
        end
        combatSnap.hp = c.hpKnown
        combatSnap.power = Pub(UnitPower("player")) ~= nil
        combatSnap.auraP, combatSnap.auraT = auraSecret.player, auraSecret.target
        if c.target then combatSnap.target = not c.hostileSecret end
        if c.cast then
            combatSnap.casts = combatSnap.casts + 1
            combatSnap.castSecret = (c.cast.name == "feitico do inimigo")
        end
        if combatSnap.usable == nil then
            for _, rule in ipairs(rules) do
                local k = rule.pick[1]
                if k and Known(k) then
                    combatSnap.usable = SpellUsable(N[k]) ~= nil
                    local _, _, act = SpellCooldown(N[k])
                    combatSnap.cd = act ~= nil
                    break
                end
            end
        end
    else
        combatSnap.active = false
    end
    if DB.combatOnly and not c.inCombat then HideSuggestion(); return end
    local rule, key, unit = Evaluate()
    if not rule then HideSuggestion(); return end
    if c.inCombat and key ~= current then combatSnap.shown = combatSnap.shown + 1 end
    local text = rule.msg
    if type(text) == "function" then text = text(c, unit) end
    local spell = N[key] or ""
    ShowSuggestion(key, rule.cat, (text and text ~= "" and (text .. "\n|cffaaaaaa" .. spell .. "|r")) or spell)
end

-- Rede de seguranca: se alguma API nova devolver algo inesperado, o addon so
-- esconde o icone neste ciclo em vez de gerar erro de Lua a cada 0,1s.
local lastError
local function Update()
    if not DB or not DB.enabled then hud:Hide(); cast:Hide(); banner:Hide(); return end
    if GetTime() < testUntil then return end
    local ok, err = pcall(DoUpdate)
    if not ok then
        lastError = err
        hud:Hide()
    end
    -- painel de cast e aviso de encontro sao independentes: um erro num nao derruba o outro
    local ok2, err2 = pcall(CastTick)
    if not ok2 then lastError = err2; cast:Hide() end
    BannerTick()
end

---------------------------------------------------------------------------
-- 10. EVENTOS E COMANDOS
---------------------------------------------------------------------------
-- O log de combate (COMBAT_LOG_EVENT_UNFILTERED) NAO e usado: no Forever ele e
-- proibido para addons e gera o aviso "so disponivel para a interface da Blizzard".
local core = CreateFrame("Frame")
local elapsed = 0

core:SetScript("OnUpdate", function(_, dt)
    elapsed = elapsed + dt
    if elapsed >= UPDATE_INTERVAL then
        elapsed = 0
        Update()
    end
end)

local function RefreshSpells()
    ResolveNames()
    ScanSpellbook()
    ResolveRankIDs()
    RebuildKeyCache()
end

core:RegisterEvent("ADDON_LOADED")
core:RegisterEvent("PLAYER_LOGIN")
local function EventValid(e)
    if not (C_EventUtils and C_EventUtils.IsEventValid) then return true end
    local ok, v = pcall(C_EventUtils.IsEventValid, e)
    return (not ok) or v == true
end

core:SetScript("OnEvent", function(_, event, arg1, arg2, arg3)
    if event == "ADDON_LOADED" then
        if arg1 ~= ADDON_NAME then return end
        MVAT_DB = MVAT_DB or {}
        for k, v in pairs(DEFAULTS) do if MVAT_DB[k] == nil then MVAT_DB[k] = v end end
        DB = MVAT_DB
        core:UnregisterEvent("ADDON_LOADED")
    elseif event == "PLAYER_LOGIN" then
        ApplyLayout()
        RefreshSpells()
        pcall(RefreshGear)
        LoadClassRules()
        for _, e in ipairs({ "SPELLS_CHANGED", "LEARNED_SPELL_IN_TAB", "PLAYER_LEVEL_UP", "CHARACTER_POINTS_CHANGED",
                             "ACTIONBAR_SLOT_CHANGED", "UPDATE_BINDINGS", "UPDATE_SHAPESHIFT_FORM",
                             "UPDATE_BONUS_ACTIONBAR", "PLAYER_TARGET_CHANGED", "PLAYER_EQUIPMENT_CHANGED" }) do
            if not C_EventUtils or not C_EventUtils.IsEventValid or C_EventUtils.IsEventValid(e) then
                core:RegisterEvent(e)
            end
        end
        -- casts apenas do alvo atual (reacao instantanea a interrupts)
        for _, e in ipairs({ "UNIT_SPELLCAST_START", "UNIT_SPELLCAST_CHANNEL_START", "UNIT_SPELLCAST_STOP",
                             "UNIT_SPELLCAST_CHANNEL_STOP", "UNIT_SPELLCAST_INTERRUPTED" }) do
            if EventValid(e) then core:RegisterUnitEvent(e, "target") end
        end
        -- os SEUS casts (alimentam os combos "usei A -> use B")
        if EventValid("UNIT_SPELLCAST_SUCCEEDED") then core:RegisterUnitEvent("UNIT_SPELLCAST_SUCCEEDED", "player") end
        -- sistema de encontro da Blizzard (aviso do chefe): so se o cliente o enviar
        encState.valid = EventValid("ENCOUNTER_WARNING")
        encState.validTimeline = EventValid("ENCOUNTER_TIMELINE_EVENT_ADDED")
        if encState.valid then pcall(core.RegisterEvent, core, "ENCOUNTER_WARNING") end
        if encState.validTimeline then pcall(core.RegisterEvent, core, "ENCOUNTER_TIMELINE_EVENT_ADDED") end
        -- brilho de proc da Blizzard
        for _, e in ipairs({ "SPELL_ACTIVATION_OVERLAY_GLOW_SHOW", "SPELL_ACTIVATION_OVERLAY_GLOW_HIDE" }) do
            if not C_EventUtils or not C_EventUtils.IsEventValid or C_EventUtils.IsEventValid(e) then
                core:RegisterEvent(e)
            end
        end
        print("|cff33ccffMVAT|r carregado para " .. (UnitClass("player")) .. ". Digite |cffffff00/mvat|r para opcoes.")
    elseif event == "SPELLS_CHANGED" or event == "LEARNED_SPELL_IN_TAB" or event == "PLAYER_LEVEL_UP"
        or event == "CHARACTER_POINTS_CHANGED" then
        RefreshSpells()
        LoadClassRules()
    elseif event == "ACTIONBAR_SLOT_CHANGED" or event == "UPDATE_BINDINGS"
        or event == "UPDATE_SHAPESHIFT_FORM" or event == "UPDATE_BONUS_ACTIONBAR" then
        RebuildKeyCache()
    elseif event == "SPELL_ACTIVATION_OVERLAY_GLOW_SHOW" or event == "SPELL_ACTIVATION_OVERLAY_GLOW_HIDE" then
        local sid = Pub(arg1)
        if type(sid) == "number" then
            if event == "SPELL_ACTIVATION_OVERLAY_GLOW_SHOW" then
                glowing[sid] = true
                if UnitAffectingCombat("player") then procSeen = procSeen + 1 end
            else
                glowing[sid] = nil
            end
        end
        elapsed = UPDATE_INTERVAL
    elseif event == "UNIT_SPELLCAST_SUCCEEDED" then
        if arg1 == "player" then
            OnPlayerCast(arg3)
            elapsed = UPDATE_INTERVAL
        end
    elseif event == "ENCOUNTER_WARNING" then
        local ok, err = pcall(ShowEncounterWarning, arg1)
        if not ok then lastError = err end
    elseif event == "ENCOUNTER_TIMELINE_EVENT_ADDED" then
        encState.timeline = encState.timeline + 1
    elseif event == "PLAYER_EQUIPMENT_CHANGED" then
        pcall(RefreshGear)
        elapsed = UPDATE_INTERVAL
    elseif event == "PLAYER_TARGET_CHANGED" or event:find("^UNIT_SPELLCAST_") then
        if event == "PLAYER_TARGET_CHANGED" then wipe(tcache); wipe(lastCast.at); lastCast.cp = 0 end -- tipo/classe do alvo anterior nao vale mais
        elapsed = UPDATE_INTERVAL -- reavalia imediatamente
    end
end)

local function Msg(text) print("|cff33ccffMVAT|r " .. text) end

local function Slash(input)
    local cmd, arg = (input or ""):lower():match("^(%S*)%s*(.-)$")
    if cmd == "unlock" or cmd == "destravar" then
        DB.locked = false; ApplyLayout(); HideSuggestion(); Msg("Destravado: arraste o icone. Use /mvat lock para travar.")
    elseif cmd == "lock" or cmd == "travar" then
        DB.locked = true; ApplyLayout(); hud:Hide(); Msg("Travado e posicao salva.")
    elseif cmd == "" then
        DB.locked = not DB.locked; ApplyLayout()
        if DB.locked then hud:Hide() else HideSuggestion() end
        Msg(DB.locked and "Travado." or "Destravado: arraste o icone.")
        Msg("Comandos: lock | unlock | scale <0.5-3> | aoe <n> | combat | text | test | reset | on | off")
    elseif cmd == "scale" or cmd == "escala" then
        local v = tonumber(arg)
        if v and v >= 0.5 and v <= 3 then DB.scale = v; ApplyLayout(); Msg("Escala: " .. v)
        else Msg("Use: /mvat scale 1.2  (entre 0.5 e 3)") end
    elseif cmd == "aoe" or cmd == "area" then
        local v = tonumber(arg)
        if v and v >= 2 and v <= 10 then DB.aoe = math.floor(v); Msg("Modo area a partir de " .. DB.aoe .. " inimigos.")
        else Msg("Use: /mvat aoe 3  (entre 2 e 10)") end
    elseif cmd == "combat" or cmd == "combate" then
        DB.combatOnly = not DB.combatOnly; Msg(DB.combatOnly and "Mostrando so em combate." or "Mostrando tambem fora de combate (buffs).")
    elseif cmd == "text" or cmd == "texto" then
        DB.showText = not DB.showText; ApplyLayout(); Msg(DB.showText and "Texto de motivo ligado." or "Texto de motivo desligado.")
    elseif cmd == "reset" then
        for k, v in pairs(DEFAULTS) do DB[k] = v end
        ApplyLayout(); Msg("Posicao e opcoes restauradas.")
    elseif cmd == "on" then DB.enabled = true; Msg("Ativado.")
    elseif cmd == "off" then DB.enabled = false; hud:Hide(); Msg("Desativado.")
    elseif cmd == "test" or cmd == "teste" then
        local key
        for k in pairs(ID) do if Known(k) then key = k; break end end
        if key then
            testUntil = GetTime() + 5
            ShowSuggestion(key, "COMBO", "Teste do HUD (5s)\n|cffaaaaaa" .. N[key] .. "|r")
        else Msg("Nenhuma habilidade conhecida encontrada.") end
    elseif cmd == "selo" or cmd == "seal" then
        if playerClass ~= "PALADIN" then Msg("O comando de selo e so do Paladino."); return end
        local want = SEAL_PREF[arg]
        if arg == "" then
            Msg("Selo: " .. tostring(DB.seal) .. ". Use /mvat selo auto | retidao | furia | cruzado | comando | luz | sabedoria | justica")
        elseif not want then
            Msg("Nao conheco o selo '" .. arg .. "'. Use: auto, retidao, furia, cruzado, comando, luz, sabedoria, justica")
        else
            DB.seal = (want == "auto") and "auto" or arg
            Msg(want == "auto" and "Selo AUTOMATICO: o addon escolhe pelo alvo, arma e escudo."
                or ("Selo fixado em " .. (N[want] or arg) .. "."))
        end
    elseif cmd == "barra" or cmd == "bar" then
        DB.barOnly = not DB.barOnly
        Msg(DB.barOnly and ("So sugere habilidades que estao nas suas barras (" .. barCount .. " encontradas).")
            or "Sugere qualquer habilidade que voce ja aprendeu, mesmo fora das barras.")
    elseif cmd == "debug" then
        local count = 0
        for _, rule in ipairs(rules) do for _, k in ipairs(rule.pick) do if Known(k) then count = count + 1 end end end
        Msg(string.format("Classe %s | %d regras | %d habilidades aprendidas usadas | inimigos %s",
            tostring(playerClass), #rules, count, tostring(c.enemies)))
        Msg(string.format("Barras: %d habilidades (filtro %s) | arma: %s, %.1fs | escudo: %s",
            barCount, DB.barOnly and "LIGADO" or "desligado", gear.twoHand and "duas maos" or "uma mao", gear.speed,
            gear.shield and "sim" or "nao"))
        if playerClass == "PALADIN" and paladin.choose then
            local have = {}
            for _, k in ipairs(SEAL_KEYS) do if Known(k) then have[#have + 1] = (N[k] or k) .. (OnBar(N[k]) and "" or " (fora da barra)") end end
            Msg("Selos que voce tem: " .. (#have > 0 and table.concat(have, ", ") or "nenhum"))
            local k, why = paladin.choose(c)
            Msg("Selo escolhido: " .. (k and ((N[k] or k) .. " - " .. why) or "nenhum disponivel") .. " | modo tanque: " .. tostring(paladin.tankMode() and true or false))
            local left = paladin.sealLeft()
            Msg("Selo ativo: " .. (sealState.key and (N[sealState.key] or sealState.key) or "nenhum") .. (left and string.format(" (%ds)", math.floor(left)) or ""))
        end
    elseif cmd == "diag" then
        local function yn(v) return v and "|cffff5555SECRETO|r" or "|cff55ff55liberado|r" end
        local function should(fn)
            if not (C_Secrets and C_Secrets[fn]) then return "n/d" end
            local ok, v = pcall(C_Secrets[fn])
            if not ok or issecret(v) then return "?" end
            return tostring(v)
        end
        local _, build, _, iface = GetBuildInfo()
        Msg("Diagnostico (build " .. tostring(build) .. ", interface " .. tostring(iface) .. ")")
        Msg("Agora: auras=" .. should("ShouldAurasBeSecret") .. " recargas=" .. should("ShouldCooldownsBeSecret")
            .. " | leitura de auras " .. yn(AurasRestricted()))
        if combatSnap.seen then
            Msg("Ultimo combate: vida " .. yn(not combatSnap.hp) .. " | recurso " .. yn(not combatSnap.power)
                .. " | auras proprias " .. yn(combatSnap.auraP) .. " | auras do alvo " .. yn(combatSnap.auraT))
            local function known3(v) if v == nil then return "nao medido" end return yn(not v) end
            Msg("Alvo inimigo " .. known3(combatSnap.target) .. " | habilidade usavel " .. known3(combatSnap.usable)
                .. " | cast do alvo detectado: " .. (combatSnap.casts > 0 and "sim" or "nao")
                .. (combatSnap.casts > 0 and (" (nome " .. yn(combatSnap.castSecret) .. ")") or ""))
            Msg("Recarga (isActive) " .. known3(combatSnap.cd)
                .. " | procs (brilho da Blizzard): " .. procSeen
                .. " | sugestoes mostradas: " .. combatSnap.shown)
        else
            Msg("Entre em combate uma vez e rode /mvat diag de novo.")
        end
        if castState.count > 0 then
            Msg("Painel de cast: " .. castState.count .. " casts vistos | nome " .. yn(not castState.nameReadable)
                .. " | interrompivel " .. yn(not castState.intReadable)
                .. " | cast em voce " .. yn(not castState.meReadable))
        else
            Msg("Painel de cast: nenhum cast de inimigo visto (teste com um mob que lance feitico)")
        end
        Msg("Seus casts: " .. castSeen .. " eventos, " .. castReadable .. " legiveis | combos por sequencia "
            .. (castReadable > 0 and "|cff55ff55ATIVOS|r" or "|cffff5555sem dados|r"))
        Msg("Encontro: ENCOUNTER_WARNING " .. (encState.valid and "existe" or "nao existe")
            .. " (" .. encState.warning .. " recebidos) | timeline " .. (encState.validTimeline and "existe" or "nao existe")
            .. " (" .. encState.timeline .. " eventos)")
        Msg("Ultimo erro capturado: " .. (lastError and tostring(lastError) or "nenhum"))
        lastError = nil -- o proximo diag mostra so erros novos
    else
        Msg("Comandos: lock | unlock | scale <0.5-3> | aoe <n> | combat | text | barra | selo | test | reset | on | off | debug | diag")
    end
end

SLASH_MVAT1, SLASH_MVAT2 = "/mvat", "/tutor"
SlashCmdList.MVAT = Slash
