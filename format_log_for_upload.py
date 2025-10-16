import os
import re
import shutil
import time
import zipfile


def handle_replacements(line, replacements):
    for pattern, replacement in replacements.items():
        try:
            new_text, num_subs = re.subn(pattern, replacement, line)
        except Exception as e:
            print(f"Error replacing pattern: {pattern} with replacement: {replacement}")
            print(f"Line: {line}")
            raise e
        if num_subs:
            return new_text

    return line


def remove_raid_marks(target_name, marks_list):
    """Remove raid target marks from a target name"""
    if not target_name:
        return target_name

    # Remove period if present
    target_name = target_name.rstrip('.')

    for mark in marks_list:
        # Remove marks in parentheses like "(Cross)" from the end of names
        target_name = re.sub(rf'\({mark}\)$', '', target_name)

    return target_name.strip()


def replace_instances(player_name, filename):
    player_name = player_name.strip().capitalize()

    # Compile regex patterns once for better performance
    summoned_pet_owner_regex = re.compile(r"([a-zzA-Z][ a-zzA-Z]+[a-zzA-Z]) \(([a-zzA-Z]+)\)")
    self_damage_patterns = [
        (re.compile(r"  ([a-zA-Z' ]*?) suffers (.*) (damage) from ([a-zA-Z' ]*?) 's"), r"  \g<1> suffers \g<2> damage from \g<4> (self damage) 's"),
        (re.compile(r"  ([a-zA-Z' ]*?) 's (.*) (hits|crits) ([a-zA-Z' ]*?) for"), r"  \g<1> (self damage) 's \g<2> \g<3> \g<4> for")
    ]

    # Greylist: For spells that appear here, only the specified ID is accepted
    # Other spells with same name but different IDs will be filtered out
    spell_id_greylist = {
        "Blood Fury": 20572,  # Only Blood Fury(20572) is kept, others like 23234 are filtered
    }

    # Raid target marks to remove from target names (from AdvancedLogger.lua)
    raid_target_marks = {"Star", "Circle", "Diamond", "Triangle", "Moon", "Square", "Cross", "Skull"}

    # Pattern to match cast lines with spell IDs - captures spell ID in group 3
    cast_with_id_pattern = re.compile(r"(.* (?:casts|channels|begins to cast) )(.+?)\((\d+)\)(?:\(Rank \d+\))?( .*)?")

    # Patterns for filtering unwanted cast lines (non-greylist)
    unwanted_cast_patterns = [
        # These will be populated dynamically based on greylist
    ]

    # Patterns for filtering unwanted line types
    unwanted_line_prefixes = [
        "MARK:",
        "LOOT_TRADE:",
        "AGGRO:",
        "MODEL_UPDATE:",
        "CHAT_MSG:"
    ]

    # Mob names with apostrophes - temporarily remove apostrophes to avoid parsing issues
    # These will be restored later in the renames section
    mob_names_with_apostrophe = {
        "Onyxia's Elite Guard": "Onyxias Elite Guard",
        "Sartura's Royal Guard": "Sarturas Royal Guard",
        "Ima'ghaol, Herald of Desolation": "Imaghaol, Herald of Desolation",
    }

    # Item/consumable names with apostrophes - temporarily remove apostrophes
    # These will be restored later in the renames section
    item_names_with_apostrophe = {
        "Medivh's Merlot": "Medivhs Merlot",
        "Medivh's Merlot Blue Label": "Medivhs Merlot Blue Label",
        "Kreeg's Stout Beatdown": "Kreegs Stout Beatdown",
        "Danonzo's Tel'Abim Delight": "Danonzos TelAbim Delight",
        "Danonzo's Tel'Abim Medley": "Danonzos TelAbim Medley",
        "Danonzo's Tel'Abim Surprise": "Danonzos TelAbim Surprise",
    }

    # Spell/ability names with apostrophes - temporarily remove apostrophes
    # These will be restored later in the renames section
    spell_names_with_apostrophe = {
        "Nature's Swiftness": "Natures Swiftness",
        "Slayer's Crest": "Slayers Crest",
    }

    # Pet replacements have next priority
    # only the first match will be replaced
    pet_replacements = {
        r"  ([a-zzA-Z][ a-zzA-Z]+[a-zzA-Z]) \(([a-zzA-Z]+)\) (hits|crits|misses)": r"  \g<2>'s Auto Attack (pet) \g<3>",
        # convert pet hits/crits/misses to 'Auto Attack (pet)' on the owner
        r"  ([a-zzA-Z][ a-zzA-Z]+[a-zzA-Z]) \(([a-zzA-Z]+)\)'s": r"  \g<2>'s",  # pet ability
        #r"  ([a-zzA-Z][ a-zzA-Z]+[a-zzA-Z]) \(([a-zzA-Z]+)\)'s \(([a-zzA-Z]+)\) (hits|crits|misses)": r"  \g<2>'s Pet Summoned \g<3>",  # pet ability
    }

    # You replacements have next priority
    # Only the first two matches will be replaced
    you_replacements = {
        r'.*You fail to cast.*\n': '',
        r'.*You fail to perform.*\n': '',
        r"You suffer (.*?) from your": rf"{player_name} suffers \g<1> from {player_name} (self damage) 's",
        # handle self damage
        r"Your (.*?) hits you for": rf"{player_name} (self damage) 's \g<1> hits {player_name} for",
        # handle self damage
        # handle self parry, legacy expects 'was' instead of 'is'
        r"Your (.*?) is parried by": rf"{player_name} 's \g<1> was parried by",
        r"Your (.*?) failed": rf"{player_name} 's \g<1> fails",
        r" failed. You are immune": rf" fails. {player_name} is immune",
        r" [Yy]our ": f" {player_name}'s ",
        r"You gain (.*?) from (.*?)'s": rf"{player_name} gains \g<1> from \g<2> 's",
        # handle gains from other players spells
        r"You gain (.*?) from ": rf"{player_name} gains \g<1> from {player_name}'s ",
        # handle gains from your own spells
        "You gain": f"{player_name} gains",  # handle buff gains
        "You hit": f"{player_name} hits",
        "You crit": f"{player_name} crits",
        "You are": f"{player_name} is",
        "You suffer": f"{player_name} suffers",
        "You lose": f"{player_name} loses",
        "You die": f"{player_name} dies",
        "You cast": f"{player_name} casts", # problem line, causes 2x casts recorded for self
        "You create": f"{player_name} creates",
        "You perform": f"{player_name} performs",
        "You interrupt": f"{player_name} interrupts",
        "You miss": f"{player_name} misses",
        "You attack": f"{player_name} attacks",
        "You block": f"{player_name} blocks",
        "You parry": f"{player_name} parries",
        "You dodge": f"{player_name} dodges",
        "You resist": f"{player_name} resists",
        "You absorb": f"{player_name} absorbs",
        "You reflect": f"{player_name} reflects",
        "You receive": f"{player_name} receives",
        "You deflect": f"{player_name} deflects",
        "causes you": f"causes {player_name}",
        "heals you": f"heals {player_name}",
        "hits you for": f"hits {player_name} for",
        "crits you for": f"crits {player_name} for",
        r"You have slain (.*?)!": rf"\g<1> is slain by {player_name}.",
        r"(\S)\syou\.": rf"\g<1> {player_name}.",  # non whitespace character followed by whitespace followed by you
        "You fall and lose": f"{player_name} falls and loses",
    }

    # Generic replacements have 2nd priority
    # Only the first match will be replaced
    generic_replacements = {
        r" fades from .*\.": r"\g<0>",  # some buffs/debuffs have 's in them, need to ignore these lines
        r" gains .*\)\.": r"\g<0>",  # some buffs/debuffs have 's in them, need to ignore these lines
        r" is afflicted by .*\)\.": r"\g<0>",  # some buffs/debuffs have 's in them, need to ignore these lines

        # handle 's at beginning of line by looking for [double space] [playername] [Capital letter]
        r"  ([a-zA-Z' ]*?\S)'s ([A-Z])": r"  \g<1> 's \g<2>",
        r"from ([a-zA-Z' ]*?\S)'s ([A-Z])": r"from \g<1> 's \g<2>",  # handle 's in middle of line by looking for 'from'
        r"is immune to ([a-zA-Z' ]*?\S)'s ([A-Z])": r"is immune to \g<1> 's \g<2>",  # handle 's in middle of line by looking for 'is immune to'
        r"\)'s ([A-Z])": r") 's \g<1>",  # handle 's for pets
    }


    # Renames occur last
    # Only the first match will be replaced
    renames = {
        r"'s Fireball\.": "'s Improved Fireball.",  # make fireball dot appear as a separate spell
        r"'s Flamestrike\.": "'s Improved Flamestrike.",  # make flamestrike dot appear as a separate spell
        r"'s Pyroblast\.": "'s Pyroclast Barrage.",  # make Pyroblast dot appear as a separate spell
        r"'s Immolate\.": "'s Improved Immolate.",  # make Immolate dot appear as a separate spell
        r"'s Moonfire\.": "'s Improved Moonfire.",  # make Immolate dot appear as a separate spell

        " Burning Hatred": " Burning Flesh",
        # Burning Hatred custom twow spell not in logging database so it doesn't show up
        " Fire Rune": " Fire Storm",  # Fire rune is proc from flarecore 6 set
        " Spirit Link": " Spirit Bond",  # Shaman spell
        " Pain Spike": " Intense Pain",  # Spriest spell
        " Potent Venom": " Creeper Venom",  # lower kara trinket
        " Savage Bite": " Savage Fury",  # custom druid ability

        # convert totem spells to appear as though the shaman cast them so that player gets credit
        r"  [A-Z][a-zA-Z ]* Totem [IVX]+ \((.*?)\) 's": r"  \g<1> 's",
        r" from [A-Z][a-zA-Z ]* Totem [IVX]+ \((.*?)\) 's": r" from \g<1> 's",
    }

    # Restore apostrophes for mob names
    mob_apostrophe_restore = {
        "Onyxias Elite Guard": "Onyxia's Elite Guard",
        "Sarturas Royal Guard": "Sartura's Royal Guard",
    }

    # Restore apostrophes for item/consumable names
    item_apostrophe_restore = {
        "Medivhs Merlot": "Medivh's Merlot",
        "Medivhs Merlot Blue Label": "Medivh's Merlot Blue Label",
        "Kreegs Stout Beatdown": "Kreeg's Stout Beatdown",
        "Danonzos TelAbim Delight": "Danonzo's Tel'Abim Delight",
        "Danonzos TelAbim Medley": "Danonzo's Tel'Abim Medley",
        "Danonzos TelAbim Surprise": "Danonzo's Tel'Abim Surprise",
    }

    # Restore apostrophes for spell/ability names
    spell_apostrophe_restore = {
        "Natures Swiftness": "Nature's Swiftness",
        "Slayers Crest": "Slayer's Crest",
    }


    # add quantity 1 to loot messages without quantity
    loot_replacements = {
        r"\|h\|r\.$": "|h|rx1.",
    }

    # create backup of original file
    backup_filename = filename.replace(".txt", "") + f".original.{int(time.time())}.txt"
    try:
        shutil.copyfile(filename, backup_filename)
        print(f"Backup created: {backup_filename}")
    except (IOError, OSError) as e:
        print(f"Warning: Could not create backup file: {e}")
        return  # Exit if we can't create backup

    # Read the contents of the file
    try:
        with open(filename, 'r', encoding='utf-8') as file:
            lines = file.readlines()
    except (IOError, OSError, UnicodeDecodeError) as e:
        print(f"Error reading file: {e}")
        return

    # collect pet names and change LOOT messages
    # 4/14 20:51:43.354  COMBATANT_INFO: 14.04.24 20:51:43&Hunter&HUNTER&Dwarf&2&PetName <- pet name
    pet_names = set()
    owner_names = set()

    ignored_pet_names = {"Razorgore the Untamed", "Deathknight Understudy", "Naxxramas Worshipper"}

    # lines = [line for line in lines if "COMBAT_START" not in line and "COMBAT_END" not in line]

    # associate common summoned pets with their owners as well
    summoned_pet_names = {"Greater Feral Spirit", "Battle Chicken", "Arcanite Dragonling"}
    for i, _ in enumerate(lines):
        # DPSMate logs have " 's" already which will break some of our parsing, remove the space
        # But only for DPSMate-style logs that have extra spaces
        if " 's" in lines[i] and not any(marker in lines[i] for marker in ["COMBATANT_INFO", "LOOT:", "ZONE_INFO"]):
            lines[i] = lines[i].replace(" 's", "'s")
        if "COMBATANT_INFO" in lines[i]:
            try:
                line_parts = lines[i].split("&")
                if len(line_parts) < 6:
                    print(f"Warning: Malformed COMBATANT_INFO line with insufficient parts: {lines[i].strip()}")
                    continue

                pet_name = line_parts[5]
                if pet_name != "nil" and pet_name not in ignored_pet_names:
                    pet_names.add(f"{pet_name}")
                    if len(line_parts) > 1:  # Ensure we have player name
                        owner_names.add(f"({line_parts[1]})")

                # remove pet name from uploaded combatant info, can cause player to not appear in logs if pet name
                # is a player name or ability name.  Don't even think legacy displays pet info anyways.
                line_parts[5] = "nil"

                # remove turtle items that won't exist
                for j, line_part in enumerate(line_parts):
                    if ":" in line_part:
                        item_parts = line_part.split(":")
                        if len(item_parts) == 4:
                            try:
                                # definitely an item, remove any itemid > 25818 or enchantid > 3000 as they won't exist
                                item_id = int(item_parts[0])
                                enchant_id = int(item_parts[1])
                                if item_id > 25818 or enchant_id >= 3000:
                                    line_parts[j] = "nil"
                            except ValueError:
                                print(f"Warning: Invalid item ID or enchant ID in: {line_part}")
                                continue

                lines[i] = "&".join(line_parts)

            except (IndexError, ValueError) as e:
                print(f"Error parsing combatant info from line: {lines[i].strip()}")
                print(f"Error details: {e}")
            except Exception as e:
                print(f"Unexpected error parsing combatant info from line: {lines[i].strip()}")
                print(f"Error details: {e}")
        elif "LOOT:" in lines[i]:
            lines[i] = handle_replacements(lines[i], loot_replacements)
        else:
            for summoned_pet_name in summoned_pet_names:
                if summoned_pet_name in lines[i]:
                    match = summoned_pet_owner_regex.search(lines[i])
                    if match:
                        pet_names.add(summoned_pet_name)
                        owner_names.add(f"({match.group(2)})")

    print(f"The following pet owners will have their pet hits/crits/misses/spells associated with them: {owner_names}")

    # Perform replacements and filtering
    # enumerate over lines to be able to modify the list in place
    filtered_lines = []

    for i, line in enumerate(lines):
        # Check if this is a cast line with spell ID
        cast_match = cast_with_id_pattern.search(line)
        should_filter = False

        if cast_match:
            # Extract spell name, ID, and action type from the cast line
            prefix = cast_match.group(1)  # "Player casts/channels/begins to cast "
            spell_name = cast_match.group(2).strip()
            spell_id = int(cast_match.group(3))

            # Always filter out 'channels' and 'begins to cast' with spell IDs
            if "channels" in prefix or "begins to cast" in prefix:
                should_filter = True
            elif "casts" in prefix:
                # Only apply greylist logic to 'casts' lines
                if spell_name in spell_id_greylist:
                    if spell_id == spell_id_greylist[spell_name]:
                        # Keep this spell but remove ID/rank and marks
                        suffix = cast_match.group(4) if cast_match.group(4) else ""  # " on target" or ""
                        # Remove raid marks from target names
                        if suffix and " on " in suffix:
                            target_part = suffix.replace(" on ", "")
                            clean_target = remove_raid_marks(target_part, raid_target_marks)
                            suffix = f" on {clean_target}" if clean_target else ""

                        if suffix and not suffix.endswith('.'):
                            line = prefix + spell_name + suffix + ".\n"
                        elif suffix and suffix.endswith('.'):
                            line = prefix + spell_name + suffix + "\n"
                        else:
                            line = prefix + spell_name + ".\n"
                    else:
                        # Wrong spell ID for this spell name, filter it out
                        should_filter = True
                else:
                    # Not in greylist, keep it but remove ID/rank and marks (normal behavior)
                    suffix = cast_match.group(4) if cast_match.group(4) else ""  # " on target" or ""
                    # Remove raid marks from target names
                    if suffix and " on " in suffix:
                        target_part = suffix.replace(" on ", "")
                        clean_target = remove_raid_marks(target_part, raid_target_marks)
                        suffix = f" on {clean_target}" if clean_target else ""

                    if suffix and not suffix.endswith('.'):
                        line = prefix + spell_name + suffix + ".\n"
                    elif suffix and suffix.endswith('.'):
                        line = prefix + spell_name + suffix + "\n"
                    else:
                        line = prefix + spell_name + ".\n"

        # Filter out unwanted line types by prefix
        if not should_filter:
            for prefix in unwanted_line_prefixes:
                if prefix in line:
                    should_filter = True
                    break

        if should_filter:
            continue  # Skip this line

        # Continue with normal processing
        # Handle names with apostrophes (highest priority to avoid parsing issues)
        line = handle_replacements(line, mob_names_with_apostrophe)
        line = handle_replacements(line, item_names_with_apostrophe)
        line = handle_replacements(line, spell_names_with_apostrophe)

        # handle pets
        for owner_name in owner_names:
            if owner_name in line:
                line = handle_replacements(line, pet_replacements)

        # if line contains you/You
        if "you" in line or "You" in line:
            line = handle_replacements(line, you_replacements)
            line = handle_replacements(line,
                                           you_replacements)  # when casting ability on yourself need to do two replacements

        # generic replacements
        line = handle_replacements(line, generic_replacements)

        # renames
        line = handle_replacements(line, renames)

        # restore apostrophes (after all other processing)
        line = handle_replacements(line, mob_apostrophe_restore)
        line = handle_replacements(line, item_apostrophe_restore)
        line = handle_replacements(line, spell_apostrophe_restore)

        # self damage - improved logic to handle edge cases
        for pattern_compiled, replacement in self_damage_patterns:
            match = pattern_compiled.search(line)
            if match:
                # Normalize names for comparison (remove extra spaces, handle case)
                name1 = ' '.join(match.group(1).strip().split())
                name4 = ' '.join(match.group(4).strip().split())

                # Check that group 1 and 4 are equal meaning the player is hitting themselves
                if name1.lower() == name4.lower() and name1:  # Ensure name is not empty
                    line = pattern_compiled.sub(replacement, line)
                    break

        # Add processed line to filtered results
        filtered_lines.append(line)

    # Write the modified text back to the file
    try:
        with open(filename, 'w', encoding='utf-8') as file:
            file.writelines(filtered_lines)
        print(f"Successfully processed {filename}")
    except (IOError, OSError) as e:
        print(f"Error writing to file: {e}")
        return

def create_zip_file(source_file, zip_filename):
    try:
        with zipfile.ZipFile(zip_filename, 'w', zipfile.ZIP_DEFLATED) as zipf:
            zipf.write(source_file, arcname=os.path.basename(source_file))
        print(f"Zip file created: {zip_filename}")
    except (IOError, OSError, zipfile.BadZipFile) as e:
        print(f"Error creating zip file: {e}")

def validate_player_name(name):
    """Validate player name - should only contain letters, spaces, and apostrophes"""
    if not name or not name.strip():
        return False
    # Allow letters, spaces, apostrophes, and common accented characters
    import string
    allowed_chars = string.ascii_letters + " '"
    return all(c in allowed_chars for c in name.strip())

def validate_filename(filename):
    """Validate filename exists and is readable"""
    if not filename or not filename.strip():
        return False
    if not os.path.exists(filename):
        return False
    if not os.path.isfile(filename):
        return False
    try:
        with open(filename, 'r', encoding='utf-8') as f:
            f.read(1)  # Try to read first character
        return True
    except (IOError, OSError, UnicodeDecodeError):
        return False

def main():
    """Main function for interactive usage"""
    # Get and validate player name
    while True:
        player_name = input("Enter player name: ").strip()
        if validate_player_name(player_name):
            break
        print("Invalid player name. Please use only letters, spaces, and apostrophes.")

    # Get and validate filename
    while True:
        filename = input("Enter filename (defaults to WoWCombatLog.txt if left empty): ").strip()
        if not filename:
            filename = 'WoWCombatLog.txt'

        if validate_filename(filename):
            break
        print(f"File '{filename}' not found or not readable. Please enter a valid filename.")

    create_zip = input("Create zip file (default y): ")

    replace_instances(player_name, filename)
    if not create_zip.strip() or create_zip.lower().startswith('y'):
        create_zip_file(filename, filename + ".zip")
    print(
        f"Messages with You/Your have been converted to {player_name}.  A backup of the original file has also been created.")

if __name__ == "__main__":
    main()
