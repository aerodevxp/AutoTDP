# AutoTDP

AutoTDP is a Bash script that adjusts AMD APU TDP dynamically with `ryzenadj` based on % of your SOC used. It is designed for Linux handheld PCs and AMD laptops, and uses real CPU and GPU utilization.

For Ally/ASUS devices, it uses WMI Platform Profiles for fans.

**See releases page for installation instructions!**

To change settings, launch the config UI, available on the desktop or with `/usr/local/bin/autotdp.sh --configui`.

In some rare cases after long sleep/suspend periods. the SMU of your APU might be bugged, forcing the TDP to be low. This is not something I can't fix nor change, as it's a firmware bug. You will have to reboot if that happens for the SMU firmware to reset. The blame is not on this script.

## Showcase

Click the thumbnail to watch the video.


[![Video](https://img.youtube.com/vi/zKW589sK05g/0.jpg)](https://www.youtube.com/watch?v=zKW589sK05g)

## Features

- Uses both CPU AND/OR GPU utilization for both CPU-bound and GPU-bound games
- Reduces TDP oscillation with a stable-sample requirement before applying changes
- TDP will increase for shader compilation and data transfers (temporarily when one CPU core is at peak usage, then slowly ramps back down)
- Supports an optional battery cap for handheld-friendly behavior away from the charger
- Loads device-specific presets from `known_devices.json`
- Includes presets for AMD handhelds and AMD laptops
- Supports selectable performance modes from the command line
- Supports game-aware tuning with Steam AppID, executable and Wine/Proton fallback detection
- Supports custom profile JSON files for user-defined tuning
- Keeps configuration in `/etc/AutoTDP/AutoTDP.config`
- Logs all actions to `/etc/AutoTDP/logs/`
- Can install itself as an optional `systemd` service
- Easy update by running /usr/local/bin/autotdp.sh --update

## Linux Compatibility

The runtime logic is distro-agnostic and relies on standard Linux interfaces:

- `/proc/stat` for CPU utilization sampling
- `/sys/class/power_supply` for charger detection
- `ryzenadj` for AMD APU power control

That means the script can run on CachyOS, SteamOS, Bazzite, Nobara, Arch, Fedora-based handheld images, Ubuntu-based laptop installs, or most other Linux distributions, as long as the required tools are installed.

`systemd` is only required if you want to use `--install`. Running the script directly does not depend on a specific distro.

## Requirements

Install these commands on your system:

- `jq`
- `ryzenadj`

## Default Config

Default config file path: `/etc/AutoTDP/AutoTDP.config`

```ini
MIN_TDP=5000
DEFAULT_TDP=10000
MAX_CPU_TDP=18000
STEP_TDP=1000
RYZENADJ_EXEC=ryzenadj
RYZENADJ_DELAY=4
MONITOR_INTERVAL=5
STABLE_SAMPLE_COUNT=2
BATTERY_MAX_TDP=18000
DEVICE_PROFILE=generic
DEVICE_PROFILE_FILE=/etc/AutoTDP/known_devices.json
PERFORMANCE_MODE=balanced
GAME_PROFILE_FILE=/etc/AutoTDP/game_profiles.json
```

Config meanings:

- `RYZENADJ_DELAY`: minimum seconds between TDP changes
- `MONITOR_INTERVAL`: CPU sampling window in seconds
- `STABLE_SAMPLE_COUNT`: how many consecutive matching samples are required before changing TDP
- `BATTERY_MAX_TDP`: max TDP when no external power is detected
- `DEVICE_PROFILE`: selected profile key or alias from the JSON file
- `DEVICE_PROFILE_FILE`: JSON file to read profiles from
- `PERFORMANCE_MODE`: selected runtime tuning mode
- `GAME_PROFILE_FILE`: JSON file with per-game tuning rules

## Known Device Profiles

The repo includes `known_devices.json` with presets for popular handheld PCs, including:

- `generic_amd_laptop_u`
- `generic_amd_laptop_hs`
- `generic_amd_laptop_hx`
- `framework_13_7840u`
- `zephyrus_g14_7940hs`
- `steam_deck`
- `rog_ally_z1_extreme`
- `rog_ally_z1`
- `legion_go_z1_extreme`
- `legion_go_z1`
- `gpd_win_4_7840u`
- `gpd_win_mini_7840u`
- `ayaneo_2s_7840u`
- `onexplayer_2_7840u`

There is also an `msi_claw_a1m` entry marked as unsupported because it uses Intel hardware and `ryzenadj` is for AMD APUs.

These presets are conservative starting points, not hard guarantees. Handheld firmware, BIOS limits, cooling and vendor EC behavior vary.

For laptops, the generic presets are intended as category-level defaults:

- `generic_amd_laptop_u`: ultrabooks and thin-and-light Ryzen U systems
- `generic_amd_laptop_hs`: balanced gaming and creator laptops with Ryzen HS chips
- `generic_amd_laptop_hx`: larger high-performance Ryzen laptops with more cooling headroom

## Performance Modes

AutoTDP supports runtime modes that change how aggressively it ramps TDP:

- `silent`: lowest ceiling and slowest response, aimed at quiet operation
- `battery`: conservative mode for unplugged use
- `balanced`: default behavior
- `performance`: faster ramp-up and higher sustained targets
- `turbo`: most aggressive mode, best used while plugged in

Mode commands:

```bash
./AutoTDP.sh --list-modes
./AutoTDP.sh --mode performance
sudo ./AutoTDP.sh --set-mode battery
```

`--mode` applies only to the current run. `--set-mode` writes the mode to `/etc/AutoTDP/AutoTDP.config` and restarts the service automatically if it is already running.

You can also override individual settings for a single run:

```bash
./AutoTDP.sh --profile generic_amd_laptop_hs --mode performance --override BATTERY_MAX_TDP=18000 --override MONITOR_INTERVAL=3
```

Supported override keys are:

- `MIN_TDP`
- `DEFAULT_TDP`
- `MAX_CPU_TDP`
- `STEP_TDP`
- `RYZENADJ_EXEC`
- `RYZENADJ_DELAY`
- `MONITOR_INTERVAL`
- `STABLE_SAMPLE_COUNT`
- `BATTERY_MAX_TDP`
- `DEVICE_PROFILE`
- `DEVICE_PROFILE_FILE`
- `PERFORMANCE_MODE`
- `GAME_PROFILE_FILE`

Profile commands:

```bash
./AutoTDP.sh --list-profiles
./AutoTDP.sh --profile rog_ally_z1_extreme --mode turbo
sudo ./AutoTDP.sh --set-profile generic_amd_laptop_hs
```

`--profile` is temporary for that run. `--set-profile` persists the selected profile to the config file.

## Steam Launch Parameters

AutoTDP can wrap a game command directly. Everything after `--` is treated as the game command, so this works well with Steam `%command%` launch options.

Example Steam launch options:

```bash
/usr/local/bin/autotdp.sh --profile rog_ally_z1_extreme --mode turbo -- %command%
```

With custom overrides:

```bash
/usr/local/bin/autotdp.sh --profile steam_deck --mode performance --override BATTERY_MAX_TDP=14000 --override MONITOR_INTERVAL=3 -- %command%
```

For an AMD laptop profile:

```bash
/usr/local/bin/autotdp.sh --profile generic_amd_laptop_hs --mode performance --override DEFAULT_TDP=22000 -- %command%
```

Behavior in Steam wrapper mode:

- AutoTDP starts monitoring in the background
- launches the game command passed by Steam
- keeps the chosen profile, mode and overrides active while the game runs
- restores the mode default TDP when the game exits

## Game Detection And Priority

AutoTDP now supports game-aware overrides through `game_profiles.json`.

Detection sources, from strongest to weakest:

1. Steam AppID from environment variables such as `SteamAppId`, `SteamGameId`, or `STEAM_COMPAT_APP_ID`
2. Executable name detection from the wrapped command or running process command line
3. Launcher type fallback such as `steam` or `wine`

Configuration priority, from strongest to weakest:

1. CLI `--override KEY=VALUE`
2. CLI `--mode` and `--profile`
3. Detected game profile from `game_profiles.json`
4. Persisted config values from `/etc/AutoTDP/AutoTDP.config`
5. Device profile defaults from `known_devices.json`
6. Built-in script defaults

This means contradictions are resolved deterministically. Example:

- if the detected Steam AppID says `turbo`, but launch options include `--mode battery`, the explicit CLI mode wins
- if a game profile changes `DEFAULT_TDP`, but launch options include `--override DEFAULT_TDP=14000`, the override wins
- if no exact game match exists, AutoTDP falls back to executable matching, then launcher matching, then the base profile

Included game profile examples:

- Steam AppID `1091500` for Cyberpunk 2077
- Steam AppID `1245620` for Elden Ring
- Steam AppID `1086940` for Baldur's Gate 3
- Steam AppID `1145360` for Hades

The bundled `game_profiles.json` also includes generic fallbacks for Steam-native and Wine/Proton-launched games.

Alternative detection methods considered:

- `SteamAppId`, `SteamGameId`, `STEAM_COMPAT_APP_ID`: best signal when launching from Steam or Proton
- `/proc/<pid>/cmdline`: useful to identify `.exe` names under Wine/Proton or native executables
- `/proc/<pid>/comm`: useful for weaker fallback classification like `wine`, `wine64-preloader`, `wineserver`, `steam`
- Wine process existence alone: useful as a last-resort hint that a Windows game is probably running, but not reliable enough for exact title detection

Steam AppID is the preferred exact-match signal whenever available.

## Custom JSON Profiles

You can point AutoTDP to your own JSON file while keeping the same structure:

```json
{
  "version": 1,
  "profiles": {
    "my_handheld": {
      "display_name": "My Custom Handheld",
      "supported": true,
      "config": {
        "MIN_TDP": 6000,
        "DEFAULT_TDP": 12000,
        "MAX_CPU_TDP": 25000,
        "STEP_TDP": 1000,
        "RYZENADJ_DELAY": 4,
        "MONITOR_INTERVAL": 4,
        "STABLE_SAMPLE_COUNT": 2,
        "BATTERY_MAX_TDP": 18000
      }
    }
  }
}
```

Then set:

```ini
DEVICE_PROFILE=my_handheld
DEVICE_PROFILE_FILE=/path/to/my_profiles.json
PERFORMANCE_MODE=balanced
GAME_PROFILE_FILE=/path/to/my_game_profiles.json
```

## Service Installation

To install AutoTDP as a `systemd` service:

```bash
sudo ./AutoTDP.sh --install
```

Check service status with:

```bash
sudo systemctl status autotdp.service
```

## Logs

Log files are stored in `/etc/AutoTDP/logs/`.

## Notes

- AutoTDP currently targets AMD handhelds that work with `ryzenadj`.
- AutoTDP now also supports AMD laptops through generic and device-specific presets.
- Device presets are intended to be editable and extended over time.
- If your handheld has unusual firmware behavior, create a custom JSON profile instead of editing the script.

## Contributing

Contributions are welcome. New handheld profiles, better conservative defaults, and distro-specific installation notes are especially useful.

