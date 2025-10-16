# AdvancedLogger

An advanced combat logging addon for Turtle WoW that provides comprehensive raid logging with detailed event tracking.  
Not currently entirely compatible with melbaa's consume tracker, many trinket uses and consumes won't be tracked as melbaa's doesn't read raw spell ids.  

## Features

### Combat Logging
- **Automatic Combat Log Control**: Automatically enables combat logging when entering instances, disables when leaving
- **Spell Cast Tracking**: Logs all spell casts with spell IDs, ranks, cast types (cast/channel/begin/fail), and targets

### Boss & Enemy Tracking
- **Boss Ability Special Cases**: Tracks casts of targetless boss abilities (Chromaggus breaths, Flame Breath, Shadow Flame, etc.)
- **Aggro Events**: Tracks and logs initial mob aggro with target information
- **Model Changes**: Logs unit model updates (useful for boss phase transitions and transformations)
- **Boss Communications**: Captures all boss say/yell/emote/whisper messages and raid boss emotes

### Raid Markers
- **Mark Tracking**: Logs all raid target marking events (Star, Circle, Diamond, Triangle, Moon, Square, Cross, Skull)
- **Mark Changes**: Tracks when marks are changed on living units
- **Mark Integration**: Includes marks in cast and aggro logs for easier identification

### Player & Raid Information
- **Combatant Info Logging**: Comprehensive player information capture including:
  - Name, class, race, sex
  - Guild name, rank name, and rank index
  - Pet names
  - Complete gear inventory (all 19 equipment slots with item IDs and enchants)
  - Talent specialization (for player character)
- **Automatic Roster Updates**: Captures player info when joining raid/party and on zone changes

### Loot & Economy
- **Enhanced Loot Logging**: Logs all loot events with timestamps
- **Trade Tracking**: Records item trades between players

### Zone & Instance
- **Zone Information**: Logs current zone and instance ID on zone changes
- **Instance ID Tracking**: Captures and logs saved instance information

## Installation
This requires https://github.com/balakethelock/SuperWoW to work.

Remove `AdvancedVanillaCombatLog` directory from your addons folder if it existed.

Place `AdvancedLogger` in Interface/Addons.

## Preparing for upload
In order to upload your logs to monkeylogs/legacy logs you need to run `format_log_for_upload.py` on your WowCombatLog.txt.

Fill in your player name and the name of your log file when prompted, then upload the zipped WowCombatLog.txt to turtlogs.

## Changes from AdvancedVanillaCombatLog
- No longer requires any raiders to run the AdvancedVanillaCombatLog_Helper addon.
- No longer need to spam failure messages to write to the log
- No longer overwrites all of the combat event format strings to change you -> playername.  This would break addons like bigwigs that looked for messages like "You have been afflicted by Poison Charge".
It does still overwrite the initial debuff/buff events to add a (1) because I deemed it unlikely to break other addons and is convenient compared to editing those messages after the fact.
```
    AURAADDEDOTHERHELPFUL = "%s gains %s (1)."
    AURAADDEDOTHERHARMFUL = "%s is afflicted by %s (1)."
    AURAADDEDSELFHARMFUL = "You are afflicted by %s (1)."
    AURAADDEDSELFHELPFUL = "You gain %s (1)."
```
- Self damage is now separated as Playername(selfdamage)
