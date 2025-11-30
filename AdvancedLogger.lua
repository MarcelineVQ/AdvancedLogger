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
ALogger = CreateFrame("FRAME")
ALogger.VERSION = tonumber(GetAddOnMetadata("AdvancedLogger","Version")) or 0
ALogger.MAX_MESSAGE_LENGTH = 500

ALogger.PlayerInformation = {}
ALogger.Synchronizers = {}
ALogger.LoggedCombatantInfo = {}
ALogger.mob_list = {}
ALogger.TalentInfo = {}  -- Store other players' talents: [playerName] = { [tree] = "00503..." }
ALogger.TalentLastUpdate = {}  -- Track when we last got talents: [playerName] = timestamp
ALogger.InspectionQueue = {}  -- Queue of players to inspect: { name1, name2, ... }
ALogger.QueuedInspectionCount = 0  -- Number of active inspections
ALogger.CurrentInspectionTarget = nil  -- Currently inspecting this player
ALogger.LastInspectionRequest = 0  -- Timestamp of last inspection request
ALogger.TALENT_REFRESH_INTERVAL = 300  -- Re-check talents every 5 minutes (300 seconds)

-- Hook TWInspectTalents_Show to suppress the window during automated scans
local orig_TWInspectTalents_Show = TWInspectTalents_Show
TWInspectTalents_Show = function()
	-- If we're doing an automated scan, don't show the window
	if ALogger.QueuedInspectionCount > 0 then
		return
	end
	-- Otherwise, call the original function
	orig_TWInspectTalents_Show()
end

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
ALogger:RegisterEvent("CHAT_MSG_ADDON")

ALogger:RegisterEvent("UNIT_INVENTORY_CHANGED")
ALogger:RegisterEvent("UI_ERROR_MESSAGE")
ALogger:SetScript("OnEvent", function () return ALogger[event](ALogger,arg1,arg2,arg3,arg4,arg5,arg6,arg7,arg8,arg9) end)
ALogger:SetScript("OnUpdate", function() ALogger:OnUpdate() end)


-- todo change this to only grab from people in-raid/party, and only when not in combat?
function ALogger:UNIT_INVENTORY_CHANGED(unit)
	if not unit then return end
	if self.inCombat then return end -- don't care about weapon swaps
	-- only care about (p)arty, (p)layer, and (r)aid members
	if not (string.find(unit,"^p") or string.find(unit,"^r")) then return end
	self:grab_unit_information(unit)
end

function ALogger:UI_ERROR_MESSAGE(msg)
	-- Suppress "Unknown Unit" errors during automated talent scans
	if self.QueuedInspectionCount > 0 and msg and (string.find(msg, "^Unknown unit") or string.find(msg, "^You can't inspect")) then
		UIErrorsFrame:Clear()
	end
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

-- todo, remove special case for items, who cares, it's all spells
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

-- helper to easily force on for testing
function ALoggerForce()
	ALogger:RegisterSpellData(true)
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

	-- Preserve cache entries for units that still exist (prevents rapid reapplication spam)
	for guid, old_mark in pairs(mark_cache) do
		if not new_cache[guid] and UnitExists(guid) and not UnitIsDead(guid) then
			new_cache[guid] = old_mark  -- Keep in cache if unit still alive
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
		local name = UnitName(unit)
		if name then
			-- Queue talent inspection for new players (will be skipped if recently inspected)
			self:QueuePlayerInspection(unit)
			-- Grab equipment info immediately
			self:grab_unit_information(unit)
		end
	end
	rcount = rnow
	-- Queue processing handled by OnUpdate
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
		local name = UnitName(unit)
		if name then
			-- Queue inspection for party members to get talents
			self:QueuePlayerInspection(unit)
			self:grab_unit_information(unit)
		end
	end
	pcount = pnow
	-- Queue processing handled by OnUpdate
end

function ALogger:UNIT_PET(unit)
	if not unit then return end
	-- only care about (p)arty, (p)layer, and (r)aid members
	if not (string.find(unit,"^p") or string.find(unit,"^r")) then return end
	self:grab_unit_information(unit)
end

function ALogger:PLAYER_PET_CHANGED()
	self:grab_unit_information("player")
end

function ALogger:PET_STABLE_CLOSED()
	self:grab_unit_information("player")
end

-- todo: this misses too much, what can we do?
function ALogger:CHAT_MSG_LOOT(msg)
	local r = "LOOT: " .. date("%d.%m.%y %H:%M:%S") .. "&" .. msg
	CombatLogAdd(r)
	CombatLogAdd(r, 1)
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

-- Queue a player for inspection to collect talents and equipment
-- @param unit: Unit ID to inspect (e.g., "raid1", "party2")
-- @param force: Force inspection even if recently updated
function ALogger:QueuePlayerInspection(unit, force)
	if not unit then return end

	local playerName = UnitName(unit)
	if not playerName or UnitIsUnit(unit, "player") then return end

	-- Don't queue if already queued
	for _, queuedUnit in ipairs(self.InspectionQueue) do
		if UnitIsUnit(queuedUnit, unit) then
			return  -- Already queued
		end
	end

	-- Don't queue if recently inspected (unless forced)
	if not force and self.TalentLastUpdate[playerName] then
		local timeSinceUpdate = GetTime() - self.TalentLastUpdate[playerName]
		if timeSinceUpdate < self.TALENT_REFRESH_INTERVAL then
			return  -- Recently inspected
		end
	end

	tinsert(self.InspectionQueue, unit)
end

-- Trigger inspection for the next player in queue
function ALogger:ProcessInspectionQueue()
	if self.QueuedInspectionCount > 0 then
		return  -- Already inspecting someone
	end

	if table.getn(self.InspectionQueue) == 0 then
		return  -- Nothing to inspect
	end

	-- Get next player from queue
	local unit = table.remove(self.InspectionQueue, 1)
	local playerName = UnitName(unit)

	-- Skip if player not found or offline
	if not playerName or not UnitIsConnected(unit) then
		-- Player is offline or left raid/party, try next in queue
		self:ProcessInspectionQueue()
		return
	end

	-- Initialize talent storage for this player
	self.TalentInfo[playerName] = { "", "", "" }

	-- Track active inspection
	self.CurrentInspectionTarget = playerName
	self.QueuedInspectionCount = self.QueuedInspectionCount + 1

	-- Request talents directly via addon message (Turtle WoW inspection protocol)
	-- Format: SendAddonMessage("TW_CHAT_MSG_WHISPER<PlayerName>", "INSShowTalents", "GUILD")
	SendAddonMessage("TW_CHAT_MSG_WHISPER<"..playerName..">", "INSShowTalents", "GUILD")
	self.LastInspectionRequest = GetTime()
end

-- OnUpdate handler to check for inspection timeouts and periodic talent refreshes
local last_inspection_check = GetTime()
local last_talent_refresh_check = GetTime()
function ALogger:OnUpdate()
	local now = GetTime()

	-- Check for inspection timeout and process queue
	if now > last_inspection_check + 0.2 then
		last_inspection_check = now

		-- If someone isn't responding to talent query, reset after 3 seconds
		if self.QueuedInspectionCount > 0 and (now - self.LastInspectionRequest > 3) then
			self.QueuedInspectionCount = 0
			self.CurrentInspectionTarget = nil
		end

		-- Process inspection queue (handles rate limiting internally)
		self:ProcessInspectionQueue()
	end

	-- Check for talent refreshes every 30 seconds (still with a 5 min cd on successes)
	if now > last_talent_refresh_check + 30 then
		last_talent_refresh_check = now

		-- Queue talent refresh for raid members
		local numRaid = GetNumRaidMembers()
		if numRaid > 0 then
			for i = 1, numRaid do
				local unit = "raid"..i
				if UnitName(unit) then
					-- QueuePlayerInspection will check if refresh is needed
					self:QueuePlayerInspection(unit)
				end
			end
		else
			-- Queue talent refresh for party members
			local numParty = GetNumPartyMembers()
			for i = 1, numParty do
				local unit = "party"..i
				if UnitName(unit) then
					self:QueuePlayerInspection(unit)
				end
			end
		end
	end
end

-- Parse talent information from addon messages (Turtle WoW inspection system)
function ALogger:CHAT_MSG_ADDON(prefix, message, channel, from)
	if prefix ~= "TW_CHAT_MSG_WHISPER" then return end

	-- Only process messages from the player we're currently inspecting
	-- This prevents stale messages from previous inspections
	if from ~= self.CurrentInspectionTarget then
		return
	end

	-- Check for inspection completion
	if string.find(message, "INSTalentEND") then
		self.QueuedInspectionCount = math.max(self.QueuedInspectionCount - 1, 0)
		self.CurrentInspectionTarget = nil

		-- Record successful talent update
		self.TalentLastUpdate[from] = GetTime()

		-- Trigger equipment update for this player now that talents are collected
		-- Find the unit ID for this player
		local unit = nil
		local numRaid = GetNumRaidMembers()
		if numRaid > 0 then
			for i = 1, numRaid do
				if UnitName("raid"..i) == from then
					unit = "raid"..i
					break
				end
			end
		else
			local numParty = GetNumPartyMembers()
			for i = 1, numParty do
				if UnitName("party"..i) == from then
					unit = "party"..i
					break
				end
			end
		end

		if unit then
			self:grab_unit_information(unit)
		end

		-- Next inspection will be processed by OnUpdate
		return
	end

	if not string.find(message, "INSTalentInfo") then return end

	-- Parse talent message: INSTalentInfo;tree;index;name;tier;column;currRank;maxRank;meetsPrereq
	local parts = {}
	local start = 1
	for i = 1, 9 do
		local pos = string.find(message, ";", start, true)
		if pos then
			tinsert(parts, strsub(message, start, pos - 1))
			start = pos + 1
		else
			tinsert(parts, strsub(message, start))
			break
		end
	end

	if table.getn(parts) >= 7 then
		local tree = tonumber(parts[2])
		local currRank = tonumber(parts[7])

		if tree and currRank then
			-- Append rank to the tree's talent string
			-- We've already verified this is from CurrentInspectionTarget
			-- and initialized the table in ProcessInspectionQueue
			self.TalentInfo[from][tree] = self.TalentInfo[from][tree] .. currRank
		end
	end
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

-- NB Server sends weird custom item id's for xmogged items, real ones don't exist in a form we can extract
-- the only way to get around this would be to keep our own item db and to compare item names
function ALogger:grab_unit_information(unit)
	local unit_name = UnitName(unit)
	if UnitIsPlayer(unit) and unit_name ~= nil and unit_name ~= Unknown then
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
			-- Get player's own talents directly from API
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
		else
			-- Get other players' talents from addon message cache
			if self.TalentInfo[unit_name] then
				local talents = strjoin("}", self.TalentInfo[unit_name][1], self.TalentInfo[unit_name][2], self.TalentInfo[unit_name][3])
				if strlen(talents) > 10 then
					info["talents"] = talents
				end
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
