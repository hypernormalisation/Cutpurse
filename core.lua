--=========================================================================================
-- Main module for Cutpurse
--=========================================================================================
local addon_name, cp = ...
local CP = LibStub("AceAddon-3.0"):NewAddon(addon_name, "AceConsole-3.0", "AceEvent-3.0")
CP.callbacks = CP.callbacks or LibStub("CallbackHandler-1.0"):New(CP)
local LSM = LibStub("LibSharedMedia-3.0")
cp.debug = false
cp.add_test_list = true
local L = cp.L
if cp.debug then CP:Print("Parsing core.lua...") end

-- Load some relevant wow API and lua globals into the local namespace.
local GetInviteConfirmationInfo = GetInviteConfirmationInfo
local GetNextPendingInviteConfirmation = GetNextPendingInviteConfirmation
local GetUnitName = GetUnitName
local GetTime = GetTime
local GetPlayerInfoByGUID = GetPlayerInfoByGUID
local GetRealmName = GetRealmName
local IsInGroup = IsInGroup
local IsInRaid = IsInRaid
local PlaySoundFile = PlaySoundFile
local GetNumGroupMembers = GetNumGroupMembers

local UnitInBattleground = UnitInBattleground
local UnitFactionGroup = UnitFactionGroup
local UnitIsPlayer = UnitIsPlayer
local UnitIsUnit = UnitIsUnit
local UnitGUID = UnitGUID
local UnitName = UnitName
local UnitLevel = UnitLevel
local UnitRace = UnitRace
local UnitClass = UnitClass
local GetGuildInfo = GetGuildInfo
local SendChatMessage = SendChatMessage

local pcall = pcall

local LE_PARTY_CATEGORY_HOME = LE_PARTY_CATEGORY_HOME
local RAID_CLASS_COLORS = RAID_CLASS_COLORS

local ipairs = ipairs
local next = next
local pairs = pairs
local print = print
local select = select
local string = string
local type = type
local tostring = tostring

local function tab_dump(o)
	if type(o) == 'table' then
	   local s = '{ '
	   for k,v in pairs(o) do
		  if type(k) ~= 'number' then k = '"'..k..'"' end
		  s = s .. '['..k..'] = ' .. tab_dump(v) .. ','
	   end
	   return s .. '} '
	else
	   return tostring(o)
	end
end
CP.tab_dump = tab_dump

function CP:colorise_name(name, class)
	local c = RAID_CLASS_COLORS[class]
	local cc = ('c' .. c.colorStr)
	return "|"..cc..name.."|r"
end

local context_pretty_table = {
	mouseover = "Mouseover",
	target = "Target",
	group = "Group",
	invite_confirmation = "Invite Confirmation",
	trade = "Trade Window",
	whisper = "Whisper",
}

local incident_categories = {
	["dungeon"] = "Dungeon Scam",
	["raid"] = "Raid Scam",
	["gdkp"] = "GDKP Scam",
	["trade"] = "Trade Scam",
	["harassment"] = "Harassment",
}

-- Necessary for localization due to the lower case classes being localized.
local english_locale_classes = {
	DEATHKNIGHT = "Death Knight",
	DRUID = "Druid",
	HUNTER = "Hunter",
	MAGE = "Mage",
	PALADIN = "Paladin",
	PRIEST = "Priest",
	ROGUE = "Rogue",
	SHAMAN = "Shaman",
	WARRIOR = "Warrior",
	WARLOCK = "Warlock",
}

CP.guid_match_str = "This player's ID matches the following incidents:"
CP.name_match_str = "This player's name matches the following incidents (name matches may not be conclusive):"
CP.unprocessed_case_data = {}
CP.provider_counter = 0

--=========================================================================================
-- Helper funcs
--=========================================================================================
function CP:get_opts_db()
	return self.db.profile
end

function CP:get_provider_settings()
	return self.db.global.provider_settings
end

function CP:get_UDI()
	return self.db.global.udi
end

--=========================================================================================
-- The basic AceAddon structure
--=========================================================================================
function CP:OnInitialize()

	-- Register our custom sound alerts with LibSharedMedia
	LSM:Register(
		"sound", "Cutpurse: Criminal scum!",
		string.format([[Interface\Addons\%s\media\criminal_scum.mp3]], addon_name)
	)
	LSM:Register(
		"sound", "Cutpurse: Not on my watch!",
		string.format([[Interface\Addons\%s\media\nobody_breaks_the_law.mp3]], addon_name)
	)
	LSM:Register(
		"sound", "Cutpurse: You've violated the law!",
		string.format([[Interface\Addons\%s\media\youve_violated_the_law.mp3]], addon_name)
	)

	-- Make the addon database
	self.db = LibStub("AceDB-3.0"):New(addon_name.."DB", self.defaults, true)
	self.conf = self.db.global --shorthand

	-- Register the options table
	local AC = LibStub("AceConfig-3.0")
	local ACD = LibStub("AceConfigDialog-3.0")
	local options_name = addon_name.."_Options"
	AC:RegisterOptionsTable(options_name, self.options)
	self.optionsFrame = ACD:AddToBlizOptions(options_name, addon_name)

	-- Register the necessary slash commands
	self:RegisterChatCommand("cp", "slashcommand_options")
	self:RegisterChatCommand("cutpurse", "slashcommand_options")
	self:RegisterChatCommand("dump_users", "dump_users")
	self:RegisterChatCommand("dump_incidents", "dump_incidents")
	self:RegisterChatCommand("dump_name_lookup", "dump_name_lookup")
	-- self:RegisterChatCommand("dump_guid_lookup", "dump_guid_lookup")

	self:RegisterChatCommand("dump_udi", "dump_udi")
	self:RegisterChatCommand("clear_udi", "clear_udi")
	self:RegisterChatCommand("clear_fps", "clear_fps")
	self:RegisterChatCommand("test1", "test1")

	-- Temporary 
	-- self.provider_counter = 0

	-- Containers for the alerts system.
	self.alert_counter = 0  -- just for index handling on temp alerts list
	self.pending_alerts = {}

end

function CP:OnEnable()
	self.realm_name = GetRealmName()
	self.player_faction = UnitFactionGroup("player")

	-- Alert the extension addons to register their case data.
	self.callbacks:Fire("CUTPURSE_LIST_CONSTRUCTION")
	-- Then build the database.
	self:build_database()

	-- Enable the requisite events here according to settings.
	local opts_db = self:get_opts_db()
	if opts_db.use_mouseover_scan then
		self:RegisterEvent("UPDATE_MOUSEOVER_UNIT")
	end
	if opts_db.use_whisper_scan then
		self:RegisterEvent("CHAT_MSG_WHISPER")
	end
	if opts_db.use_target_scan then
		self:RegisterEvent("PLAYER_TARGET_CHANGED")
	end
	if opts_db.use_trade_scan then
		self:RegisterEvent("TRADE_SHOW")
	end
	if opts_db.use_group_scan then
		self:RegisterEvent("GROUP_ROSTER_UPDATE")
	end
	if opts_db.use_group_request_scan then
		self:RegisterEvent("GROUP_INVITE_CONFIRMATION")
	end
	-- Only if in a group, run the group scan callback.
	if opts_db.use_group_scan and IsInGroup(LE_PARTY_CATEGORY_HOME) then
		self:GROUP_ROSTER_UPDATE()
	end

	-- Welcome message if requested
	if opts_db.welcome_message then
		self:Print('Welcome to version 0.0.1.')
	end

end

--=========================================================================================
-- Funcs to register lists with Cutpurse, for use in addons that extend Cutpurse, and
-- funcs to construct the lists used by the addon.
--=========================================================================================
function CP:register_case_data(data)
	-- Function to be called in provider extentions upon receiving
	-- the CUTPURSE_LIST_CONSTRUCTION callback.
	-- This function takes a table of case data vars with integer keys.
	-- self:Print("CALL TO REGISTER A LIST")
	-- print(tab_dump(data))

	-- TO-DO: we should do some data validation here.

	self.provider_counter = self.provider_counter + 1
	self.unprocessed_case_data[self.provider_counter] = data
end

function CP:build_database()
	-- This function builds (or rebuilds) the database from the registered
	-- raw lists from the provider extensions.
	if cp.debug then
		self:Print("Building Cutpurse database...")
	end
	-- A table mapping GUIDs to User info tables.
	self.user_table = {}
	self.user_counter = 0

	-- A table recording individual incidents.
	self.incident_table = {}
	self.incident_counter = 0
	self.name_to_incident_table = {}

	-- Tables for sanity checks on old aliases and guids.
	self.previous_guid_table = {}
	self.alias_table = {}

	-- Now iterate over the unprocessed case data and build up the db.
	local pdb = self:get_provider_settings()
	for _, l in pairs(self.unprocessed_case_data) do
		local n = l.name
		-- If no setting for this provider, assume enabled.
		if pdb[n] == nil then
			pdb[n] = {enabled = true}
			self:process_provider(l)
		-- Else check for disabled lists and skip
		else
			if pdb[n].enabled then
				self:process_provider(l)
			end
		end
	end
	-- self:database_post_processing()
end

function CP:protected_process_provider(l)
	-- Wrap the parse of the unprocessed provider data in a pcall
	-- to catch errors.
	local result = pcall(self.process_provider, l)
	if not result then
		local name = l.name or l.provider or "UNIDENTIFIED LIST"
		self:Print(
			string.format(
				"ERROR: the provider list %s could not be properly processed. "..
				"Please contact the distributer of this list and disable the extension "..
				"module until a fix is provided by the distributer, as this list may "..
				"corrupt Cutpurse's internal databases.",
				name
			)
		)
	end
end

function CP:process_provider(l)
	-- Takes the given case data for a single provider and adds
	-- it to the database.
	for realm, realm_dict in pairs(l.realm_data) do
		for _, case_data in pairs(realm_dict) do
			case_data.realm = realm
			case_data.provider = l.provider
			if case_data.name then
				case_data.full_name = case_data.name .. "-" .. realm	
			end
			-- If "players" field given, we have multiple players on
			-- this incident, so process them all.
			if case_data.players then
				self:process_players(case_data)
			-- Else if we have a GUID, we ensure the case is linked
			-- to a discrete user.
			elseif case_data.guid then
				self:process_player_by_guid(case_data)
			end
			self:process_incident(case_data)
		end
	end
end

function CP:process_players(case_data)
	-- This function handles parsing of incidents with multiple players.
	for _, player_info in pairs(case_data.players) do
		if player_info.guid then
			player_info.realm = case_data.realm
			player_info.provider = case_data.provider
			self:process_player_by_guid(player_info)
		end
	end
end

function CP:process_player_by_guid(input)
	-- This function processes an individual case where a guid
	-- is given in the case data. If a user entry already exists for this
	-- guid, it merges the information. Else, it creates a new user entry.
	-- print(tab_dump(input))
	local exists = not (self.user_table[input.guid] == nil)
	local t = {}
	if exists then
		t = self.user_table[input.guid]
		if input.realm ~= t.realm then
			self:Print(
				"Warning: two lists have the same player matched by current guid, but "..
				"listed on different servers, which is impossible. "..
				string.format("Player name: %s", input.name .. "-" .. input.realm)
			)
		end
	else
		t.realm = input.realm
		t.names = {}
		t.previous_names = {}
		t.previous_guids = {}
		t.incidents = {}
	end

	-- Add name if not present to possible current names.
	if not t.names[input.provider] then
		t.names[input.provider] = input.name
	end
	-- Possible previous names
	if input.previous_names then
		for _, alias in ipairs(input.previous_names) do
			if not t.aliases[alias] then
				t.aliases[alias] = true
				self.alias_table[alias] = input.name
			end
		end
	end
	-- Possible previous guids
	if input.previous_guids then
		for _, g in ipairs(input.previous_guids) do
			if not t.previous_guids[g] then
				t.previous_guids[g] = true
				self.previous_guid_table[g] = {guid = input.guid}
			end
		end
	end
	self.user_table[input.guid] = t
end

function CP:process_incident(case_data)
	-- Adds the incident to the db, ensuring it's linked
	-- to either a guid or name in the lookup.
	self.incident_counter = self.incident_counter + 1
	local c = {}
	c.case_id = self.incident_counter
	c.description = case_data.description or false
	c.url = case_data.url
	c.category = case_data.category or false
	c.level = case_data.level or 3
	c.provider = case_data.provider
	-- c.class = case_data.class or false
	self.incident_table[self.incident_counter] = c

	-- Now we need to reference the incident.
	if case_data.players then
		for _, player_info in pairs(case_data.players) do
			if player_info.name then
				player_info.full_name = player_info.name .. "-" .. case_data.realm
			end
			self:reference_incident_to_player(player_info)
		end
	else
		self:reference_incident_to_player(case_data)
	end
end

function CP:reference_incident_to_player(input)
	-- Creates a reference between a single player and the incident in question.
	-- input will either be the table for the whole case for a single player,
	-- or alternately a player_info table for each player in the case.
	if input.guid then
		self.user_table[input.guid].incidents[self.incident_counter] = true
	else
		if not self.name_to_incident_table[input.full_name] then
			self.name_to_incident_table[input.full_name] = {}
			self.name_to_incident_table[input.full_name].incidents = {}
		end
		self.name_to_incident_table[input.full_name].incidents[self.incident_counter] = true
	end
end

--=========================================================================================
-- Unit checking functionality.
--=========================================================================================
function CP:is_unit_eligible(unit_token)
	-- Function to get info using the specified unit_token and
	-- verify the unit in question is another same-faction player.
	if not UnitIsPlayer(unit_token) then
		return false
	end
	if UnitIsUnit("player", unit_token) then
		return false
	end
	local is_same_faction = self.player_faction == UnitFactionGroup(unit_token)
	if not is_same_faction then
		return false
	end
	return true
end

function CP:check_unit(unit_token, unit_guid, scan_context)
	-- Checks a unit against the lists.
	-- Requires one of unit_token or unit_guid.
	-- The scan_context is required to tell the alerts system what scan
	-- registered the unit. If a unit_token is given, it defaults to that.
	-- If a unit token does not exist, as for whispers or invite
	-- confirmations, it should be passed manually.

	-- First check for a guid match.
	local conf = self:get_opts_db()
	unit_guid = unit_guid or UnitGUID(unit_token)
	local guid_match = false
	if self.user_table[unit_guid] then
		guid_match = true
	end
	local name, realm = select(6, GetPlayerInfoByGUID(unit_guid))
	-- self:Print(realm, type(realm))
	if realm == "" then
		-- self:Print(self.realm_name)
		realm = self.realm_name
	end
	local full_name = name .. "-" .. realm
	-- self:Print(full_name)

	-- If not a guid match, check for name match. If also no name match, unit
	-- is not listed, so return.
	-- self:Print("GUID match: " .. tostring(guid_match))
	if not guid_match then
		if conf.require_guid_match then return end
		if not self.name_to_incident_table[full_name] then
			return
		end
	end
	-- By now we know the person is listed. So populate the query table
	-- and update the dynamic info for the unit.
	unit_token = unit_token or false
	scan_context = unit_token or scan_context
	self.query = {}  -- internal container to avoid passing args everywhere.
	self.query.unit_token = unit_token
	self.query.scan_context = scan_context
	self.query.guid_match = guid_match
	self.query.guid = unit_guid
	self.query.full_name = full_name
	self.query.short_name = name
	self:update_UDI()


	-- Check we're not on report lockout for this unit.
	if not self:is_off_alert_lockout() then return end

	-- Fetch incidents that meet addon user's requirements.
	-- conf.match_all_incidents
	local guid_match_incidents = nil
	local name_match_incidents = nil
	if guid_match then
		guid_match_incidents = self:return_viable_incidents()
	end
	if (not guid_match) or conf.match_all_incidents then
		name_match_incidents = self:return_viable_incidents(true)
	end
	if (not guid_match_incidents) and (not name_match_incidents) then
		-- self:Print("No viable matches")
		return
	end
	-- self:Print("Found some matching incidents.")
	self.query.guid_match_incidents = guid_match_incidents
	self.query.name_match_incidents = name_match_incidents
	self:raise_alert()

end

function CP:is_off_alert_lockout()
	-- This function determines if a given unit is on alert lockout.
	-- Also sets the last_alerted variables if off lockout. Returns true or false.
	local udi = self:get_UDI()
	local q = self.query
	local index = q.guid
	if not q.guid_match then
		index = q.full_name
	end
	if not udi[index].last_alerted then
		udi[index].last_alerted = GetTime()
		return true
	end

	local delta = self:get_opts_db().alert_lockout_seconds
	if GetTime() < delta + udi[index].last_alerted then
		local time_until = delta + udi[index].last_alerted - GetTime()
		-- self:Print(string.format("locked out for another %f seconds", time_until))
		return false
	end
	udi[index].last_alerted = GetTime()
	return true
end

function CP:return_viable_incidents(force_name_match)
	-- Function to parse the incidents and return
	-- a list of ones meeting the player's requirements for alerts.
	-- Returns a table of incidents if any match.
	-- Returns false if none match.
	force_name_match = force_name_match or false
	local incident_table = {}
	local counter = 0
	local incident_matches = nil
	if not force_name_match then
		incident_matches = self.user_table[self.query.guid].incidents
	else
		-- print(self.query.full_name)
		if self.name_to_incident_table[self.query.full_name] == nil then
			-- print('no table')
			return false
		end
		incident_matches = self.name_to_incident_table[self.query.full_name].incidents
	end
	-- print(tab_dump(incident_matches))
	for i, _ in pairs(incident_matches) do
		local incident = self.incident_table[i]
		-- print(i)
		-- print(incident.description)
		if self:should_add_incident(incident) then
			counter = counter + 1
			incident_table[counter] = incident
		end
	end
	if next(incident_table) == nil then
		return false
	end
	return incident_table
end

function CP:should_add_incident(incident)
	-- Checks the given incident meets the user's requirements
	-- for generating an alert.
	local conf = self:get_opts_db()

	-- First alert level.
	if incident.level < conf.minimum_level then
		-- self:Print("Incident too low level")
		return false
	end

	-- Then category. If no category given by provider then proceed.
	if incident.category == false then
		return true
	end
	-- If category is given wrongly by provider, ignore it.
	if not incident_categories[incident.category] then
		return true

	-- If category exists, check it's not excluded.
	else
		if conf.exclusions[incident.category] == false then
			return true
		end
	end
	return false
end

function CP:update_UDI()
	-- This function runs when we interact with a scammer and records some of their
	-- information to persistant storage (User Dynamic Information table).
	local udi = self:get_UDI()
	local q = self.query
	local index = q.guid
	if not q.guid_match then
		index = q.full_name
	end

	-- If the entry doesn't exist, create it and populate the static fields.
	if not udi[index] then
		local p = {}
		local loc_class, english_class, race, _, _, name = GetPlayerInfoByGUID(
			q.guid
		)
		p.class = loc_class
		p.class_english_locale = english_locale_classes[english_class]
		p.english_class = english_class
		p.race = race
		p.guid = q.guid
		p.short_name = name
		p.full_name = q.full_name
		-- And placeholders for the dynamic fields.
		p.guild = false
		p.level = false
		p.last_alerted = false
		p.name_mismatches = {}
		udi[index] = p
	end
	local p = udi[index]

	-- Always update last seen
	p.last_seen = GetTime()

	-- At this point can also check the names 
	if q.guid_match then
		for provider, name in pairs(self.user_table[index].names) do
			if p.short_name ~= name and p.name_mismatches[name] == nil then
				p.name_mismatches[provider] = name
				local s = string.format(
					"Warning: the list provider %s has an outdated name listed for the "..
					"user %s. They are listed as % in the provider list, please contact "..
					"the list provider to remedy this.",
					provider, p.short_name, name
				)
				self:Print(s)
			end
		end
	end

	-- If we have a unit token, we can check current guild and level.
	if q.unit_token then
		local token = q.unit_token
		p.level = UnitLevel(token)
		p.guild = GetGuildInfo(token) or false
	end
end

--=========================================================================================
-- String construction for alerts
--=========================================================================================
function CP:construct_printout_headline()
	-- Constructs a summary string for the pinged unit.
	local q = self.query
	local udi = self:get_UDI()
	local u = udi[q.guid]
	local name = self:colorise_name(u.short_name, u.english_class)
	if u == nil then
		u = udi[q.full_name]
	end
	local s1 = "Encountered a listed player! "
	if u.level and u.guild then
		s1 = s1 .. string.format("lvl %0.f %s %s from [%s]", u.level, u.class_english_locale, name, u.guild)
	elseif u.level then
		s1 = s1 .. string.format("lvl %0.f %s %s", u.level, u.class_english_locale, name)
	elseif u.guild then
		s1 = s1 .. string.format("%s %s from [%s]", u.race, u.class_english_locale, name)
	else
		s1 = s1 .. string.format("%s %s", u.class_english_locale, name)
	end
	s1 = s1 .. string.format(", detected via %s scan.\nListed by:", q.scan_context)
	q.headline = s1
end

-- function CP:construct_incident_summaries()
-- 	-- Construct summary strings for the incidents for the unit.
-- 	local q = self.query
-- 	local counter = 0
-- 	if q.guid_match_incidents then
-- 		q.guid_incident_summaries = {}
-- 		for _, incident in pairs(q.guid_match_incidents) do
-- 			local s = "    Listed by " .. incident.provider
-- 			if incident.category and incident_categories[incident.category] then
-- 				s = s .. string.format(" for %s:\n", incident_categories[incident.category])
-- 			else
-- 				s = s .. ":\n"
-- 			end
-- 			if incident.description then
-- 				s = s .. "    - " .. incident.description .. '\n'
-- 			end
-- 			s = s .. "    - " .. incident.url .. '\n'
-- 			-- print(s)
-- 			q.guid_incident_summaries[counter] = s
-- 			counter = counter + 1
-- 		end
-- 	end
-- 	if q.name_match_incidents then
-- 		q.name_incident_summaries = {}
-- 		for _, incident in pairs(q.name_match_incidents) do
-- 			local s = "    Listed by " .. incident.provider
-- 			if incident.category and incident_categories[incident.category] then
-- 				s = s .. string.format(" for %s:\n", incident_categories[incident.category])
-- 			else
-- 				s = s .. ":\n"
-- 			end
-- 			if incident.description then
-- 				s = s .. "    - " .. incident.description .. '\n'
-- 			end
-- 			s = s .. "    - " .. incident.url .. '\n'
-- 			-- print(s)
-- 			q.name_incident_summaries[counter] = s
-- 			counter = counter + 1
-- 		end
-- 	end
-- end

function CP:construct_chat_strings()
	-- Constructs the necessary strings for channel alerts.
	local q = self.query

	-- The headline
	q.chat_headline = string.format("Warning! %s is a known scammer. Listed by...", q.short_name)
	-- The guid-matched incidents
	q.chat_incidents = {}
	if q.guid_match_incidents then
		for _, incident in pairs(q.guid_match_incidents) do
			if not q.chat_incidents[incident.provider] then
				q.chat_incidents[incident.provider] = {}
			end
			local s = string.format("-> %s:", incident.provider)
			if incident.category then
				s = string.format("-> %s for %s:", incident.provider, incident_categories[incident.category])
			end
			s = s .. " " .. incident.url
			q.chat_incidents[incident.provider][incident.case_id] = {s = s, guid = true, incident=incident}
		end
	end
	-- The name-matched incidents
	if q.name_match_incidents then
		for _, incident in pairs(q.name_match_incidents) do
			if not q.chat_incidents[incident.provider] then
				q.chat_incidents[incident.provider] = {}
			end
			local s = string.format("-> %s:", incident.provider)
			if incident.category then
				s = string.format("-> %s for %s:", incident.provider, incident_categories[incident.category])
			end
			s = s .. " " .. incident.url
			s = s .. " (name-only)"
			q.chat_incidents[incident.provider][incident.case_id] = {s = s, guid = false, incident=incident}
		end
	end
end

--=========================================================================================
-- Alert functionality.
--=========================================================================================
function CP:play_alert_sound()
	-- Plays the configured alert sound in the client.
	local k = self:get_opts_db().alert_sound
	-- self:Print('playing alert, sound key = '..tostring(k))
	local sound_file = LSM:Fetch('sound', k)
	PlaySoundFile(sound_file)
end

function CP:print_chat_alert()
	-- Prints an alert to the chatbox, just to the player.
	local conf = self:get_opts_db()
	local q = self.query
	local s = q.headline .. '\n'
	for _, provider_table in pairs(q.chat_incidents) do
		for _, t in pairs(provider_table) do
			s = s .. t.s .. '\n'
			if t.incident.description and conf.show_chat_descriptions then
				s = s .. "--> " .. t.incident.description .. '\n'
			end
		end
	end
	self:Print(s)
end

function CP:send_channel_alert(channel)
	-- Sends a chat alert to the requested channel.
	local conf = self:get_opts_db()
	local q = self.query
	SendChatMessage(q.chat_headline, channel)
	for _, provider_table in pairs(q.chat_incidents) do
		for _, t in pairs(provider_table) do
			SendChatMessage(t.s, channel)
			if t.incident.description and conf.show_chat_descriptions then
				SendChatMessage("--> " .. t.incident.description, channel)
			end
		end
	end
end

function CP:raise_alert()
	-- This function acts upon the internal query object to produce
	-- a report on the unit that has been flagged, and alerts the user
	-- using the configured methods.
	-- First construct the relevant messages etc.
	self:construct_printout_headline()
	self:construct_chat_strings()

	local conf = self:get_opts_db()
	if conf.use_alert_sound then
		self:play_alert_sound()
	end

	-- Only do printout if the 
	if conf.use_group_chat_alert and IsInGroup(LE_PARTY_CATEGORY_HOME) then
		local channel = "PARTY"
		if IsInRaid() then
			channel = "RAID"
		end
		self:send_channel_alert(channel)
	else
		if conf.use_chat_alert then
			self:print_chat_alert()
		end
	end
	-- Handle stats counters
	-- self.db.global.n_alerts = self.db.global.n_alerts + 1
	-- self.db.realm.n_alerts = self.db.realm.n_alerts + 1
end

--=========================================================================================
-- WoW API callbacks
--=========================================================================================
function CP:UPDATE_MOUSEOVER_UNIT()
	if not self:get_opts_db().use_mouseover_scan then return end
	if not self:is_unit_eligible("mouseover") then return end
	self:check_unit("mouseover")
end

function CP:CHAT_MSG_WHISPER(
		event_name, msg, player_name_realm,
		_, _, player_name, _, _, _, _, _, line_id, player_guid
	)
	if not self:get_opts_db().use_whisper_scan then return end
	self:check_unit(nil, player_guid, "whisper")
end

function CP:PLAYER_TARGET_CHANGED()
	if not self:get_opts_db().use_target_scan then return end
	if not self:is_unit_eligible("target") then return end
	self:check_unit("target")
end

function CP:GROUP_ROSTER_UPDATE()
	local members = {}
	if not IsInGroup(LE_PARTY_CATEGORY_HOME) then
		-- print("not in a group")
		return
	end
	-- Based on reading online, might need a short C_Timer in here if the unit info
	-- isn't available 
	local n, unit = GetNumGroupMembers(), "raid"
	if not IsInRaid(LE_PARTY_CATEGORY_HOME) then
		n, unit = n - 1, "party"
	end
	for i = 1, n do
		local name = GetUnitName(unit..i, true)
		local guid = UnitGUID(unit..i)
		if name and name ~= "UNKNOWN" then
			members[name] = guid
		end
	end
	self.members = members
	for name, guid in pairs(members) do
		-- self:Print(name, guid)
		self:check_unit(nil, guid, "group")
	end
end

function CP:GROUP_INVITE_CONFIRMATION()
	-- This event is called when another player requests to join the group, either
	-- via interacting with the player directly or through the group finder, or when a party member
	-- suggests an invite. We can use the API funcs in this callback to programatically get the info
	-- we need on the player who is requesting/being requested to join.
	local invite_guid = GetNextPendingInviteConfirmation()
	local _, name, guid = GetInviteConfirmationInfo(invite_guid)
	self:Print(name, guid)
	self:check_unit(nil, guid, "invite_confirmation")
end

function CP:TRADE_SHOW()
	-- This event is called when the trade window is opened.
	-- We can use the special "NPC" unit to get info we need on the
	-- character. See
	-- https://github.com/Gethe/wow-ui-source/blob/f0084386950fe3dc31a1d61de33b364e268cf66b/Interface/FrameXML/TradeFrame.lua#L68
	-- The other relevant event for the trade is "TRADE_REQUEST", however we cannot
	-- use it, because the "NPC" unit is only valid when the trade window is open.
	self:check_unit("NPC", nil, "trade")
end

--=========================================================================================
-- Register slashcommands
--=========================================================================================
function CP:slashcommand_options(input, editbox)
	local ACD = LibStub("AceConfigDialog-3.0")
	ACD:Open(addon_name.."_Options")
end

function CP:dump_users()
	print(tab_dump(self.user_table))
end

function CP:dump_incidents()
	print(tab_dump(self.incident_table))
end

function CP:dump_name_lookup()
	print(tab_dump(self.name_to_incident_table))
end

function CP:dump_udi()
	print(tab_dump(self:get_UDI()))
end

function CP:clear_udi()
	self.db.global.udi = {}
end

function CP:clear_fps()
	-- Clear false positive table
	self.db.global.false_positive_table = {}
end

function CP:slashcommand_soundcheck()
	local sound_file = LSM:Fetch('sound', self.conf.alert_sound)
	PlaySoundFile(sound_file)
end

function CP:test1()
	self:Print("N alerts global = " .. tostring(self.db.global.n_alerts))
	self:Print("N alerts realm  = " .. tostring(self.db.realm.n_alerts))
end

--=========================================================================================
-- Debug for lua parsing
--=========================================================================================
if cp.debug then CP:Print("Finished parsing core.lua.") end
