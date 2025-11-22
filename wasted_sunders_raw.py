#!/usr/bin/env python3
"""
GUID-based Wasted Sunder Counter for World of Warcraft Combat Logs

This script analyzes combat log files with GUID format to count wasted sunder armor casts.
It tracks all sunder casts per mob GUID and counts any beyond the 5th as wasted,
but excludes refreshes (sunders cast when the debuff is about to expire).

Expected log format, uses the RAW log:
8/22 20:01:54.030  0x0000000000440A95(Qcb) casts Sunder Armor(11597)(Rank 5) on 0xF13000F1ED276B19(Greater Gloomwing).
8/22 20:01:54.033  0xF13000F1ED276B19 is afflicted by Sunder Armor (1).

Usage: python wasted_sunders_raw.py <logfile> [tank1] [tank2] ...
Example: python wasted_sunders_raw.py combat.log Maintankname Offtankname
"""

# Configuration
SUNDER_DURATION = 30  # Sunder Armor debuff lasts 30 seconds
WASTE_THRESHOLD = 22  # Only count as wasted if cast within this many seconds of last sunder

import re
import sys
from collections import defaultdict
from datetime import datetime, timedelta

def clean_player_name(name):
    """
    Clean player names by removing common suffixes like (Circle), (Triangle), (Queen), etc.
    
    Args:
        name (str): Raw player name from combat log
        
    Returns:
        str: Cleaned player name without suffix
    """
    # Remove any suffix in parentheses at the end of the name
    cleaned = re.sub(r'\s*\([^)]+\)\s*$', '', name).strip()
    return cleaned if cleaned else name

def analyze_guid_sunders(filename):
    """
    Analyze sunder armor usage by tracking casts per mob GUID.
    
    Args:
        filename (str): Path to the combat log file
        
    Returns:
        tuple: (wasted_counts, total_counts, first_counts, display_names, sunder_cast_count, successful_sunder_count, unique_mobs)
    """
    wasted_counts = defaultdict(int)
    total_counts = defaultdict(int)
    first_counts = defaultdict(int)
    display_names = {}
    mob_sunder_counts = defaultdict(int)  # Track sunders per mob GUID
    mob_names = {}  # Store mob names for debugging
    mob_last_sunder_time = {}  # Track timestamp of last sunder per mob
    sunder_cast_count = 0  # Debug counter for total casts
    successful_sunder_count = 0  # Counter for successful sunders (not missed/dodged/parried)
    pending_sunders = {}  # Track sunders that were cast but not yet resolved
    
    try:
        with open(filename, 'r', encoding='utf-8') as file:
            for line_num, line in enumerate(file, 1):
                # Extract timestamp from each line (format: 8/22 20:01:54.030)
                timestamp_match = re.match(r'(\d+/\d+\s+\d+:\d+:\d+\.\d+)', line)
                current_time = None
                if timestamp_match:
                    try:
                        # Parse timestamp (assuming current year)
                        time_str = timestamp_match.group(1)
                        current_time = datetime.strptime(f"2024/{time_str}", "%Y/%m/%d %H:%M:%S.%f")
                    except ValueError:
                        # If parsing fails, we'll skip time-based logic for this line
                        pass
                
                # Look for sunder armor casts with GUID format
                # Note: Names may contain raid marks like (Diamond) inside the parentheses
                # e.g., 0x123(Khoni(Diamond)) - we use [^()]+ to match base name, then optionally (\([^)]+\))? for the mark
                cast_match = re.search(
                    r'(0x[0-9A-Fa-f]+)\(([^()]+(?:\([^)]+\))?)\)\s+casts\s+Sunder Armor\([^)]+\)\([^)]+\)\s+on\s+(0x[0-9A-Fa-f]+)\(([^()]+(?:\([^)]+\))?)\)',
                    line,
                    re.IGNORECASE
                )
                
                if cast_match:
                    sunder_cast_count += 1
                    player_guid = cast_match.group(1)
                    raw_player_name = cast_match.group(2)
                    mob_guid = cast_match.group(3)
                    raw_mob_name = cast_match.group(4)
                    
                    # Clean both player and mob names
                    player_name = clean_player_name(raw_player_name)
                    mob_name = clean_player_name(raw_mob_name)
                    
                    # Store this sunder as pending
                    pending_sunders[player_guid] = {
                        'player_name': player_name,
                        'mob_guid': mob_guid,
                        'mob_name': mob_name,
                        'timestamp': current_time
                    }
                
                # Check for miss/dodge/parry - these negate the sunder
                miss_match = re.search(
                    r'(0x[0-9A-Fa-f]+)\'s Sunder Armor (?:was parried by|was dodged by|missed) (0x[0-9A-Fa-f]+)',
                    line,
                    re.IGNORECASE
                )
                
                if miss_match:
                    player_guid = miss_match.group(1)
                    if player_guid in pending_sunders:
                        # Remove from pending - this sunder doesn't count
                        del pending_sunders[player_guid]
                
                # Process any remaining pending sunders (these are successful)
                if not cast_match and not miss_match and pending_sunders:
                    # Process all pending sunders as successful
                    for player_guid, sunder_info in list(pending_sunders.items()):
                        successful_sunder_count += 1  # Count this as a successful sunder
                        player_name = sunder_info['player_name']
                        mob_guid = sunder_info['mob_guid']
                        mob_name = sunder_info['mob_name']
                        current_time = sunder_info['timestamp']
                        
                        # Store mob name for reference
                        mob_names[mob_guid] = mob_name
                        
                        # Increment sunder count for this mob
                        mob_sunder_counts[mob_guid] += 1
                        current_count = mob_sunder_counts[mob_guid]
                        
                        # Count total sunders for this player
                        key = player_name.lower()
                        display_names[key] = player_name
                        total_counts[key] += 1
                        
                        # Check if this is the first sunder on this mob
                        if current_count == 1:
                            first_counts[key] += 1
                        
                        # Check if this is wasted (more than 5 stacks AND cast too early)
                        if current_count > 5:
                            # Check if this is a premature cast
                            if current_time and mob_guid in mob_last_sunder_time:
                                last_sunder_time = mob_last_sunder_time[mob_guid]
                                time_since_last = (current_time - last_sunder_time).total_seconds()
                                
                                if time_since_last < WASTE_THRESHOLD:
                                    wasted_counts[key] += 1
                        
                        # Update last sunder time for this mob
                        if current_time:
                            mob_last_sunder_time[mob_guid] = current_time
                    
                    # Clear all pending sunders
                    pending_sunders.clear()
        
        print(f"- Found {sunder_cast_count} total sunder casts")
        print(f"- Successful sunders: {successful_sunder_count} (not missed/dodged/parried)")
        print(f"- Tracking {len(mob_sunder_counts)} unique mobs")
        print(f"- Total wasted sunders: {sum(wasted_counts.values())}")
                    
    except FileNotFoundError:
        print(f"Error: File '{filename}' not found.")
        return {}, {}, {}, {}, 0, 0, 0
    except Exception as e:
        print(f"Error reading file: {e}")
        return {}, {}, {}, {}, 0, 0, 0
    
    return wasted_counts, total_counts, first_counts, display_names, sunder_cast_count, successful_sunder_count, len(mob_sunder_counts)

def display_results(wasted_counts, total_counts, first_counts, display_names, tanks, sunder_cast_count, successful_sunder_count, unique_mobs):
    """
    Display the sunder statistics in four columns, sorted by true sunders.
    
    Args:
        wasted_counts: Dictionary with wasted sunder counts per player
        total_counts: Dictionary with total sunder counts per player
        first_counts: Dictionary with first sunder counts per player
        display_names: Dictionary mapping lowercase names to original case names
        tanks: List of tank names to exclude from rankings
        sunder_cast_count: Total number of sunder casts found
        successful_sunder_count: Number of successful sunders
        unique_mobs: Number of unique mobs tracked
    """
   
    # Get all unique players from all three dictionaries
    all_players = set()
    all_players.update(wasted_counts.keys())
    all_players.update(total_counts.keys())
    all_players.update(first_counts.keys())
    
    if not all_players:
        print("No sunder applications found.")
        return
    
    # Calculate true sunders for each player (total - wasted)
    true_counts = {}
    for player in all_players:
        total = total_counts.get(player, 0)
        wasted = wasted_counts.get(player, 0)
        true_counts[player] = total - wasted
    
    # Find top performers for each category (excluding tanks from total and wasted only)
    non_tank_players = [p for p in all_players if display_names[p].lower() not in [t.lower() for t in tanks]]
    
    top_total_player = max(non_tank_players, key=lambda x: total_counts.get(x, 0), default=None) if non_tank_players else None
    top_wasted_player = max(non_tank_players, key=lambda x: wasted_counts.get(x, 0), default=None) if non_tank_players else None
    top_first_player = max(all_players, key=lambda x: first_counts.get(x, 0), default=None)  # Include tanks for first sunders
    # No asterisk for True column
    
    print("\nPlayer            True  First  Landed  Wasted")
    print("-" * 45) 
    
    # Sort by true sunders (descending), then by name (ascending)
    sorted_players = sorted(all_players, 
                           key=lambda x: (-true_counts.get(x, 0), x))
    
    for player_key in sorted_players:
        player_name = display_names[player_key]
        wasted = wasted_counts.get(player_key, 0)
        total = total_counts.get(player_key, 0)
        true = true_counts.get(player_key, 0)
        first = first_counts.get(player_key, 0)
        
        # Add asterisks for top performers (no asterisk for True)
        total_str = f"*{total}" if player_key == top_total_player else str(total)
        wasted_str = f"*{wasted}" if player_key == top_wasted_player else str(wasted)
        first_str = f"*{first}" if player_key == top_first_player else str(first)
        true_str = str(true)  # No asterisk for True column
        
        # Format with fixed-width columns - accounting for asterisks in width
        formatted_name = player_name[:15].ljust(15)
        print(f"{formatted_name} {true_str:>6}  {first_str:>5} {total_str:>7} {wasted_str:>7}")
    
    # Summary statistics
    total_wasted = sum(wasted_counts.values())
    total_all = sum(total_counts.values())
    total_true = sum(true_counts.values())
    total_first = sum(first_counts.values())
    
    print("-" * 45)
    print(f"{'TOTAL':<15} {total_true:>6}  {total_first:>5} {total_all:>7} {total_wasted:>7}")

    print(f"\nTracking {unique_mobs} unique mobs and {sunder_cast_count} total sunder spell casts.")
    if tanks:
        print(f"- Tanks: {', '.join(tanks)}")
    print(f"- Tanks are excluded from Landed/Wasted ranking.")
    print(f"- Wasted sunders are those cast when a 5 stack is present\nand has more than 8 seconds left.")
    print(f"- Landed sunders are ones which did not miss/dodge/parry.")
    print(f"- True sunder count is Landed minus Wasted.")

def main():
    """Main function to handle command line arguments and run the analysis."""
    if len(sys.argv) < 2:
        print("Usage: python guid_sunder_counter.py <rawlogfile> [tank1] [tank2] ...")
        print("Example: python guid_sunder_counter.py WoWRawCombatLog.txt Maintank Offtank")
        sys.exit(1)
    
    filename = sys.argv[1]
    tanks = sys.argv[2:] if len(sys.argv) > 2 else []  # Get tank names from remaining arguments
    
    wasted_counts, total_counts, first_counts, display_names, sunder_cast_count, successful_sunder_count, unique_mobs = analyze_guid_sunders(filename)
    display_results(wasted_counts, total_counts, first_counts, display_names, tanks, sunder_cast_count, successful_sunder_count, unique_mobs)

if __name__ == "__main__":
    main()