#!/usr/bin/python3

import os
import re
import shutil
import time
import zipfile


def handle_replacements(line, replacements):
    for pattern, replacement in replacements.items():
        try:
            new_text, num_subs = re.subn(pattern, replacement, line, flags=re.IGNORECASE)
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

    # letter pattern including Unicode for unit names
    L = "a-zA-Z\\u00C0-\\u017F"

    # Pet renames have next priority (for pets with same name as owner)
    pet_rename_replacements = {}

    # Greylist: For spells that appear here, only the specified ID is accepted
    # Other spells with same name but different IDs will be filtered out
    spell_id_greylist = {
        "Blood Fury": 20572,  # Only Blood Fury(20572) is kept, others like 23234 are filtered
    }

    # Raid target marks to remove from target names (from AdvancedLogger.lua)
    raid_target_marks = {"Star", "Circle", "Diamond", "Triangle", "Moon", "Square", "Cross", "Skull"}

    # Pattern to match cast lines with spell IDs - captures spell ID in group 3
    cast_with_id_pattern = re.compile(r"(.* (?:casts|channels|begins to cast|fails casting) )(.+?)\((\d+)\)(?:\(Rank \d+\))?( .*)?")

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

    # Pattern to match any "fails casting" line (with or without spell ID)
    fails_casting_pattern = re.compile(r".* fails casting ")

    # Mob names with apostrophes have top priority
    # only the first match will be replaced
    mob_names_with_apostrophe = {
        "Onyxia's Elite Guard": "Onyxias Elite Guard",
        "Sartura's Royal Guard": "Sarturas Royal Guard",
        "Medivh's Merlot Blue Label": "Medivhs Merlot Blue Label",
        "Ima'ghaol, Herald of Desolation": "Imaghaol, Herald of Desolation",
    }

    # Pet replacements have next priority
    # only the first match will be replaced
    pet_replacements = {
        rf"  ([{L}][{L} ]+[{L}]) \(([{L}]+)\) (hits|crits|misses)": r"  \g<2>'s Auto Attack (pet) \g<3>",
        rf"  Your ([{L}][{L} ]+[{L}]) \(([{L}]+)\) is dismissed.": r"  \g<2>'s \g<1> (\g<2>) is dismissed.",
        # convert pet hits/crits/misses to spell 'Auto Attack (pet)' on the owner
        rf"  ([{L}][{L} ]+[{L}]) \(([{L}]+)\)('s| 's) Arcane Missiles": r"  \g<2> 's Arcane Missiles (pet)",  # differentiate Remains trinket pet arcane missiles from caster's
        rf"  ([{L}][{L} ]+[{L}]) \(([{L}]+)\)('s| 's)": r"  \g<2> 's",  # pet ability
        rf"from ([{L}][{L} ]+[{L}]) \(([{L}]+)\)('s| 's)": r"from \g<2>\g<3>",  # pet ability
    }

    # You replacements have next priority
    # Only the first two matches will be replaced
    you_replacements = {
        r'.*You fail to cast.*\n': '',
        r'.*You fail to perform.*\n': '',
        r" You suffer (.*?) from your": rf" {player_name} suffers \g<1> from {player_name} (self damage) 's",
        # handle self damage
        r" Your (.*?) hits you for": rf" {player_name} (self damage) 's \g<1> hits {player_name} for",
        # handle self damage
        # handle self parry, legacy expects 'was' instead of 'is'
        r" Your (.*?) is parried by": rf" {player_name} 's \g<1> was parried by",
        r" Your (.*?) failed": rf" {player_name} 's \g<1> fails",
        r" failed\. You are immune": rf" fails. {player_name} is immune",
        r" [Yy]our ": f" {player_name} 's ",
        r" You gain (.*?) from (.*?)'s": rf" {player_name} gains \g<1> from \g<2> 's",
        # handle gains from other players spells
        r" You gain (.*?) from ": rf" {player_name} gains \g<1> from {player_name} 's ",
        # handle gains from your own spells
        " You gain": f" {player_name} gains",  # handle buff gains
        " You hit": f" {player_name} hits",
        " You crit": f" {player_name} crits",
        " You are": f" {player_name} is",
        " You suffer": f" {player_name} suffers",
        " You lose": f" {player_name} loses",
        " You die": f" {player_name} dies",
        " You cast": f" {player_name} casts",
        " You create": f" {player_name} creates",
        " You perform": f" {player_name} performs",
        " You interrupt": f" {player_name} interrupts",
        " You miss": f" {player_name} misses",
        " You attack": f" {player_name} attacks",
        " You block": f" {player_name} blocks",
        " You parry": f" {player_name} parries",
        " You dodge": f" {player_name} dodges",
        " You resist": f" {player_name} resists",
        " You absorb": f" {player_name} absorbs",
        " You reflect": f" {player_name} reflects",
        " You receive": f" {player_name} receives",
        "&You receive": f"&{player_name} receives",
        " You deflect": f" {player_name} deflects",
        r"was dodged\.": f"was dodged by {player_name}.",  # SPELLDODGEDOTHERSELF=%s's %s was dodged.  No 'You'
        "causes you": f"causes {player_name}",
        "heals you": f"heals {player_name}",
        "hits you for": f"hits {player_name} for",
        "crits you for": f"crits {player_name} for",
        r" You have slain (.*?)!": rf" \g<1> is slain by {player_name}.",
        r"(\S)\syou\.": rf"\g<1> {player_name}.",  # non whitespace character followed by whitespace followed by you
        " You fall and lose": f" {player_name} falls and loses",
    }

    # Generic replacements have 2nd priority
    # Only the first match will be replaced
    generic_replacements = {
        r" fades from .*\.": r"\g<0>",  # some buffs/debuffs have 's in them, need to ignore these lines
        r" gains .*\)\.": r"\g<0>",  # some buffs/debuffs have 's in them, need to ignore these lines
        r" is afflicted by .*\)\.": r"\g<0>",  # some buffs/debuffs have 's in them, need to ignore these lines

        # handle 's at beginning of line by looking for [double space] [playername] [Capital letter]
        rf"  ([{L}'\- ]*?\S)'s ([A-Z])": r"  \g<1> 's \g<2>",
        rf"from ([{L}'\- ]*?\S)'s ([A-Z])": r"from \g<1> 's \g<2>",  # handle 's in middle of line by looking for 'from'
        rf"is immune to ([{L}'\- ]*?\S)'s ([A-Z])": r"is immune to \g<1> 's \g<2>",
        # handle 's in middle of line by looking for 'is immune to'
        r"\)'s ([A-Z])": r") 's \g<1>",  # handle 's for pets
    }


    # Renames occur last
    # Only the first match will be replaced
    renames = {
        # convert totem spells to appear as though the shaman cast them so that player gets credit
        rf"  [A-Z][{L} ]* Totem [IVX]+ \((.*?)\) 's": r"  \g<1> 's",
        rf" from [A-Z][{L} ]* Totem [IVX]+ \((.*?)\) 's": r" from \g<1> 's",

        r"Lightning Strike was resisted": r"Lightning Strike (nature) was resisted",  # separate nature portion of Lightning Strike
        r"Lightning Strike (.*) Nature damage": r"Lightning Strike (nature) \g<1> Nature damage",  # separate nature portion of Lightning Strike

        "Onyxias Elite Guard": "Onyxia's Elite Guard",  # readd apostrophes
        "Sarturas Royal Guard": "Sartura's Royal Guard",
    }

    friendly_fire = {
        rf"from ([{L}]*?) 's Power Overwhelming": r"from \g<1> (self damage) 's Power Overwhelming",
        # power overwhelming causes owner to damage pet, shouldn't count as dps
    }

    # check for players hitting themselves
    self_damage = {
        rf"  ([{L}' ]*?) suffers (.*) (damage) from ([{L}' ]*?) 's": r"  \g<1> suffers \g<2> damage from \g<4> (self damage) 's",
        rf"  ([{L}' ]*?) 's (.*) (hits|crits) ([{L}' ]*?) for": r"  \g<1> (self damage) 's \g<2> \g<3> \g<4> for",
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
    pet_renames = set()  # rename pets that have the same name their owner
    pet_names = set()
    owner_names = set()

    ignored_pet_names = {"Razorgore the Untamed (", "Deathknight Understudy (", "Naxxramas Worshipper ("}

    # associate common summoned pets with their owners as well
    summoned_pet_names = {"Greater Feral Spirit", "Battle Chicken", "Arcanite Dragonling", "The Lost", "Minor Arcane Elemental", "Scytheclaw Pureborn", "Explosive Trap I", "Explosive Trap II", "Explosive Trap III"}
    summoned_pet_owner_regex = rf"([{L}][{L} ]+[{L}]) \(([{L}]+)\)"

    for i, _ in enumerate(lines):
        # DPSMate logs have " 's" already which will break some of our parsing, remove the space
        # But only for DPSMate-style logs that have extra spaces
        if " 's" in lines[i] and not any(marker in lines[i] for marker in ["COMBATANT_INFO", "LOOT:", "ZONE_INFO"]):
            lines[i] = lines[i].replace(" 's", "'s")
        if "COMBATANT_INFO" in lines[i]:
            try:
                line_parts = lines[i].split("&")
                pet_name = line_parts[5]
                if pet_name != "nil" and pet_name not in ignored_pet_names:
                    owner_name = line_parts[1]
                    # rename pets that have the same name as their owner
                    if pet_name == owner_name:
                        pet_renames.add(pet_name)
                        pet_rename_replacements[rf"{pet_name} \({owner_name}\)"] = f"{pet_name}Pet ({owner_name})"

                        line_parts[5] = f"{pet_name}Pet"

                    pet_names.add(f"{pet_name}")
                    owner_names.add(f"({line_parts[1]})")
                else:
                    # remove pet name from uploaded combatant info, can cause player to not appear in logs if pet name
                    # is a player name or ability name.  Don't even think legacy displays pet info anyways.
                    line_parts[5] = "nil"

                lines[i] = "&".join(line_parts)

            except Exception as e:
                print(f"Error parsing pet name from line: {lines[i]}")
                print(e)
        elif "LOOT:" in lines[i]:
            lines[i] = handle_replacements(lines[i], loot_replacements)
        else:
            for summoned_pet_name in summoned_pet_names:
                if summoned_pet_name in lines[i]:
                    match = re.search(summoned_pet_owner_regex, lines[i])
                    if match:
                        pet_names.add(summoned_pet_name)
                        owner_names.add(f"({match.group(2)})")

    print(f"The following pet owners will have their pet hits/crits/misses/spells associated with them: {owner_names}")
    if pet_renames:
        print(f"The following pets will be renamed to avoid having the same name as their owner: {pet_renames}")

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

            # Remove raid marks from caster name in prefix
            clean_prefix = prefix
            for mark in raid_target_marks:
                clean_prefix = re.sub(rf'\({mark}\)', '', clean_prefix)
            prefix = clean_prefix

            # Always filter out 'channels', 'begins to cast', and 'fails casting' with spell IDs
            if "channels" in prefix or "begins to cast" in prefix or "fails casting" in prefix:
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

        # Filter out all "fails casting" lines (with or without spell ID)
        if not should_filter and fails_casting_pattern.search(line):
            should_filter = True

        if should_filter:
            continue  # Skip this line

        # Continue with normal processing
        # Handle names with apostrophes (highest priority to avoid parsing issues)
        line = handle_replacements(line, mob_names_with_apostrophe)

        # handle pet renames
        if pet_rename_replacements:
            line = handle_replacements(line, pet_rename_replacements)

        # handle pets
        for owner_name in owner_names:
            if owner_name in line:
                # ignore pet dying
                if "dies." in line or "is killed by" in line:
                    continue

                # check if line contains any ignored pet names
                if not any(ignored_pet_name in line for ignored_pet_name in ignored_pet_names):
                    line = handle_replacements(line, pet_replacements)

        # if line contains you/You
        if "you" in line or "You" in line or "dodged." in line:
            line = handle_replacements(line, you_replacements)
            line = handle_replacements(line,
                                           you_replacements)  # when casting ability on yourself need to do two replacements

        # generic replacements
        line = handle_replacements(line, generic_replacements)

        # renames
        line = handle_replacements(line, renames)

        # self damage exceptions
        for pattern, replacement in friendly_fire.items():
            match = re.search(pattern, line)
            if match:
                line = handle_replacements(line, {pattern: replacement})
                break

        # self damage
        for pattern, replacement in self_damage.items():
            match = re.search(pattern, line)
            # check that group 1 and 4 are equal meaning the player is hitting themselves
            if match and match.group(1).strip() == match.group(4).strip():
                line = handle_replacements(line, {pattern: replacement})
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
