if not SetAutoloot then
  StaticPopupDialogs["NO_SUPERWOW_ALogger"] = {
    text = "|cffffff00Advanced Logger|r requires SuperWoW to operate.",
    button1 = TEXT(OKAY),
    timeout = 0,
    whileDead = 1,
    hideOnEscape = 1,
		showAlert = 1,
  }

  StaticPopup_Show("NO_SUPERWOW_ALogger")
  return
end

local _G = _G or getfenv(0)

local marks = { "Star", "Circle", "Diamond", "Triangle", "Moon", "Square", "Cross", "Skull" }

-- todo, obviate the xml
local ALogger = CreateFrame("FRAME")
ALogger.VERSION = 20
ALogger.MAX_MESSAGE_LENGTH = 500
ALogger.CONSOLIDATE_CHARACTER = "{"
ALogger.MESSAGE_PREFIX = "ALogger_HELPER_"

ALogger.PlayerInformation = {}
ALogger.Synchronizers = {}
ALogger.LoggedCombatantInfo = {}
ALogger.mob_list = {}

-- capture global functions as local to reduce lua global table lookups
local tinsert = table.insert
local UnitName = UnitName
local strsub = string.sub
local GetNumSavedInstances = GetNumSavedInstances
local GetSavedInstanceInfo = GetSavedInstanceInfo
local IsInInstance = IsInInstance
local pairs = pairs
local GetNumPartyMembers = GetNumPartyMembers
local GetNumRaidMembers = GetNumRaidMembers
local UnitIsPlayer = UnitIsPlayer
local UnitSex = UnitSex
local strlower = strlower
local GetGuildInfo = GetGuildInfo
local GetInventoryItemLink = GetInventoryItemLink
local strfind = string.find
local Unknown = UNKNOWN
local LoggingCombat = LoggingCombat
local CombatLogAdd = CombatLogAdd
local SpellInfo = SpellInfo
local format = format
local time = time
local GetRealZoneText = GetRealZoneText
local date = date
local strjoin = string.join or function(delim, ...)
	if type(arg) == 'table' then
		return table.concat(arg, delim)
	else
		return delim
	end
end

-- cache what we've seen, SpellInfo (while fairly speedy) is _5x_ slower than keeping a table
local spellCache = {}
local current_zone = nil

local mark_cache = {}

-- some mobs have a 'target' but their spell cast doesn't mention one, we add them ourselves
local specials = nil
local specials_data = {
	["Blackwing Lair"] = {
		[22539] = "Shadow Flame", -- firemaw/ebonroc/flamegor/nefarian
		[23308] = "Incinerate", -- chromag
		[23310] = "Time Lapse", -- chromag
		[23313] = "Corrosive Acid", -- chromag
		[23315] = "Ignite Flesh", -- chromag
		[23187] = "Frost Burn", -- chromag
		[22334] = "Bomb" -- techies
		-- [23461] = "Flame Breath", -- vael
	},
	["Onyxia's Lair"] = {
		[18435] = "Flame Breath", -- onyxia
	}
	-- ["Tower of Karazhan"] = {
		-- gnarlmoon lunar shift
	-- }
}

ALogger:RegisterEvent("RAID_ROSTER_UPDATE")
ALogger:RegisterEvent("PARTY_MEMBERS_CHANGED")

ALogger:RegisterEvent("ZONE_CHANGED_NEW_AREA")
ALogger:RegisterEvent("UPDATE_INSTANCE_INFO")

ALogger:RegisterEvent("PLAYER_ENTERING_WORLD")
-- ALogger:RegisterEvent("PLAYER_REGEN_DISABLED")
-- ALogger:RegisterEvent("PLAYER_REGEN_ENABLED")

ALogger:RegisterEvent("RAID_TARGET_UPDATE")

ALogger:RegisterEvent("UNIT_PET")
ALogger:RegisterEvent("PLAYER_PET_CHANGED")
ALogger:RegisterEvent("PET_STABLE_CLOSED")

ALogger:RegisterEvent("CHAT_MSG_LOOT")
ALogger:RegisterEvent("CHAT_MSG_SYSTEM")

ALogger:RegisterEvent("UNIT_INVENTORY_CHANGED")

ALogger:SetScript("OnEvent", function () return ALogger[event](ALogger,arg1,arg2,arg3,arg4,arg5,arg6,arg7,arg8,arg9) end)

-- todo change this to only grab from people in-raid/party, and only when not in combat?
function ALogger:UNIT_INVENTORY_CHANGED(unit)
	if self.inCombat then return end -- don't care about weapon swaps
	self:grab_unit_information(unit)
end

function ALogger:PLAYER_REGEN_ENABLED()
	self.inCombat = false
	self.mob_list = {}
end

-- this is verbose but prevents allocating runtime strings each call
local fmt_with_rank_target = "%s %s %s(%s)(%s) on %s."
local fmt_with_rank = "%s %s %s(%s)(%s)."
local fmt_with_target = "%s %s %s(%s) on %s."
local fmt_simple = "%s %s %s(%s)."
local fmt_raw_with_rank_target = "%s(%s) %s %s(%s)(%s) on %s(%s)."
local fmt_raw_with_rank = "%s(%s) %s %s(%s)(%s)."
local fmt_raw_with_target = "%s(%s) %s %s(%s) on %s(%s)."
local fmt_raw_simple = "%s(%s) %s %s(%s)."

-- todo, remove specail case for items, who cares, it's all spells
function ALogger:UNIT_CASTEVENT(caster, target, event, spellID, castDuration)
	if not (caster and spellID) then return end
	if event == "MAINHAND" or event == "OFFHAND" then return end

	-- cache lookup
	local cachedSpell = spellCache[spellID]
	local spell = cachedSpell and cachedSpell[1]
	local rank = cachedSpell and cachedSpell[2]

	if not spell then
		-- Spell not cached yet? Call SpellInfo and cache the result.
		spell,rank = SpellInfo(spellID)
		if spell then
			-- only cache Rank for things that have one. Some items have joke ranks!
			rank = string.find(rank, "^Rank") and rank or ""
			spellCache[spellID] = { spell, rank }
		end
	end

	if not spell then return end

	local targetName -- = UnitName(target) or "Unknown"
	local casterName = UnitName(caster) or "Unknown"
	if specials and specials[spellID] then
		targetName = UnitName(caster.."target")
	elseif target and target ~= "" then
		targetName = UnitName(target) or "Unknown"
	-- else
		-- local t = UnitName(caster.."target")
		-- targetName = t and (t.."(via targeting)")
	end
	
	local verb
	if consume then
		verb = "uses"
	elseif event == "START" then
		verb = "begins to cast"
	elseif event == "FAIL" then
		verb = "fails casting"
	elseif event == "CHANNEL" then
		verb = "channels"
	else -- event == "CAST"
		verb = "casts"
	end
	
	local has_mark_caster = mark_cache[caster]
	local has_mark_target = mark_cache[target]
	if has_mark_caster then casterName = casterName .."(" .. marks[has_mark_caster] .. ")" end

	if targetName then
		if has_mark_target then targetName = targetName .."(" .. marks[has_mark_target] .. ")" end
		if rank ~= "" then
			CombatLogAdd(format(fmt_with_rank_target, casterName, verb, spell, spellID, rank, targetName))
			CombatLogAdd(format(fmt_raw_with_rank_target, caster, casterName, verb, spell, spellID, rank, target, targetName), 1)
		else
			CombatLogAdd(format(fmt_with_target, casterName, verb, spell, spellID, targetName))
			CombatLogAdd(format(fmt_raw_with_target, caster, casterName, verb, spell, spellID, target, targetName), 1)
		end
	else
		if rank ~= "" then
			CombatLogAdd(format(fmt_with_rank, casterName, verb, spell, spellID, rank))
			CombatLogAdd(format(fmt_raw_with_rank, caster, casterName, verb, spell, spellID, rank), 1)
		else
			CombatLogAdd(format(fmt_simple, casterName, verb, spell, spellID))
			CombatLogAdd(format(fmt_raw_simple, caster, casterName, verb, spell, spellID), 1)
		end
	end
end

function ALogger:RegisterSpellData(forced)
	local zone = GetRealZoneText()
	specials = specials_data[zone]
	if IsInInstance("player") or forced then
		LoggingCombat(1)
		self:RegisterEvent("UNIT_CASTEVENT")
		self:RegisterEvent("UNIT_MODEL_CHANGED")
		self:RegisterEvent("CHAT_MSG_MONSTER_SAY")
		self:RegisterEvent("CHAT_MSG_MONSTER_YELL")
		self:RegisterEvent("CHAT_MSG_MONSTER_EMOTE")
		self:RegisterEvent("CHAT_MSG_MONSTER_WHISPER")
		self:RegisterEvent("CHAT_MSG_RAID_BOSS_EMOTE")
		self:RegisterEvent("CHAT_MSG_RAID_BOSS_WHISPER")
		self:RegisterEvent("UNIT_FLAGS")
	else
		LoggingCombat(nil)
		self:UnregisterEvent("UNIT_CASTEVENT")
		self:UnregisterEvent("UNIT_MODEL_CHANGED")
		self:UnregisterEvent("CHAT_MSG_MONSTER_SAY")
		self:UnregisterEvent("CHAT_MSG_MONSTER_YELL")
		self:UnregisterEvent("CHAT_MSG_MONSTER_EMOTE")
		self:UnregisterEvent("CHAT_MSG_MONSTER_WHISPER")
		self:UnregisterEvent("CHAT_MSG_RAID_BOSS_EMOTE")
		self:UnregisterEvent("CHAT_MSG_RAID_BOSS_WHISPER")
		self:UnregisterEvent("UNIT_FLAGS")
	end
end

local function get_mark_str(guid)
	local mark = mark_cache and mark_cache[guid]
	return mark and ("(" .. marks[mark] .. ")") or ""
end

local function get_unit_display(guid)
	if not guid then return "unknown" end
	local name = UnitName(guid) or "unknown"
	local mark_str = get_mark_str(guid)
	return format("%s(%s)%s", name, guid, mark_str)
end

local function get_owner_display(guid)
	local _,owner_guid = UnitExists(guid .. "owner")
	if owner_guid then
			local owner_name = UnitName(owner_guid) or "unknown"
			return format(" owner %s(%s)%s", owner_name, owner_guid, get_mark_str(owner_guid))
	end
	return ""
end

function ALogger:UNIT_FLAGS(guid)
	if string.sub(guid, 3, 3) ~= "F" then return end -- only track mob guids

	-- Aggroed for the first time
	if not ALogger.mob_list[guid] and UnitAffectingCombat(guid) and UnitCanAttack("player", guid) then
			ALogger.mob_list[guid] = true

			local mob_disp = get_unit_display(guid) .. get_owner_display(guid)
			local _,target_guid = UnitExists(guid .. "target")
			local target_disp = target_guid and (get_unit_display(target_guid) .. get_owner_display(target_guid)) or "no_target"

			CombatLogAdd("AGGRO: " .. mob_disp .. " aggro " .. target_disp)
			CombatLogAdd("AGGRO: " .. mob_disp .. " aggro " .. target_disp, 1)
			return
	end

	-- Combat ended
	if ALogger.mob_list[guid] and not UnitAffectingCombat(guid) then
			ALogger.mob_list[guid] = nil
			return
	end
end

-- addons can cause rapid mark reapplication
function ALogger:RAID_TARGET_UPDATE()
	local new_cache = {}
	for i=1,8 do
		local _,guid = UnitExists("mark"..i)
		if guid then
			local had_mark = mark_cache[guid]
			if had_mark ~= i then
				if had_mark and not UnitIsDead(guid) then -- was this living unit previously marked?
					CombatLogAdd(format("MARK: %s(%s) is %s was %s", UnitName(guid), guid, marks[i], marks[had_mark]))
					CombatLogAdd(format("MARK: %s(%s) is %s was %s", UnitName(guid), guid, marks[i], marks[had_mark]), 1)
				else
					CombatLogAdd(format("MARK: %s(%s) is %s", UnitName(guid), guid, marks[i]))
					CombatLogAdd(format("MARK: %s(%s) is %s", UnitName(guid), guid, marks[i]), 1)
				end
			end
			new_cache[guid] = i
		end
	end
	mark_cache = new_cache
end

function ALogger:UNIT_MODEL_CHANGED(guid)
	if string.sub(guid,3,3) ~= "F" then return end -- only track mob guids
	local name = UnitName(guid)
	CombatLogAdd(format("MODEL_UPDATE: %s(%s)", name, guid))
	CombatLogAdd(format("MODEL_UPDATE: %s(%s)", name, guid), 1)
end

function ALogger:CHAT_MSG_MONSTER_SAY(msg,from)
	CombatLogAdd(format("CHAT_MSG: %s&%s&%s","CHAT_MSG_MONSTER_SAY",from,msg))
	CombatLogAdd(format("CHAT_MSG: %s&%s&%s","CHAT_MSG_MONSTER_SAY",from,msg),1)
end
function ALogger:CHAT_MSG_MONSTER_YELL(msg,from)
	CombatLogAdd(format("CHAT_MSG: %s&%s&%s","CHAT_MSG_MONSTER_YELL",from,msg))
	CombatLogAdd(format("CHAT_MSG: %s&%s&%s","CHAT_MSG_MONSTER_YELL",from,msg),1)
end
function ALogger:CHAT_MSG_MONSTER_EMOTE(msg,from)
	CombatLogAdd(format("CHAT_MSG: %s&%s&%s","CHAT_MSG_MONSTER_EMOTE",from,msg))
	CombatLogAdd(format("CHAT_MSG: %s&%s&%s","CHAT_MSG_MONSTER_EMOTE",from,msg),1)
end
function ALogger:CHAT_MSG_MONSTER_WHISPER(msg,from)
	CombatLogAdd(format("CHAT_MSG: %s&%s&%s","CHAT_MSG_MONSTER_WHISPER",from,msg))
	CombatLogAdd(format("CHAT_MSG: %s&%s&%s","CHAT_MSG_MONSTER_WHISPER",from,msg),1)
end

function ALogger:CHAT_MSG_RAID_BOSS_EMOTE(msg,from)
	CombatLogAdd(format("CHAT_MSG: %s&%s&%s","CHAT_MSG_RAID_BOSS_EMOTE",from,msg))
	CombatLogAdd(format("CHAT_MSG: %s&%s&%s","CHAT_MSG_RAID_BOSS_EMOTE",from,msg),1)
end
function ALogger:CHAT_MSG_RAID_BOSS_WHISPER(msg,from)
	CombatLogAdd(format("CHAT_MSG: %s&%s&%s","CHAT_MSG_RAID_BOSS_WHISPER",from,msg))
	CombatLogAdd(format("CHAT_MSG: %s&%s&%s","CHAT_MSG_RAID_BOSS_WHISPER",from,msg),1)
end

local ran_once = false
function ALogger:ZONE_CHANGED_NEW_AREA()
	self:RegisterSpellData()
	-- LoggingCombat(IsInInstance("player"))
	self:grab_unit_information("player")
	self:RAID_ROSTER_UPDATE()
	self:PARTY_MEMBERS_CHANGED()
	self:QueueRaidIds()
	self.mob_list = {}

	self:RAID_TARGET_UPDATE() -- to catch from instance enter and from login

	if IsInInstance() or not ran_once then
		for _,r in pairs(self.LoggedCombatantInfo) do
			CombatLogAdd(r)
			CombatLogAdd(r,1)
		end
		ran_once = true
	end
end

function ALogger:UPDATE_INSTANCE_INFO()
	self:RegisterSpellData()
	-- LoggingCombat(IsInInstance("player"))
	self:grab_unit_information("player")
	self:RAID_ROSTER_UPDATE()
	self:PARTY_MEMBERS_CHANGED()
	self:QueueRaidIds()
end

local initialized = false
function ALogger:PLAYER_ENTERING_WORLD()
	self:RegisterSpellData()

	self.inCombat = UnitAffectingCombat("player")

	if initialized then
		return
	end
	initialized = true
	--[[
	4/4 18:04:50.322  You crit 0xF13000035A009809 for 168.
4/4 18:04:50.997  0x0000000000186B75(Ehawne) casts Earth Shock(10414)(Rank 7) on 0xF13000035A009809(Sorrow Spinner).
4/4 18:04:51.002  Your Earth Shock hits 0xF13000035A009809 for 540 Nature damage.
4/4 18:04:51.002  You have slain 0xF13000035A009809!
can this be AURAADDEDOTHERHELPFUL'd to add names?
	--]]

	-- VSABSORBOTHEROTHER = "%s attacks. %s absorbs all the damage.";
	-- VSABSORBOTHERSELF = "%s attacks. You absorb all the damage.";
	-- VSABSORBSELFOTHER = "You attack. %s absorbs all the damage.";
	-- VSBLOCKOTHEROTHER = "%s attacks. %s blocks.";
	-- VSBLOCKOTHERSELF = "%s attacks. You block.";
	-- VSBLOCKSELFOTHER = "You attack. %s blocks.";
	-- VSDEFLECTOTHEROTHER = "%s attacks. %s deflects.";
	-- VSDEFLECTOTHERSELF = "%s attacks. You deflect.";
	-- VSDEFLECTSELFOTHER = "You attack. %s deflects.";
	-- VSDODGEOTHEROTHER = "%s attacks. %s dodges.";
	-- VSDODGEOTHERSELF = "%s attacks. You dodge.";
	-- VSDODGESELFOTHER = "You attack. %s dodges.";
	-- VSENVIRONMENTALDAMAGE_DROWNING_OTHER = "%s is drowning and loses %d health.";
	-- VSENVIRONMENTALDAMAGE_DROWNING_SELF = "You are drowning and lose %d health.";
	-- VSENVIRONMENTALDAMAGE_FALLING_OTHER = "%s falls and loses %d health.";
	-- VSENVIRONMENTALDAMAGE_FALLING_SELF = "You fall and lose %d health.";
	-- VSENVIRONMENTALDAMAGE_FATIGUE_OTHER = "%s is exhausted and loses %d health.";
	-- VSENVIRONMENTALDAMAGE_FATIGUE_SELF = "You are exhausted and lose %d health.";
	-- VSENVIRONMENTALDAMAGE_FIRE_OTHER = "%s suffers %d points of fire damage.";
	-- VSENVIRONMENTALDAMAGE_FIRE_SELF = "You suffer %d points of fire damage.";
	-- VSENVIRONMENTALDAMAGE_LAVA_OTHER = "%s loses %d health for swimming in lava.";
	-- VSENVIRONMENTALDAMAGE_LAVA_SELF = "You lose %d health for swimming in lava.";
	-- VSENVIRONMENTALDAMAGE_SLIME_OTHER = "%s loses %d health for swimming in slime.";
	-- VSENVIRONMENTALDAMAGE_SLIME_SELF = "You lose %d health for swimming in slime.";
	-- VSEVADEOTHEROTHER = "%s attacks. %s evades.";
	-- VSEVADEOTHERSELF = "%s attacks. You evade.";
	-- VSEVADESELFOTHER = "You attack. %s evades.";
	-- VSIMMUNEOTHEROTHER = "%s attacks but %s is immune.";
	-- VSIMMUNEOTHERSELF = "%s attacks but you are immune.";
	-- VSIMMUNESELFOTHER = "You attack but %s is immune.";
	-- VSPARRYOTHEROTHER = "%s attacks. %s parries.";
	-- VSPARRYOTHERSELF = "%s attacks. You parry.";
	-- VSPARRYSELFOTHER = "You attack. %s parries.";
	-- VSRESISTOTHEROTHER = "%s attacks. %s resists all the damage.";
	-- VSRESISTOTHERSELF = "%s attacks. You resist all the damage.";
	-- VSRESISTSELFOTHER = "You attack. %s resists all the damage.";
	-- -- VULNERABLE_TRAILER = " (+%d vulnerability bonus)";

	-- YOU_LOOT_MONEY = "You loot %s";
	-- LOOT_MONEY = "%s loots %s.";

	-- LOOT_ROLL_ALL_PASSED = "Everyone passed on: %s|Hitem:%d:%d:%d:%d|h[%s]|h%s";
	-- LOOT_ROLL_GREED = "%s has selected Greed for: %s|Hitem:%d:%d:%d:%d|h[%s]|h%s";
	-- LOOT_ROLL_GREED_SELF = "You have selected Greed for: %s|Hitem:%d:%d:%d:%d|h[%s]|h%s";
	-- LOOT_ROLL_NEED = "%s has selected Need for: %s|Hitem:%d:%d:%d:%d|h[%s]|h%s";
	-- LOOT_ROLL_NEED_SELF = "You have selected Need for: %s|Hitem:%d:%d:%d:%d|h[%s]|h%s";
	-- LOOT_ROLL_PASSED = "%s passed on: %s|Hitem:%d:%d:%d:%d|h[%s]|h%s";
	-- LOOT_ROLL_PASSED_SELF = "You passed on: %s|Hitem:%d:%d:%d:%d|h[%s]|h%s";
	-- LOOT_ROLL_ROLLED = "%s rolls a %d on: %s|Hitem:%d:%d:%d:%d|h[%s]|h%s";
	-- LOOT_ROLL_ROLLED_GREED = "Greed Roll - %d for %s|Hitem:%d:%d:%d:%d|h[%s]|h%s by %s";
	-- LOOT_ROLL_ROLLED_GREED_SELF = "You roll a %d (Greed) on: %s|Hitem:%d:%d:%d:%d|h[%s]|h%s";
	-- LOOT_ROLL_ROLLED_NEED = "Need Roll - %d for %s|Hitem:%d:%d:%d:%d|h[%s]|h%s by %s";
	-- LOOT_ROLL_ROLLED_NEED_SELF = "You roll a %d (Need) on: %s|Hitem:%d:%d:%d:%d|h[%s]|h%s";
	-- LOOT_ROLL_ROLLED_SELF = "You roll a %d on: %s|Hitem:%d:%d:%d:%d|h[%s]|h%s";
	-- LOOT_ROLL_START = "Rolling started on: %s|Hitem:%d:%d:%d:%d|h[%s]|h%s";
	-- LOOT_ROLL_WON = "%s won: %s|Hitem:%d:%d:%d:%d|h[%s]|h%s";
	-- LOOT_ROLL_WON_NO_SPAM_GREED = "%1$s won: %3$s|Hitem:%4$d:%5$d:%6$d:%7$d|h[%8$s]|h%9$s |cff818181(Greed - %2$d)|r";
	-- LOOT_ROLL_WON_NO_SPAM_NEED = "%1$s won: %3$s|Hitem:%4$d:%5$d:%6$d:%7$d|h[%8$s]|h%9$s |cff818181(Need - %2$d)|r";
	-- LOOT_ROLL_YOU_WON = "You won: %s|Hitem:%d:%d:%d:%d|h[%s]|h%s";
	-- LOOT_ROLL_YOU_WON_NO_SPAM_GREED = "You won: %2$s|Hitem:%3$d:%4$d:%5$d:%6$d|h[%7$s]|h%8$s |cff818181(Greed - %1$d)|r";
	-- LOOT_ROLL_YOU_WON_NO_SPAM_NEED = "You won: %2$s|Hitem:%3$d:%4$d:%5$d:%6$d|h[%7$s]|h%8$s |cff818181(Need - %1$d)|r";
	-- LOOT_ROUND_ROBIN = "Loot: Round robin";
	-- LOOT_THRESHOLD = "Loot Threshold";
	-- LOSING_LOYALTY = "Losing Loyalty";
	-- LOOT_ITEM_SELF = "You receive loot: %s.";
	-- LOOT_ITEM_SELF_MULTIPLE = "You receive loot: %sx%d.";

	-- add (1) for first stack of buffs/debuffs
	AURAADDEDOTHERHELPFUL = "%s gains %s (1)."
	AURAADDEDOTHERHARMFUL = "%s is afflicted by %s (1)."
	AURAADDEDSELFHARMFUL = "You are afflicted by %s (1)."
	AURAADDEDSELFHELPFUL = "You gain %s (1)."

	-- self.PlayerInformation = ALogger_PlayerInformation 
	self:grab_unit_information("player")
	self:RAID_ROSTER_UPDATE()
	self:PARTY_MEMBERS_CHANGED() -- todo, make arcane checker give reverse order and tag offlines as offline. also autorepeat the query on a timer
	self:RAID_TARGET_UPDATE() -- to catch after /rl
	self.mob_list = {}
end

local rcount = 0
function ALogger:RAID_ROSTER_UPDATE()
	local rnow = GetNumRaidMembers()
	if rnow <= rcount then -- don't update when people leave
		rcount = rnow
		return
	end
	for i = 1, rnow do
		local unit = "raid" .. i
		if UnitName(unit) then
			self:grab_unit_information(unit)
		end
	end
	rcount = rnow
end

local pcount = 0
function ALogger:PARTY_MEMBERS_CHANGED()
	local pnow = GetNumPartyMembers()
	if pnow <= pcount then -- don't update when people leave
		pcount = pnow
		return
	end
	for i = 1, pnow do
		local unit = "party" .. i
		if UnitName(unit) then
			self:grab_unit_information(unit)
		end
	end
	pcount = pnow
end

function ALogger:UNIT_PET(unit)
	if unit then
		self:grab_unit_information(unit)
	end
end

function ALogger:PLAYER_PET_CHANGED()
	self:grab_unit_information("player")
end

function ALogger:PET_STABLE_CLOSED()
	self:grab_unit_information("player")
end

-- todo: this misses too much
function ALogger:CHAT_MSG_LOOT(msg)
	-- if not self:ContainsSynchronizer(msg) then
		local r = "LOOT: " .. date("%d.%m.%y %H:%M:%S") .. "&" .. msg
		CombatLogAdd(r)
		CombatLogAdd(r, 1)
	-- end
end

function ALogger:CHAT_MSG_SYSTEM(msg)
	-- "Iseut trades item Libram of the Faithful to Milkpress."
	local trade = string.find(msg, "^%w+ trades item")
	if trade then
		local r = "LOOT_TRADE: " .. date("%d.%m.%y %H:%M:%S") .. "&" .. msg
		CombatLogAdd(r)
		CombatLogAdd(r, 1)
	end
end

function ALogger:ContainsSynchronizer(msg)
	for key, val in pairs(self.Synchronizers) do
		if strfind(msg, key) ~= nil then
			return true
		end
	end
	return false
end

function ALogger:QueueRaidIds()
	local zone = strlower(GetRealZoneText())
	local found = false
	for i = 1, GetNumSavedInstances() do
		local instance_name, instance_id = GetSavedInstanceInfo(i)
		if zone == strlower(instance_name) then
			-- CombatLogAdd("ZONE_INFO: " .. date("%d.%m.%y %H:%M:%S") .. "&" .. instance_name .. "&" .. instance_id)
			local r = "ZONE_INFO: " .. date("%d.%m.%y %H:%M:%S") .. "&" .. instance_name .. "&" .. instance_id
			CombatLogAdd(r)
			CombatLogAdd(r, 1)
			found = true
			break
		end
	end

	if found == false then
		local r = "ZONE_INFO: " .. date("%d.%m.%y %H:%M:%S") .. "&" .. zone .. "&0"
		CombatLogAdd(r)
		CombatLogAdd(r, 1)
	end
end

-- todo, tired of this not recording xmog gear id properly
function ALogger:grab_unit_information(unit)
	local unit_name = UnitName(unit)
	if UnitIsPlayer(unit) and unit_name ~= nil and unit_name ~= Unknown and not self:ContainsSynchronizer(unit_name) then
		if self.PlayerInformation[unit_name] == nil then
			self.PlayerInformation[unit_name] = {}
		end
		local info = self.PlayerInformation[unit_name]
		if info["last_update"] ~= nil and time() - info["last_update"] <= 30 then
			return
		end
		info["last_update_date"] = date("%d.%m.%y %H:%M:%S")
		info["last_update"] = time()
		info["name"] = unit_name

		-- Guild info
		local guildName, guildRankName, guildRankIndex = GetGuildInfo(unit)
		if guildName ~= nil then
			info["guild_name"] = guildName
			info["guild_rank_name"] = guildRankName
			info["guild_rank_index"] = guildRankIndex
		end

		-- Pet name
		if strfind(unit, "pet") == nil then
			local pet_name = nil
			if unit == "player" then
				pet_name = UnitName("pet")
			elseif strfind(unit, "raid") then
				pet_name = UnitName("raidpet" .. strsub(unit, 5))
			elseif strfind(unit, "party") then
				pet_name = UnitName("partypet" .. strsub(unit, 6))
			end

			if pet_name ~= nil and pet_name ~= Unknown and pet ~= "" then
				info["pet"] = pet_name
			end
		end

		-- Hero Class, race, sex
		if UnitClass(unit) ~= nil then
			local _, english_class = UnitClass(unit)
			info["hero_class"] = english_class
		end
		if UnitRace(unit) ~= nil then
			local _, en_race = UnitRace(unit)
			info["race"] = en_race
		end
		if UnitSex(unit) ~= nil then
			info["sex"] = UnitSex(unit)
		end

		-- Gear
		local any_item = false
		for i = 1, 19 do
			if GetInventoryItemLink(unit, i) ~= nil then
				any_item = true
				break
			end
		end

		if info["gear"] == nil then
			info["gear"] = {}
		end

		if any_item then
			info["gear"] = {}
			for i = 1, 19 do
				local inv_link = GetInventoryItemLink(unit, i)
				if inv_link == nil then
					info["gear"][i] = nil
				else
					local found, _, itemString = strfind(inv_link, "Hitem:(.+)\124h%[")
					if found == nil then
						info["gear"][i] = nil
					else
						info["gear"][i] = itemString
					end
				end
			end
		end

		-- Talents
		if unit == "player" then
			local talents = { "", "", "" };
			for t = 1, 3 do
				local numTalents = GetNumTalents(t);
				-- Last one is missing?
				for i = 1, numTalents do
					local _, _, _, _, currRank = GetTalentInfo(t, i);
					talents[t] = talents[t] .. currRank
				end
			end
			talents = strjoin("}", talents[1], talents[2], talents[3])
			if strlen(talents) <= 10 then
				talents = nil
			end

			if talents ~= nil then
				info["talents"] = talents
			end
		end

		log_combatant_info(info)
	end
end

function log_combatant_info(character)
	if character ~= nil then
		local num_nil_gear = 0
		if character["gear"][1] == nil then
			num_nil_gear = num_nil_gear + 1
		end

		local gear_str = prep_value(character["gear"][1])
		for i = 2, 19 do
			if character["gear"][i] == nil then
				num_nil_gear = num_nil_gear + 1
			end

			gear_str = gear_str .. "&" .. prep_value(character["gear"][i])
		end

		-- If all gear is nil, don't log
		if num_nil_gear == 19 then
			return
		end

		local result = prep_value(character["name"]) .. "&" .. prep_value(character["hero_class"]) .. "&" .. prep_value(character["race"]) .. "&" .. prep_value(character["sex"]) .. "&" .. prep_value(character["pet"]) .. "&" .. prep_value(character["guild_name"]) .. "&" .. prep_value(character["guild_rank_name"]) .. "&" .. prep_value(character["guild_rank_index"]) .. "&" .. gear_str .. "&" .. prep_value(character["talents"])

		if not ALogger.LoggedCombatantInfo[result] then
			local result_prefix = "COMBATANT_INFO: " .. prep_value(character["last_update_date"]) .. "&"
			local r = result_prefix .. result
			CombatLogAdd(r)
			CombatLogAdd(r,1)
			ALogger.LoggedCombatantInfo[result] = r
		end
	end
end

function prep_value(val)
	if val == nil then
		return "nil"
	end
	return val
end

function ALogger:SendMessage(msg)
	DEFAULT_CHAT_FRAME:AddMessage("|cFFFF8080LegacyPlayers|r: " .. msg)
end
