#!/bin/bash

set -u

# Configuration
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
CONFIG_DIR="/etc/AutoTDP"  # Shared configuration directory
CONFIG_FILE="$CONFIG_DIR/AutoTDP.config"
KNOWN_DEVICES_FILE="$CONFIG_DIR/known_devices.json"
KNOWN_DEVICES_SOURCE_FILE="$SCRIPT_DIR/known_devices.json"
GAME_PROFILES_FILE="$CONFIG_DIR/game_profiles.json"
GAME_PROFILES_SOURCE_FILE="$SCRIPT_DIR/game_profiles.json"
LOG_DIR="$CONFIG_DIR/logs"
LOG_FILE="$LOG_DIR/tdp_manager_$(date +'%Y-%m-%d_%H-%M-%S').log"  # New log file per run
REQUIRED_PACKAGES=("jq" "sudo" "ryzenadj")
CONFIG_LAUNCHER="/usr/local/bin/autotdp-configui"
DESKTOP_FILE="/usr/share/applications/autotdp-config.desktop"

# Global variables
MIN_TDP=5000
DEFAULT_TDP=10000
MAX_CPU_TDP=18000
STEP_TDP=1000  # Step increment for TDP adjustments

RYZENADJ_EXEC=ryzenadj
RYZENADJ_DELAY=4  # Delay in seconds between adjustments
MONITOR_INTERVAL=3
STABLE_SAMPLE_COUNT=2
BATTERY_MAX_TDP=$MAX_CPU_TDP
DEVICE_PROFILE="generic"
DEVICE_PROFILE_FILE="$KNOWN_DEVICES_FILE"
PERFORMANCE_MODE="balanced"
GAME_PROFILE_FILE="$GAME_PROFILES_FILE"
SKIP_CLEANUP=0
CLI_PROFILE_OVERRIDE=""
CLI_MODE_OVERRIDE=""
PERSIST_PROFILE=0
PERSIST_MODE=0
TEST_MODE=0
ACTION="run"
EXIT_STATUS=0
MONITOR_PID=0
declare -a CLI_OVERRIDES=()
declare -a GAME_COMMAND=()

BASE_MIN_TDP=$MIN_TDP
BASE_DEFAULT_TDP=$DEFAULT_TDP
BASE_MAX_CPU_TDP=$MAX_CPU_TDP
BASE_STEP_TDP=$STEP_TDP
BASE_RYZENADJ_EXEC=$RYZENADJ_EXEC
BASE_RYZENADJ_DELAY=$RYZENADJ_DELAY
BASE_MONITOR_INTERVAL=$MONITOR_INTERVAL
BASE_STABLE_SAMPLE_COUNT=$STABLE_SAMPLE_COUNT
BASE_BATTERY_MAX_TDP=$BATTERY_MAX_TDP
BASE_PERFORMANCE_MODE=$PERFORMANCE_MODE

CURRENT_GAME_PROFILE=""
CURRENT_GAME_SOURCE=""
CURRENT_GAME_MATCH=""
CURRENT_GAME_NAME=""

ACTIVE_DEFAULT_TDP=$DEFAULT_TDP
ACTIVE_MAX_TDP=$MAX_CPU_TDP
ACTIVE_BATTERY_MAX_TDP=$BATTERY_MAX_TDP
ACTIVE_RYZENADJ_DELAY=$RYZENADJ_DELAY
ACTIVE_MONITOR_INTERVAL=$MONITOR_INTERVAL
ACTIVE_STABLE_SAMPLE_COUNT=$STABLE_SAMPLE_COUNT
ACTIVE_THRESHOLD_OFFSET=0

SERVICE_FILE="/etc/systemd/system/autotdp.service"
SCRIPT_DEST="/usr/local/bin/autotdp.sh"
UPDATE_URL="https://raw.githubusercontent.com/aerodevxp/AutoTDP/refs/heads/main/AutoTDP.sh"
UPDATE_CHECK_INTERVAL=21600  # Check for updates every 6 hours

# ASUS WMI interface paths
ASUS_ARMORY_WMI_BASE="/sys/class/firmware-attributes/asus-armoury/attributes"
PLATFORM_PROFILE_CHOICES_PATH="/sys/firmware/acpi/platform_profile_choices"
PLATFORM_PROFILE_PATH="/sys/firmware/acpi/platform_profile"

# MCU powersave paths (checked in order)
MCU_POWERSAVE_PATHS=(
    "/sys/devices/platform/asus-nb-wmi/mcu_powersave"
    "${ASUS_ARMORY_WMI_BASE}/mcu_powersave/current_value"
)

# TDP interface (detected at startup)
USE_WMI_TDP=0
WMI_FAST_PATH=""
WMI_SLOW_PATH=""
WMI_STAPM_PATH=""
WMI_HAS_LOW_POWER=0

print_usage() {
    cat <<EOF
Usage: $0 [options]

Options:
  --install                 Install AutoTDP as a systemd service
  --configui                  UI to setup the configuration located at \"$CONFIG_FILE\"
  --update                  Check for and install script updates from the aerodevxp repo
  --mode <name>             Run with a temporary mode override
  --set-mode <name>         Persist the selected mode to the config file
  --profile <name>          Run with a temporary device profile override
  --set-profile <name>      Persist the selected profile to the config file
  --override KEY=VALUE      Override any supported setting for this run
  --list-modes              Print available performance modes
  --list-profiles           Print available device profiles
  -- <command ...>          Run a game or app while AutoTDP monitors it
  --help                    Show this help message
  --test                    For Debugging purposes
EOF
}

parse_arguments() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --)
                shift
                GAME_COMMAND=("$@")
                break
                ;;
            --install)
                ACTION="install"
                ;;
            --update)
                ACTION="update"
                ;;
            --configui)
                ACTION="configui"
                ;;
            --mode)
                CLI_MODE_OVERRIDE=${2:-}
                if [[ -z "$CLI_MODE_OVERRIDE" ]]; then
                    echo "Missing value for --mode" >&2
                    exit 1
                fi
                shift
                ;;
            --set-mode)
                CLI_MODE_OVERRIDE=${2:-}
                PERSIST_MODE=1
                ACTION="configure"
                if [[ -z "$CLI_MODE_OVERRIDE" ]]; then
                    echo "Missing value for --set-mode" >&2
                    exit 1
                fi
                shift
                ;;
            --profile)
                CLI_PROFILE_OVERRIDE=${2:-}
                if [[ -z "$CLI_PROFILE_OVERRIDE" ]]; then
                    echo "Missing value for --profile" >&2
                    exit 1
                fi
                shift
                ;;
            --set-profile)
                CLI_PROFILE_OVERRIDE=${2:-}
                PERSIST_PROFILE=1
                ACTION="configure"
                if [[ -z "$CLI_PROFILE_OVERRIDE" ]]; then
                    echo "Missing value for --set-profile" >&2
                    exit 1
                fi
                shift
                ;;
            --override)
                if [[ -z ${2:-} ]]; then
                    echo "Missing value for --override" >&2
                    exit 1
                fi
                CLI_OVERRIDES+=("$2")
                shift
                ;;
            --list-modes)
                ACTION="list-modes"
                ;;
            --list-profiles)
                ACTION="list-profiles"
                ;;
            --help)
                ACTION="help"
                ;;
            --test)
                TEST_MODE=1
                ;;
            *)
                echo "Unknown option: $1" >&2
                print_usage
                exit 1
                ;;
        esac
        shift
    done
}

print_modes() {
    cat <<EOF
Available modes:
  silent       Lowest ceiling, slowest ramp, best battery life
  battery      Conservative balanced mode for unplugged use
  balanced     Default mode
  performance  Faster ramp and higher sustained targets
  turbo        Most aggressive mode for plugged-in use
EOF
}

is_supported_override_key() {
    case "$1" in
        MIN_TDP|DEFAULT_TDP|MAX_CPU_TDP|STEP_TDP|RYZENADJ_EXEC|RYZENADJ_DELAY|MONITOR_INTERVAL|STABLE_SAMPLE_COUNT|BATTERY_MAX_TDP|DEVICE_PROFILE|DEVICE_PROFILE_FILE|PERFORMANCE_MODE|GAME_PROFILE_FILE)
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

apply_cli_overrides() {
    local phase=$1
    local override_entry
    local override_key
    local override_value

    for override_entry in "${CLI_OVERRIDES[@]}"; do
        if [[ $override_entry != *=* ]]; then
            log "Invalid override syntax: $override_entry"
            exit 1
        fi

        override_key=${override_entry%%=*}
        override_value=${override_entry#*=}

        if ! is_supported_override_key "$override_key"; then
            log "Unsupported override key: $override_key"
            exit 1
        fi

        if [[ $phase == "pre-profile" ]]; then
            case "$override_key" in
                DEVICE_PROFILE|DEVICE_PROFILE_FILE)
                    ;;
                *)
                    continue
                    ;;
            esac
        else
            case "$override_key" in
                DEVICE_PROFILE|DEVICE_PROFILE_FILE)
                    continue
                    ;;
            esac
        fi

        printf -v "$override_key" '%s' "$override_value"
    done
}

# Function to log messages to console and log file
log() {
    local message=$1
    local timestamp
    timestamp=$(date +'%Y-%m-%d %H:%M:%S')
    echo "$timestamp - $message"
    printf '%s - %s\n' "$timestamp" "$message" | run_privileged tee -a "$LOG_FILE" > /dev/null
}

run_privileged() {
    if [[ $EUID -eq 0 ]]; then
        "$@"
    else
        sudo "$@"
    fi
}

elevate_privileges() {
    if [[ $EUID -ne 0 ]]; then
        exec sudo --preserve-env=PATH bash "$0" "$@"
    fi
}

# Function to check if required packages are installed
check_packages() {
    local missing_packages=()
    for package in "${REQUIRED_PACKAGES[@]}"; do
        if ! command -v "$package" &> /dev/null; then
            missing_packages+=("$package")
        fi
    done

    if [ ${#missing_packages[@]} -ne 0 ]; then
        log "Missing packages: ${missing_packages[*]}"
        log "Please install the missing packages and try again."
        exit 1
    fi
}



# Detect whether to use ASUS WMI or ryzenadj for TDP control
detect_tdp_interface() {
    local fast_path readback

    # Prefer ASUS Armoury WMI (newer interface)
    fast_path="$ASUS_ARMORY_FAST_WMI_PATH"
    [[ -f "$UPDATED_ASUS_ARMORY_FAST_WMI_PATH" ]] && fast_path="$UPDATED_ASUS_ARMORY_FAST_WMI_PATH"

    if [[ -f "$fast_path" ]] && [[ -f "$ASUS_ARMORY_SLOW_WMI_PATH" ]] && [[ -f "$ASUS_ARMORY_STAPM_WMI_PATH" ]]; then
        # Test writability: write 20W and verify it actually took effect
        printf '20\n' > "$ASUS_ARMORY_STAPM_WMI_PATH" 2>/dev/null
        readback=$(cat "$ASUS_ARMORY_STAPM_WMI_PATH" 2>/dev/null)
        if [[ "$readback" == "20" ]]; then
            USE_WMI_TDP=1
            WMI_FAST_PATH="$fast_path"
            WMI_SLOW_PATH="$ASUS_ARMORY_SLOW_WMI_PATH"
            WMI_STAPM_PATH="$ASUS_ARMORY_STAPM_WMI_PATH"

            if [[ -f "$PLATFORM_PROFILE_CHOICES_PATH" ]] && grep -q "low-power" "$PLATFORM_PROFILE_CHOICES_PATH" 2>/dev/null; then
                WMI_HAS_LOW_POWER=1
            fi
            log "Using ASUS Armoury WMI for TDP control"
            return 0
        else
            log "ASUS Armoury WMI detected but not writable (wrote 20, read '$readback'), trying legacy WMI"
        fi
    fi

    # Legacy WMI — also test with a known value
    if [[ -f "$FAST_WMI_PATH" ]] && [[ -f "$SLOW_WMI_PATH" ]] && [[ -f "$STAPM_WMI_PATH" ]]; then
        printf '20\n' > "$STAPM_WMI_PATH" 2>/dev/null
        readback=$(cat "$STAPM_WMI_PATH" 2>/dev/null)
        if [[ "$readback" == "20" ]]; then
            USE_WMI_TDP=1
            WMI_FAST_PATH="$FAST_WMI_PATH"
            WMI_SLOW_PATH="$SLOW_WMI_PATH"
            WMI_STAPM_PATH="$STAPM_WMI_PATH"
            log "Using legacy ASUS WMI for TDP control"
            return 0
        else
            log "Legacy ASUS WMI detected but not writable, falling back to ryzenadj"
        fi
    fi

    log "Using ryzenadj for TDP control"
}



# Set TDP via ryzenadj
set_tdp() {
    local value=$1
    if (( value < BASE_MIN_TDP )); then
        value=$BASE_MIN_TDP
    fi
    if run_privileged "$RYZENADJ_EXEC" --stapm-limit "$value" --fast-limit "$value" --slow-limit "$value"; then
        TDP_LOG="ryzenadj ${value}mW"
    else
        TDP_LOG="ryzenadj FAILED ${value}mW"
    fi
}

# Set ACPI platform profile to match TDP range (fan curves, voltage, etc.)
set_platform_profile() {
    local tdp_w=$(($1 / 1000))
    local profile

    if [[ ! -f "$PLATFORM_PROFILE_PATH" ]]; then
        return 0
    fi

    # Read available profiles
    local choices=""
    if [[ -f "$PLATFORM_PROFILE_CHOICES_PATH" ]]; then
        choices=$(cat "$PLATFORM_PROFILE_CHOICES_PATH" 2>/dev/null)
    fi

    # Map TDP to profile, adapting to available names
    if (( tdp_w < 13 )); then
        # low-power / quiet
        if echo "$choices" | grep -q "low-power"; then
            profile="low-power"
        elif echo "$choices" | grep -q "quiet"; then
            profile="quiet"
        else
            return 0
        fi
    elif (( tdp_w < 20 )); then
        # balanced
        if echo "$choices" | grep -q "balanced"; then
            profile="balanced"
        else
            return 0
        fi
    else
        # performance
        if echo "$choices" | grep -q "performance"; then
            profile="performance"
        else
            return 0
        fi
    fi

    # Only write if different from current
    local current
    current=$(cat "$PLATFORM_PROFILE_PATH" 2>/dev/null)
    if [[ "$current" != "$profile" ]]; then
        printf '%s' "$profile" > "$PLATFORM_PROFILE_PATH" 2>/dev/null && \
            log "Platform profile set to $profile"
    fi
}

# Enable MCU powersave for suspend power savings
set_mcu_powersave() {
    local path
    for path in "${MCU_POWERSAVE_PATHS[@]}"; do
        if [[ -w "$path" ]]; then
            #itd be 1, but it looks like it's breaking SMU control on awake
            if printf '0' > "$path" 2>/dev/null; then
                log "MCU powersave enabled via $path"
                return 0
            fi
        fi
    done
    # Not an error if path doesn't exist — non-ASUS devices won't have it
}

# Reads per-core cumulative CPU times as a single snapshot string
read_core_snapshot() {
    awk '/^cpu[0-9]+/ {printf "%s %s ", $2+$3+$4+$5+$6+$7+$8+$9, $5} END {print ""}' /proc/stat
}


# Computes the busiest single core's busy percentage against the previous snapshot.
get_max_cpu_usage() {
    local previous=$1
    local current
    local top4=0 peak=0 breadth=0
    local i n td id busy pct
    local -a pts cts pcts

    current=$(read_core_snapshot)

    read -r -a pts <<< "$previous"
    read -r -a cts <<< "$current"

    n=$(( ${#cts[@]} / 2 ))

    if (( ${#pts[@]} == ${#cts[@]} && n > 0 )); then
        for ((i=0; i<n; i++)); do
            td=$(( ${cts[i*2]} - ${pts[i*2]} ))
            id=$(( ${cts[i*2+1]} - ${pts[i*2+1]} ))
            if (( td <= 0 )); then
                continue
            fi
            busy=$((td - id))
            (( busy < 0 )) && busy=0
            pct=$(( busy * 100 / td ))
            pcts+=("$pct")
            (( pct > peak )) && peak=$pct
            (( pct >= 40 )) && breadth=$((breadth + 1))
        done

        if (( ${#pcts[@]} > 0 )); then
            top4=$(printf '%s\n' "${pcts[@]}" | sort -rn | head -4 | awk '{s+=$1} END {printf "%d", s / NR}')
        fi
    fi

    echo "$top4 $breadth $peak $current"
}


# Trimmed mean of args (drops high and low); sets TM_RESULT. No forks.
trimmed_mean() {
    local sum=0 lo=999999 hi=0 v
    for v in "$@"; do
        (( v < lo )) && lo=$v
        (( v > hi )) && hi=$v
        (( sum += v ))
    done
    if (( $# > 2 )); then
        TM_RESULT=$(( (sum - lo - hi) / ($# - 2) ))
    else
        TM_RESULT=$(( $# > 0 ? sum / $# : 0 ))
    fi
}

# Pure-bash /proc/stat reader; sets SNAPSHOT. No forks.
read_core_snapshot() {
    local line
    SNAPSHOT=""
    while read -r line; do
        case "$line" in
            cpu[0-9]*)
                set -- $line
                SNAPSHOT+="$(( $2+$3+$4+$5+$6+$7+$8+$9 )) $(( $5+$6 )) "
                ;;
        esac
    done < /proc/stat
}

get_max_cpu_usage() {
    local previous=$1 current
    local peak=0 t1=0 t2=0 t3=0 t4=0
    local i n td id busy pct
    local -a pts cts

    read_core_snapshot
    current=$SNAPSHOT

    read -r -a pts <<< "$previous"
    read -r -a cts <<< "$current"

    n=$(( ${#cts[@]} / 2 ))

    if (( ${#pts[@]} == ${#cts[@]} && n > 0 )); then
        for ((i=0; i<n; i++)); do
            td=$(( ${cts[i*2]} - ${pts[i*2]} ))
            id=$(( ${cts[i*2+1]} - ${pts[i*2+1]} ))
            (( td <= 0 )) && continue
            busy=$((td - id))
            (( busy < 0 )) && busy=0
            pct=$(( busy * 100 / td ))
            (( pct > peak )) && peak=$pct
            if (( pct >= t1 )); then t4=$t3; t3=$t2; t2=$t1; t1=$pct
            elif (( pct >= t2 )); then t4=$t3; t3=$t2; t2=$pct
            elif (( pct >= t3 )); then t4=$t3; t3=$pct
            elif (( pct >= t4 )); then t4=$pct
            fi
        done
    fi

    CUR_TOP4=$(( (t1 + t2 + t3 + t4) / 4 ))
    CUR_PEAK=$peak
    CUR_SNAPSHOT=$current
}

# Max GPU busy% across cards; sets MAX_GPU. No forks.
get_max_gpu_usage() {
    local f gpu_pct
    MAX_GPU=0
    for f in /sys/class/drm/card*/device/gpu_busy_percent; do
        [[ -r "$f" ]] || continue
        read -r gpu_pct < "$f" 2>/dev/null || continue
        (( gpu_pct > MAX_GPU )) && MAX_GPU=$gpu_pct
    done
}

is_on_external_power() {
    local supply
    local supply_type
    local online

    for supply in /sys/class/power_supply/*; do
        [[ -d "$supply" && -r "$supply/type" && -r "$supply/online" ]] || continue
        read -r supply_type < "$supply/type" || continue

        case "$supply_type" in
            Mains|USB|USB_C|USB_PD|Wireless)
                read -r online < "$supply/online" || continue
                if [[ $online == "1" ]]; then
                    return 0
                fi
                ;;
        esac
    done

    return 1
}

validate_performance_mode() {
    case "$1" in
        silent|battery|balanced|performance|turbo)
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

align_tdp_to_step() {
    local value=$1

    if (( value < MIN_TDP )); then
        value=$MIN_TDP
    fi

    echo $(( (value / STEP_TDP) * STEP_TDP ))
}

scale_tdp_value() {
    local value=$1
    local percent=$2
    local scaled=$(( (value * percent) / 100 ))

    if (( scaled < MIN_TDP )); then
        scaled=$MIN_TDP
    fi

    echo "$scaled"
}

apply_performance_mode() {
    local mode=$1
    local active_max
    local active_default
    local active_battery

    if ! validate_performance_mode "$mode"; then
        log "Unknown performance mode: $mode"
        exit 1
    fi

    case "$mode" in
        silent)
            active_max=$(scale_tdp_value "$MAX_CPU_TDP" 60)
            active_default=$(scale_tdp_value "$DEFAULT_TDP" 75)
            active_battery=$(scale_tdp_value "$BATTERY_MAX_TDP" 75)
            ACTIVE_THRESHOLD_OFFSET=15
            ACTIVE_RYZENADJ_DELAY=$((RYZENADJ_DELAY + 2))
            ACTIVE_MONITOR_INTERVAL=$MONITOR_INTERVAL
            ACTIVE_STABLE_SAMPLE_COUNT=$((STABLE_SAMPLE_COUNT + 1))
            ;;
        battery)
            active_max=$(scale_tdp_value "$MAX_CPU_TDP" 75)
            active_default=$(scale_tdp_value "$DEFAULT_TDP" 85)
            active_battery=$(scale_tdp_value "$BATTERY_MAX_TDP" 85)
            ACTIVE_THRESHOLD_OFFSET=8
            ACTIVE_RYZENADJ_DELAY=$((RYZENADJ_DELAY + 1))
            ACTIVE_MONITOR_INTERVAL=$MONITOR_INTERVAL
            ACTIVE_STABLE_SAMPLE_COUNT=$STABLE_SAMPLE_COUNT
            ;;
        balanced)
            active_max=$MAX_CPU_TDP
            active_default=$DEFAULT_TDP
            active_battery=$BATTERY_MAX_TDP
            ACTIVE_THRESHOLD_OFFSET=0
            ACTIVE_RYZENADJ_DELAY=$RYZENADJ_DELAY
            ACTIVE_MONITOR_INTERVAL=$MONITOR_INTERVAL
            ACTIVE_STABLE_SAMPLE_COUNT=$STABLE_SAMPLE_COUNT
            ;;
        performance)
            active_max=$MAX_CPU_TDP
            active_default=$(scale_tdp_value "$DEFAULT_TDP" 115)
            active_battery=$BATTERY_MAX_TDP
            ACTIVE_THRESHOLD_OFFSET=-8
            ACTIVE_RYZENADJ_DELAY=$((RYZENADJ_DELAY > 1 ? RYZENADJ_DELAY - 1 : 1))
            ACTIVE_MONITOR_INTERVAL=$MONITOR_INTERVAL
            ACTIVE_STABLE_SAMPLE_COUNT=1
            ;;
        turbo)
            active_max=$MAX_CPU_TDP
            active_default=$(scale_tdp_value "$DEFAULT_TDP" 130)
            active_battery=$(scale_tdp_value "$BATTERY_MAX_TDP" 110)
            ACTIVE_THRESHOLD_OFFSET=-15
            ACTIVE_RYZENADJ_DELAY=$((RYZENADJ_DELAY > 2 ? RYZENADJ_DELAY - 2 : 1))
            ACTIVE_MONITOR_INTERVAL=$((MONITOR_INTERVAL > 1 ? MONITOR_INTERVAL - 1 : 1))
            ACTIVE_STABLE_SAMPLE_COUNT=1
            ;;
    esac

    ACTIVE_MAX_TDP=$(align_tdp_to_step "$active_max")
    ACTIVE_DEFAULT_TDP=$(align_tdp_to_step "$active_default")
    ACTIVE_BATTERY_MAX_TDP=$(align_tdp_to_step "$active_battery")

    if (( ACTIVE_DEFAULT_TDP > ACTIVE_MAX_TDP )); then
        ACTIVE_DEFAULT_TDP=$ACTIVE_MAX_TDP
    fi

    if (( ACTIVE_BATTERY_MAX_TDP > ACTIVE_MAX_TDP )); then
        ACTIVE_BATTERY_MAX_TDP=$ACTIVE_MAX_TDP
    fi

    if (( ACTIVE_STABLE_SAMPLE_COUNT <= 0 )); then
        ACTIVE_STABLE_SAMPLE_COUNT=1
    fi

    if (( ACTIVE_RYZENADJ_DELAY <= 0 )); then
        ACTIVE_RYZENADJ_DELAY=1
    fi

    if (( ACTIVE_MONITOR_INTERVAL <= 0 )); then
        ACTIVE_MONITOR_INTERVAL=1
    fi
}

install_known_device_profiles() {
    if [[ -f "$KNOWN_DEVICES_SOURCE_FILE" && ! -f "$KNOWN_DEVICES_FILE" ]]; then
        run_privileged install -m 0644 "$KNOWN_DEVICES_SOURCE_FILE" "$KNOWN_DEVICES_FILE"
    fi
}

install_game_profiles() {
    if [[ -f "$GAME_PROFILES_SOURCE_FILE" && ! -f "$GAME_PROFILES_FILE" ]]; then
        run_privileged install -m 0644 "$GAME_PROFILES_SOURCE_FILE" "$GAME_PROFILES_FILE"
    fi
}

print_device_profiles() {
    local profile_file=$1

    jq -r '
        .profiles
        | to_entries[]
        | "\(.key)\t\(.value.display_name // .key)\t\(.value.supported // true)"
    ' "$profile_file" | while IFS=$'\t' read -r key display_name supported; do
        if [[ $supported == "true" ]]; then
            printf '%s - %s\n' "$key" "$display_name"
        else
            printf '%s - %s [unsupported]\n' "$key" "$display_name"
        fi
    done
}

set_config_value() {
    local key=$1
    local value=$2
    local temp_file
    local updated=0
    local line

    temp_file=$(mktemp)

    while IFS= read -r line || [[ -n "$line" ]]; do
        if [[ $line == "$key="* ]]; then
            printf '%s=%s\n' "$key" "$value" >> "$temp_file"
            updated=1
        else
            printf '%s\n' "$line" >> "$temp_file"
        fi
    done < "$CONFIG_FILE"

    if (( updated == 0 )); then
        printf '%s=%s\n' "$key" "$value" >> "$temp_file"
    fi

    run_privileged install -m 0644 "$temp_file" "$CONFIG_FILE"
    run_privileged rm -f "$temp_file"
}

restart_service_if_running() {
    if command -v systemctl > /dev/null 2>&1 && [[ -f "$SERVICE_FILE" ]]; then
        if systemctl is-active --quiet autotdp.service; then
            run_privileged systemctl restart autotdp.service
            log "Restarted autotdp.service to apply updated configuration"
        fi
    fi
}

install_desktop_shortcut() {
    # Launcher script: password first, update, then UI
    run_privileged tee "$CONFIG_LAUNCHER" > /dev/null <<'EOF'
#!/bin/bash
# AutoTDP config launcher: update, then open the configuration UI
SELF=/usr/local/bin/autotdp.sh

# Ask for the sudo password up front so everything after runs unattended
if [[ $EUID -ne 0 ]]; then
    sudo -v || { echo "sudo authentication required to configure AutoTDP"; exit 1; }
fi

# Self-update (validates the download before installing; safe to run every time)
sudo "$SELF" --update

# Launch the config UI (reuses the cached sudo credential)
exec sudo "$SELF" --configui
EOF
    run_privileged chmod 0755 "$CONFIG_LAUNCHER"

    # Desktop entry — Terminal=true makes the DE open it in a terminal,
    # which whiptail needs, and gives sudo a place to prompt
    run_privileged tee "$DESKTOP_FILE" > /dev/null <<'EOF'
[Desktop Entry]
Type=Application
Name=AutoTDP Configuration
Comment=Update AutoTDP and edit its configuration
Exec=/usr/local/bin/autotdp-configui
Icon=preferences-system-power
Terminal=true
Categories=System;Settings;
Keywords=tdp;power;handheld;autotdp;
EOF
    run_privileged chmod 0644 "$DESKTOP_FILE"

    # Best-effort copy onto the invoking user's actual Desktop, if one exists
    if [[ -n "${SUDO_USER:-}" ]]; then
        local user_desktop
        user_desktop=$(getent passwd "$SUDO_USER" | cut -d: -f6)/Desktop
        if [[ -d "$user_desktop" ]]; then
            run_privileged install -m 0644 -o "$SUDO_USER" -g "$(id -gn "$SUDO_USER")" \
                "$DESKTOP_FILE" "$user_desktop/autotdp-config.desktop"
        fi
    fi

    log "Desktop shortcut installed: $DESKTOP_FILE"
}

read_env_value_from_pid() {
    local pid=$1
    local env_key=$2

    tr '\0' '\n' < "/proc/$pid/environ" 2> /dev/null | while IFS='=' read -r key value; do
        if [[ $key == "$env_key" ]]; then
            printf '%s\n' "$value"
            break
        fi
    done
}

detect_steam_appid_from_environment() {
    local candidate

    for candidate in "${SteamAppId:-}" "${SteamGameId:-}" "${STEAM_COMPAT_APP_ID:-}"; do
        if [[ -n "$candidate" && "$candidate" != "0" ]]; then
            printf '%s\n' "$candidate"
            return 0
        fi
    done

    return 1
}

detect_steam_appid_from_processes() {
    return 1
    local pid env_data
    for pid_path in /proc/[0-9]*; do
        pid=${pid_path##*/}
        [[ -r "/proc/$pid/environ" ]] || continue
        env_data=$(tr '\0' '\n' < "/proc/$pid/environ" 2> /dev/null)

        for key in SteamAppId SteamGameId STEAM_COMPAT_APP_ID; do
            local candidate
            candidate=$(printf '%s\n' "$env_data" | awk -F= -v k="$key" '$1 == k {print $2; exit}')
            if [[ -n "$candidate" && "$candidate" != "0" ]]; then
                printf '%s\n' "$candidate"
                return 0
            fi
        done
    done
    return 1
}

normalize_executable_name() {
    local value=$1
    value=${value##*/}
    printf '%s\n' "$value" | tr '[:upper:]' '[:lower:]'
}

extract_executable_from_cmdline() {
    local raw_cmdline=$1
    local entry

    IFS=$'\n'
    for entry in $raw_cmdline; do
        if [[ $entry == *.exe || $entry == *.EXE ]]; then
            normalize_executable_name "$entry"
            return 0
        fi
    done
    unset IFS

    return 1
}

detect_executable_from_wrapped_command() {
    local entry

    for entry in "${GAME_COMMAND[@]}"; do
        if [[ $entry == *.exe || $entry == *.EXE ]]; then
            normalize_executable_name "$entry"
            return 0
        fi
    done

    if (( ${#GAME_COMMAND[@]} > 0 )); then
        normalize_executable_name "${GAME_COMMAND[0]}"
        return 0
    fi

    return 1
}

detect_executable_from_processes() {
    local pid
    local cmdline
    local candidate

    for pid_path in /proc/[0-9]*; do
        pid=${pid_path##*/}
        [[ -r "/proc/$pid/cmdline" ]] || continue
        cmdline=$(tr '\0' '\n' < "/proc/$pid/cmdline" 2> /dev/null)
        [[ -n "$cmdline" ]] || continue

        candidate=$(extract_executable_from_cmdline "$cmdline")
        if [[ -n "$candidate" ]]; then
            printf '%s\n' "$candidate"
            return 0
        fi
    done

    return 1
}

detect_launcher_type() {
    local pid
    local comm

    for pid_path in /proc/[0-9]*; do
        pid=${pid_path##*/}
        [[ -r "/proc/$pid/comm" ]] || continue
        read -r comm < "/proc/$pid/comm" || continue
        comm=$(printf '%s' "$comm" | tr '[:upper:]' '[:lower:]')

        case "$comm" in
            wineserver|wine|wine64|wine64-preloader|winedevice)
                printf '%s\n' "wine"
                return 0
                ;;
            steam|steamwebhelper)
                printf '%s\n' "steam"
                return 0
                ;;
        esac
    done

    return 1
}

apply_game_profile_from_json() {
    local jq_expression=$1
    local match_value=$2
    local resolved_profile
    local assignments

    resolved_profile=$(jq -r --arg match "$match_value" "$jq_expression" "$GAME_PROFILE_FILE")
    if [[ -z "$resolved_profile" || "$resolved_profile" == "null" ]]; then
        return 1
    fi

    assignments=$(jq -r --arg key "$resolved_profile" '
        .profiles[$key].config
        | to_entries[]
        | select(.value != null)
        | "\(.key)=\(.value | @sh)"
    ' "$GAME_PROFILE_FILE")

    if [[ -n "$assignments" ]]; then
        eval "$assignments"
    fi

    CURRENT_GAME_PROFILE=$resolved_profile
    CURRENT_GAME_NAME=$(jq -r --arg key "$resolved_profile" '.profiles[$key].display_name // $key' "$GAME_PROFILE_FILE")
    return 0
}

reset_to_base_configuration() {
    MIN_TDP=$BASE_MIN_TDP
    DEFAULT_TDP=$BASE_DEFAULT_TDP
    MAX_CPU_TDP=$BASE_MAX_CPU_TDP
    STEP_TDP=$BASE_STEP_TDP
    RYZENADJ_EXEC=$BASE_RYZENADJ_EXEC
    RYZENADJ_DELAY=$BASE_RYZENADJ_DELAY
    MONITOR_INTERVAL=$BASE_MONITOR_INTERVAL
    STABLE_SAMPLE_COUNT=$BASE_STABLE_SAMPLE_COUNT
    BATTERY_MAX_TDP=$BASE_BATTERY_MAX_TDP
    PERFORMANCE_MODE=$BASE_PERFORMANCE_MODE
    CURRENT_GAME_PROFILE=""
    CURRENT_GAME_SOURCE=""
    CURRENT_GAME_MATCH=""
    CURRENT_GAME_NAME=""
}

resolve_active_game_profile() {
    local detected_appid=""
    local detected_executable=""
    local detected_launcher=""
    local previous_signature="${CURRENT_GAME_SOURCE}:${CURRENT_GAME_MATCH}:${CURRENT_GAME_PROFILE}"
    local new_signature

    reset_to_base_configuration

    if [[ -f "$GAME_PROFILE_FILE" ]] && jq empty "$GAME_PROFILE_FILE" > /dev/null 2>&1; then
        detected_appid=$(detect_steam_appid_from_environment || true)
        if [[ -z "$detected_appid" && ${#GAME_COMMAND[@]} -eq 0 ]]; then
            detected_appid=$(detect_steam_appid_from_processes || true)
        fi

        if [[ -n "$detected_appid" ]]; then
            if apply_game_profile_from_json '.steam_appids[$match].profile // empty' "$detected_appid"; then
                CURRENT_GAME_SOURCE="steam_appid"
                CURRENT_GAME_MATCH=$detected_appid
            fi
        fi

        if [[ -z "$CURRENT_GAME_PROFILE" ]]; then
            if (( ${#GAME_COMMAND[@]} > 0 )); then
                detected_executable=$(detect_executable_from_wrapped_command || true)
            else
                detected_executable=$(detect_executable_from_processes || true)
            fi

            if [[ -n "$detected_executable" ]]; then
                if apply_game_profile_from_json '.executables[$match].profile // empty' "$detected_executable"; then
                    CURRENT_GAME_SOURCE="executable"
                    CURRENT_GAME_MATCH=$detected_executable
                fi
            fi
        fi

        if [[ -z "$CURRENT_GAME_PROFILE" ]]; then
            detected_launcher=$(detect_launcher_type || true)
            if [[ -n "$detected_launcher" ]]; then
                if apply_game_profile_from_json '.launcher_types[$match].profile // empty' "$detected_launcher"; then
                    CURRENT_GAME_SOURCE="launcher_type"
                    CURRENT_GAME_MATCH=$detected_launcher
                fi
            fi
        fi
    fi

    apply_cli_overrides "post-profile"

    if [[ -n "$CLI_MODE_OVERRIDE" ]]; then
        PERFORMANCE_MODE=$CLI_MODE_OVERRIDE
    fi

    apply_performance_mode "$PERFORMANCE_MODE"

    new_signature="${CURRENT_GAME_SOURCE}:${CURRENT_GAME_MATCH}:${CURRENT_GAME_PROFILE}"
    if [[ "$new_signature" != "$previous_signature" ]]; then
        if [[ -n "$CURRENT_GAME_PROFILE" ]]; then
            log "Applied game profile: $CURRENT_GAME_NAME via $CURRENT_GAME_SOURCE ($CURRENT_GAME_MATCH)"
        elif [[ -n "$previous_signature" && "$previous_signature" != "::" ]]; then
            log "No active game profile detected, falling back to base configuration"
        fi
    fi
}

run_wrapped_command() {
    log "Launching wrapped command: ${GAME_COMMAND[*]}"
    monitor_and_adjust &
    MONITOR_PID=$!

    "${GAME_COMMAND[@]}"
    EXIT_STATUS=$?
}

resolve_device_profile_name() {
    local profile_file=$1
    local requested_name=$2

    jq -r --arg requested_name "$requested_name" '
        if .profiles[$requested_name] then
            $requested_name
        else
            (.profiles | to_entries | map(select((.value.aliases // []) | index($requested_name))) | .[0].key // empty)
        end
    ' "$profile_file"
}

apply_device_profile() {
    local profile_file=$1
    local requested_profile=$2
    local resolved_profile
    local supported
    local display_name
    local assignments
    local unsupported_reason

    [[ -n "$requested_profile" ]] || return 0

    if [[ ! -f "$profile_file" ]]; then
        log "Device profile file not found: $profile_file"
        exit 1
    fi

    if ! jq empty "$profile_file" > /dev/null 2>&1; then
        log "Invalid device profile JSON: $profile_file"
        exit 1
    fi

    resolved_profile=$(resolve_device_profile_name "$profile_file" "$requested_profile")
    if [[ -z "$resolved_profile" ]]; then
        log "Unknown device profile: $requested_profile"
        exit 1
    fi

    supported=$(jq -r --arg profile "$resolved_profile" '.profiles[$profile].supported // true' "$profile_file")
    if [[ $supported != "true" ]]; then
        unsupported_reason=$(jq -r --arg profile "$resolved_profile" '.profiles[$profile].unsupported_reason // "Unsupported device profile"' "$profile_file")
        log "$unsupported_reason"
        exit 1
    fi

    assignments=$(jq -r --arg profile "$resolved_profile" '
        .profiles[$profile].config
        | to_entries[]
        | select(.value != null)
        | "\(.key)=\(.value | @sh)"
    ' "$profile_file")

    if [[ -n "$assignments" ]]; then
        eval "$assignments"
    fi

    display_name=$(jq -r --arg profile "$resolved_profile" '.profiles[$profile].display_name // $profile' "$profile_file")
    DEVICE_PROFILE="$resolved_profile"
    log "Loaded device profile: $display_name"
}

# Function to determine the appropriate TDP based on CPU utilization
determine_tdp() {
    local cpu_usage=$1
    local gpu_usage=$2
    local effective_usage
    local ceiling
    local tdp
    local ramp_start=20
    local ramp_full=95
    local curve_exponent=2
    local usage_span
    local usage_above_floor

    # Combine CPU and GPU demand: union formula accounts for both running together.
    # Both 40% -> 64%, one pegged 99% -> ~99%, both 70% -> 91%.
    effective_usage=$(( cpu_usage + gpu_usage - (cpu_usage * gpu_usage + 50) / 100 ))
    if (( effective_usage > 100 )); then
        effective_usage=100
    fi

    # Apply the mode's threshold offset
    effective_usage=$(( effective_usage - ACTIVE_THRESHOLD_OFFSET ))
    if (( effective_usage < 0 )); then
        effective_usage=0
    fi

    # Pick the ceiling based on power source
    if is_on_external_power; then
        ceiling=$ACTIVE_MAX_TDP
        ramp_start=20
    else
        ceiling=$ACTIVE_BATTERY_MAX_TDP
        ramp_start=30
    fi

    if (( effective_usage <= ramp_start )); then
        tdp=$MIN_TDP
    else
        usage_span=$(( ramp_full - ramp_start ))
        usage_above_floor=$(( effective_usage - ramp_start ))
        if (( usage_above_floor > usage_span )); then
            usage_above_floor=$usage_span
        fi
        tdp=$(( MIN_TDP + (ceiling - MIN_TDP) * usage_above_floor ** curve_exponent / usage_span ** curve_exponent ))
    fi

    # Enforce floor and ceiling
    if (( tdp < MIN_TDP )); then
        tdp=$MIN_TDP
    fi
    if (( tdp > ceiling )); then
        tdp=$ceiling
    fi

    echo $(( (tdp / STEP_TDP) * STEP_TDP ))
}

# Function to monitor and adjust TDP based on CPU/GPU usage
monitor_and_adjust() {
    local last_adjustment=0
    local current_tdp=$ACTIVE_DEFAULT_TDP
    local prev_snapshot
    local cycle=0
    local last_update_check=0
    local power_state=-1
    local new_power_state
    local ceiling

    # Proportional mapping: load% maps linearly onto MIN..ceiling.
    # 90% load = full ceiling, 45% = halfway, below scales toward MIN.
    local FULL_SCALE=90
    local eff_full=$FULL_SCALE

    # CPU spikes: momentary busy-core bursts earn a temporary +3W
    local SPIKE_THRESHOLD=70   # sub-sample max that counts as a spike
    local SPIKE_BONUS=3000     # +3W
    local SPIKE_HOLD=15        # seconds without spikes before bonus expires
    local last_spike=0

    local cpu_signal=0 gpu_usage=0 load=0 smooth_load=-1 sig=0 max_sig=0
    local base_target target_tdp diff
    local -a sig_samples=()
    local -a gpu_samples=()

    get_max_cpu_usage ""
    prev_snapshot=$CUR_SNAPSHOT

    set_tdp "$ACTIVE_DEFAULT_TDP"
    set_platform_profile "$ACTIVE_DEFAULT_TDP"
    current_tdp=$ACTIVE_DEFAULT_TDP
    last_adjustment=$EPOCHSECONDS

    log "Monitoring and adjusting TDP started"

    while true; do
        # Power source + ceiling, re-checked every cycle
        if is_on_external_power; then
            new_power_state=1
            ceiling=$ACTIVE_MAX_TDP
            echo 1 | sudo tee /sys/devices/system/cpu/cpufreq/boost
        else
            new_power_state=0
            ceiling=$ACTIVE_BATTERY_MAX_TDP
            echo 0 | sudo tee /sys/devices/system/cpu/cpufreq/boost
        fi
        if (( new_power_state != power_state )); then
            if (( new_power_state == 1 )); then
                log "Power source changed: AC (ceiling $((ceiling / 1000))W)"
            else
                log "Power source changed: battery (ceiling $((ceiling / 1000))W)"
            fi
            power_state=$new_power_state
            # Unplug: never sit above the battery ceiling
            if (( new_power_state == 0 && current_tdp > ceiling )); then
                set_tdp "$ceiling"
                set_platform_profile "$ceiling"
                log "Unplug clamp: $((current_tdp / 1000))W → $((ceiling / 1000))W via ${TDP_LOG}"
                current_tdp=$ceiling
                last_adjustment=$EPOCHSECONDS
            fi
        fi

        # On battery, the same game needs the same watts at the same load —
        # so the load->watt curve must hit the (lower) battery ceiling sooner.
        # Scale the full-load point by ceiling ratio: 20W/25W -> 90% becomes 72%.
        # Compress the battery curve ONLY under real GPU demand: the same
        # game needs the same watts as AC, but only when it's actually
        # pushing the GPU. Light/medium loads keep the normal curve.
        if (( new_power_state == 1 || ACTIVE_MAX_TDP <= 0 )); then
            eff_full=$FULL_SCALE
        elif (( gpu_usage >= 60 )); then
            # Clearly demanding: compress the curve
            eff_full=$(( FULL_SCALE * ceiling / ACTIVE_MAX_TDP ))
            (( eff_full < 50 )) && eff_full=50
        elif (( gpu_usage < 55 )); then
            # Clearly light: normal curve
            eff_full=$FULL_SCALE
        fi

        cycle=$((cycle + 1))
        if (( cycle % 5 == 1 )); then
            resolve_active_game_profile
        fi

        # Periodic update check
        if (( EPOCHSECONDS - last_update_check >= UPDATE_CHECK_INTERVAL )); then
            last_update_check=$EPOCHSECONDS
            if download_file "$UPDATE_URL" /tmp/autotdp_check.sh 2>/dev/null \
                && ! cmp -s /tmp/autotdp_check.sh "$SCRIPT_DEST"; then
                log "Update available upstream - run: $0 --update"
            fi
            rm -f /tmp/autotdp_check.sh
        fi

        # Sub-sample the interval; trimmed mean filters momentary spikes
        sig_samples=()
        gpu_samples=()
        max_sig=0
        for (( sub=0; sub < ACTIVE_MONITOR_INTERVAL * 2; sub++ )); do
            sleep 0.5
            get_max_cpu_usage "$prev_snapshot"
            prev_snapshot=$CUR_SNAPSHOT
            sig=$(( (CUR_TOP4 + CUR_PEAK) / 2 ))
            sig_samples+=( "$sig" )
            (( sig > max_sig )) && max_sig=$sig
            get_max_gpu_usage
            gpu_samples+=( "$MAX_GPU" )
        done

        trimmed_mean "${sig_samples[@]}"; cpu_signal=$TM_RESULT
        trimmed_mean "${gpu_samples[@]}"; gpu_usage=$TM_RESULT

        # The bottleneck sets the load: whichever of CPU or GPU is higher
        if (( gpu_usage > cpu_signal )); then
            load=$gpu_usage
        else
            load=$cpu_signal
        fi

        # Smooth between cycles so single-cycle dips don't jerk the target
        if (( smooth_load < 0 )); then
            smooth_load=$load
        else
            smooth_load=$(( (smooth_load + load) / 2 ))
        fi

        # Spike activity refreshes the bonus window
        if (( max_sig >= SPIKE_THRESHOLD)); then
            last_spike=$EPOCHSECONDS
        fi

        log "CPU: ${cpu_signal}% (spike ${max_sig}%) | GPU: ${gpu_usage}% | load: ${load}% (fulltdp@${eff_full}%) | TDP: $((current_tdp / 1000))W"

        # Re-assert limits occasionally in case the EC resets them
        if (( EPOCHSECONDS - last_adjustment > 300 )); then
            set_tdp "$current_tdp"
            last_adjustment=$EPOCHSECONDS
        fi

        # 90% load = ceiling, 45% = halfway, linear
        # --- Proportional target ---
        # Below 25% load (and GPU idle): the minimum exists precisely for this.
        if (( smooth_load < 25 )); then
            base_target=$MIN_TDP
        elif (( smooth_load >= eff_full )); then
            base_target=$ceiling
        else
            base_target=$(( MIN_TDP + (ceiling - MIN_TDP) * smooth_load / eff_full ))
        fi

        # --- Spike bonuses ---
        # Pegged core (spike >= 90 sustained): loading / decompression / compile.
        if (( max_sig >= 90 )); then
            target_tdp=$(( base_target + 6 * STEP_TDP ))
        elif (( EPOCHSECONDS - last_spike < SPIKE_HOLD )); then
            # Regular bursts: mild bonus, 15s expiry (now includes IO bursts)
            target_tdp=$(( base_target + SPIKE_BONUS ))
        else
            target_tdp=$base_target
        fi

        (( target_tdp > ceiling )) && target_tdp=$ceiling
        (( target_tdp < MIN_TDP )) && target_tdp=$MIN_TDP

        # Round to nearest watt: sub-0.5W down, 0.5W+ up
        target_tdp=$(( (target_tdp + STEP_TDP * 3 / 4) / STEP_TDP * STEP_TDP ))
        (( target_tdp < MIN_TDP )) && target_tdp=$MIN_TDP

        # Up: jump straight to target. Down: at most 2W per write.
        if (( target_tdp < current_tdp )); then
            (( current_tdp - target_tdp > 2 * STEP_TDP )) && target_tdp=$(( current_tdp - 2 * STEP_TDP ))
        fi

        # Deadband: ignore sub-0.5W churn
        diff=$(( target_tdp - current_tdp ))
        (( diff < 0 )) && diff=$(( -diff ))
        if (( diff > 500 && EPOCHSECONDS - last_adjustment >= ACTIVE_RYZENADJ_DELAY )); then
            local old_tdp=$current_tdp
            set_tdp "$target_tdp"
            set_platform_profile "$target_tdp"
            current_tdp=$target_tdp
            last_adjustment=$EPOCHSECONDS
            log "TDP: $((old_tdp / 1000))W → $((target_tdp / 1000))W via ${TDP_LOG} (load ${load}%, smooth ${smooth_load}%)"
        fi
    done
}

# Function to handle script exit
cleanup() {
    if (( SKIP_CLEANUP == 1 )); then
        exit "$EXIT_STATUS"
    fi

    if (( MONITOR_PID > 0 )); then
        kill "$MONITOR_PID" > /dev/null 2>&1 || true
        wait "$MONITOR_PID" 2> /dev/null || true
    fi

    set_tdp "$ACTIVE_DEFAULT_TDP"
    set_platform_profile "$ACTIVE_DEFAULT_TDP"
    log "Script exited, TDP reset to default for mode $PERFORMANCE_MODE"
    exit "$EXIT_STATUS"
}

# Function to install the script as a systemd service
install_service() {
    # Copy the script to the destination directory
    run_privileged install -m 0755 "$(realpath "$0")" "$SCRIPT_DEST"
    install_known_device_profiles
    install_game_profiles

    run_privileged tee "$SERVICE_FILE" > /dev/null <<EOF
[Unit]
Description=AutoTDP Service
After=network.target

[Service]
ExecStart=$SCRIPT_DEST
Restart=on-failure
User=root

[Install]
WantedBy=multi-user.target suspend.target hibernate.target
EOF

    run_privileged systemctl daemon-reload
    run_privileged systemctl enable autotdp.service
    run_privileged systemctl restart autotdp.service
    install_desktop_shortcut
    log "AutoTDP service installed and started"
}

download_file() {
    local url=$1
    local dest=$2

    if command -v curl > /dev/null 2>&1; then
        curl -fsSL --connect-timeout 10 --max-time 60 "$url" -o "$dest"
    elif command -v wget > /dev/null 2>&1; then
        wget -q --timeout=60 -O "$dest" "$url"
    else
        return 1
    fi
}

perform_self_update() {
    local tmp_file

    tmp_file=$(mktemp)

    if ! download_file "$UPDATE_URL" "$tmp_file"; then
        rm -f "$tmp_file"
        log "Self-update: download failed, keeping current version"
        return 1
    fi

    # Validate: non-empty, looks like AutoTDP, parses as valid bash
    if [[ ! -s "$tmp_file" ]] || ! grep -q "AutoTDP" "$tmp_file" || ! bash -n "$tmp_file"; then
        rm -f "$tmp_file"
        log "Self-update: downloaded file failed validation, keeping current version"
        return 1
    fi

    if [[ -f "$SCRIPT_DEST" ]] && cmp -s "$tmp_file" "$SCRIPT_DEST"; then
        rm -f "$tmp_file"
        return 0
    fi

    run_privileged install -m 0755 "$tmp_file" "$SCRIPT_DEST"
    rm -f "$tmp_file"
    log "Self-update: new version installed to $SCRIPT_DEST"

    run_privileged restorecon -v /usr/local/bin/autotdp.sh


    if command -v systemctl > /dev/null 2>&1 && [[ -f "$SERVICE_FILE" ]] \
        && systemctl is-active --quiet autotdp.service; then
        log "Self-update: restarting autotdp.service"
        run_privileged systemctl restart autotdp.service
        exit 0
    fi

    return 0
}

UI="plain"
if [[ -n "${DISPLAY:-}" || -n "${WAYLAND_DISPLAY:-}" ]]; then
    if command -v zenity >/dev/null 2>&1; then
        UI="zenity"
    elif command -v kdialog >/dev/null 2>&1; then
        UI="kdialog"
    fi
fi
[ "$UI" = "plain" ] && command -v whiptail >/dev/null 2>&1 && UI="whiptail"
[ "$UI" = "plain" ] && command -v dialog   >/dev/null 2>&1 && UI="dialog"

ui_msg() {
    case "$UI" in
        zenity)  zenity --info --title="$1" --text="$2" --width=400 ;;
        kdialog) kdialog --title "$1" --msgbox "$2" ;;
        whiptail) whiptail --title "$1" --msgbox "$2" 12 65 ;;
        dialog)  dialog --title "$1" --msgbox "$2" 12 65 ;;
        *) echo "=== $1 ==="; echo "$2"; read -rp "Press Enter..." ;;
    esac
}

ui_yesno() {
    case "$UI" in
        zenity)  zenity --question --title="$1" --text="$2" --width=400 2>/dev/null ;;
        kdialog) kdialog --title "$1" --yesno "$2" ;;
        whiptail) whiptail --title "$1" --yesno "$2" 10 60 ;;
        dialog)  dialog --title "$1" --yesno "$2" 10 60 ;;
        *) local a; read -rp "$2 [y/N]: " a; [[ "$a" =~ ^[Yy] ]] ;;
    esac
}

ui_input() {
    local title="$1" current="$2" val
    case "$UI" in
        zenity)  zenity --entry --title="$title" --text="Current value: $current" --entry-text="$current" 2>/dev/null ;;
        kdialog) kdialog --title "$title" --inputbox "Current value: $current" "$current" ;;
        whiptail) whiptail --title "$title" --inputbox "Current value: $current" 10 60 "$current" 3>&1 1>&2 2>&3 ;;
        dialog)  dialog --title "$title" --inputbox "Current value: $current" 10 60 "$current" 3>&1 1>&2 2>&3 ;;
        *) read -rp "$title [$current]: " val; echo "${val:-$current}" ;;
    esac
}


ui_menu() {
    local title="$1"; shift
    case "$UI" in
       zenity)
            local tags=() values=()
            while [ $# -gt 0 ]; do tags+=("$1"); values+=("$2"); shift 2; done
            local lines=""
            for i in "${!values[@]}"; do
                lines+="$((i+1))) ${values[$i]}"$'\n'
            done
            local result
            result=$(printf '%s' "$lines" | zenity --list --title="$title" \
                  --column="Option" \
                  --hide-header --height=600 2>/dev/null)
            [ $? -ne 0 ] && return 1
            [ -z "$result" ] && return 1
            # Extract the number from "N) description"
            local num="${result%%)*}"
            num="${num// /}"
            [ -n "$num" ] && echo "${tags[$((num-1))]}"
            ;;
        kdialog)
            local args=()
            while [ $# -gt 0 ]; do args+=("$1" "$2"); shift 2; done
            kdialog --title "$title" --menu "Select:" "${args[@]}"
            ;;
        whiptail)
            local args=()
            while [ $# -gt 0 ]; do args+=("$1" "$2"); shift 2; done
            whiptail --title "$title" --menu "Select:" 22 65 14 "${args[@]}" 3>&1 1>&2 2>&3
            ;;
        dialog)
            local args=()
            while [ $# -gt 0 ]; do args+=("$1" "$2"); shift 2; done
            dialog --title "$title" --menu "Select:" 22 65 14 "${args[@]}" 3>&1 1>&2 2>&3
            ;;
        *)
            local tags=() i=1
            while [ $# -gt 0 ]; do echo "  $i) $1  ($2)" >&2; tags+=("$1"); shift 2; done
            local n; read -rp "Choice: " n
            [ -n "$n" ] && echo "${tags[$((n-1))]}"
            ;;
    esac
}

get_key() { grep -E "^${1}=" "$CONFIG_FILE" | head -1 | cut -d= -f2-; }

set_key() { set_config_value "$1" "$2"; }

edit_tdp() { # $1=key $2=label $3=min_allowed $4=max_allowed
    local key="$1" label="$2" lo="$3" hi="$4" new
    new=$(ui_input "$label" "$(get_key "$key")") || return
    if [[ "$new" =~ ^[0-9]+$ ]] && [ "$new" -ge "$lo" ] && [ "$new" -le "$hi" ]; then
        set_key "$key" "$new"
    else
        ui_msg "Invalid" "'$new' is not valid. Must be an integer between $lo and $hi (mW)."
    fi
}

profile_active() { [ -n "$(get_key DEVICE_PROFILE)" ]; }

# --- Device profile editor ---
edit_device_profile() {
    local current profiles_file
    current=$(get_key DEVICE_PROFILE)
    profiles_file=$(get_key DEVICE_PROFILE_FILE)

    local json_data
    json_data=$(jq -r '.profiles | to_entries[] |
        [.key, (.value.display_name // .key), (.value.supported // false)] |
        @tsv' "$profiles_file" 2>/dev/null) || json_data=""

    if [ -z "$json_data" ]; then
        ui_msg "Error" "Could not read profiles from $profiles_file.\nIs jq installed and is the JSON valid?"
        return
    fi

    if ! ui_yesno "Device Profile" \
        "Device profile is currently: ${current:-OFF}\n\nEnable a device profile?"; then
        set_key DEVICE_PROFILE ""
        return
    fi

    # Sort: supported first, unsupported at bottom with a marker
    local pair=() key name supported
    while IFS=$'\t' read -r key name supported; do
        [ "$supported" = "true" ] && pair+=("$key" "$name") \
                                  || pair+=("$key" "[UNSUPPORTED] $name")
    done <<< "$json_data"

    # Build radiolist args with current selection marked ON
    local args=() i=0
    while [ $i -lt ${#pair[@]} ]; do
        [ "${pair[$i]}" = "$current" ] && args+=("${pair[$i]}" "${pair[$((i+1))]}" "ON") \
                                       || args+=("${pair[$i]}" "${pair[$((i+1))]}" "OFF")
        ((i+=2))
    done

    local selected=""
    if [ "$UI" = "whiptail" ]; then
        selected=$(whiptail --title "Device Profile" --radiolist \
            "Select device (space to select, empty = disable):" \
            24 70 16 "${args[@]}" 3>&1 1>&2 2>&3) || return
    elif [ "$UI" = "dialog" ]; then
        selected=$(dialog --title "Device Profile" --radiolist \
            "Select device (space to select, empty = disable):" \
            24 70 16 "${args[@]}" 3>&1 1>&2 2>&3) || return
    else
        local keys=() n idx=1
        i=0
        while [ $i -lt ${#pair[@]} ]; do
            echo "  $idx) ${pair[$i]} - ${pair[$((i+1))]}"
            keys+=("${pair[$i]}")
            ((i+=2))
            ((idx+=1))
        done
        read -rp "Choice (empty = keep ${current:-OFF}): " n
        [ -n "$n" ] && selected="${keys[$((n-1))]}"
    fi

    # Empty selection = deselected = disable profile
    # This brings up an error ??
    if [ -z "$selected" ]; then
        set_key DEVICE_PROFILE ""
        return
    fi

    # Block unsupported profiles, showing the reason from the JSON
    local reason
    reason=$(jq -r --arg p "$selected" \
        '.profiles[$p].unsupported_reason // empty' "$profiles_file")
    if [ -n "$reason" ]; then
        ui_msg "Unsupported Device" "$reason"
        return
    fi

    set_key DEVICE_PROFILE "$selected"
}

# --- Performance mode editor ---
edit_perf_mode() {
    local current choice
    current=$(get_key PERFORMANCE_MODE)
    choice=$(ui_menu "Performance Mode" \
        "silent"      "$([ "$current" = silent ] && echo SELECTED || echo "")" \
        "battery"     "$([ "$current" = battery ] && echo SELECTED || echo "")" \
        "balanced"    "$([ "$current" = balanced ] && echo SELECTED || echo "")" \
        "performance" "$([ "$current" = performance ] && echo SELECTED || echo "")" \
        "turbo"       "$([ "$current" = turbo ] && echo SELECTED || echo "")") || return
    [ -n "$choice" ] && set_key PERFORMANCE_MODE "$choice"
}

# --- Advanced settings (warning first) ---
advanced_settings() {
    ui_msg "WARNING - Advanced Settings" \
        "The following settings control internal timing, sampling, and executable paths.\n\nIf you don't know what a setting means, DO NOT CHANGE IT. Incorrect values can cause TDP oscillation, delayed responses, or ryzenadj failures." \
    || return

    while true; do
        local choice
        choice=$(ui_menu "Advanced Settings" \
            "RYZENADJ_EXEC"     "$(get_key RYZENADJ_EXEC)" \
            "RYZENADJ_DELAY"    "$(get_key RYZENADJ_DELAY)" \
            "MONITOR_INTERVAL"  "$(get_key MONITOR_INTERVAL)" \
            "STABLE_SAMPLE_COUNT" "$(get_key STABLE_SAMPLE_COUNT)" \
            "DEVICE_PROFILE_FILE" "$(get_key DEVICE_PROFILE_FILE)" \
            "GAME_PROFILE_FILE"   "$(get_key GAME_PROFILE_FILE)" \
            "back"              "Return to main menu") || break

        case "$choice" in
            back|"") break ;;
            RYZENADJ_EXEC|DEVICE_PROFILE_FILE|GAME_PROFILE_FILE)
                local new
                new=$(ui_input "$choice" "$(get_key "$choice")") || continue
                [ -n "$new" ] && set_key "$choice" "$new" ;;
            RYZENADJ_DELAY|MONITOR_INTERVAL|STABLE_SAMPLE_COUNT)
                edit_tdp "$choice" "$choice" 0 3600 ;;
        esac
    done
}

# --- Main menu ---
configui() {
    while true; do
        local choice locked
        if profile_active; then
            locked="[LOCKED - profile active]"
        else
            locked=""
        fi

        choice=$(ui_menu "AutoTDP Configuration" \
            "min_tdp"      "MIN_TDP       = $(get_key MIN_TDP) $locked" \
            "default_tdp"  "DEFAULT_TDP   = $(get_key DEFAULT_TDP) $locked" \
            "max_cpu_tdp"  "MAX_CPU_TDP   = $(get_key MAX_CPU_TDP) $locked" \
            "step_tdp"     "STEP_TDP      = $(get_key STEP_TDP) $locked" \
            "battery_tdp"  "BATTERY_MAX_TDP = $(get_key BATTERY_MAX_TDP) $locked" \
            "device_prof"  "DEVICE_PROFILE  = $(get_key DEVICE_PROFILE)" \
            "perf_mode"    "PERFORMANCE_MODE = $(get_key PERFORMANCE_MODE)" \
            "advanced"     "Advanced settings (danger)" \
            "quit"         "Exit") || break

        # Guard: block edits to profile-managed keys
        case "$choice" in
            min_tdp|default_tdp|max_cpu_tdp|step_tdp|battery_tdp)
                if profile_active; then
                    ui_msg "Locked" \
                        "This value is managed by DEVICE_PROFILE ($(get_key DEVICE_PROFILE)).\n\nThe daemon overwrites manual changes while a profile is active.\n\nTo edit manually, set DEVICE_PROFILE to OFF first."
                    continue
                fi
                ;;
        esac

        case "$choice" in
            min_tdp)     edit_tdp MIN_TDP       "Minimum TDP (mW)"       1000  50000 ;;
            default_tdp) edit_tdp DEFAULT_TDP   "Default TDP (mW)"       1000  50000 ;;
            max_cpu_tdp) edit_tdp MAX_CPU_TDP   "Max CPU TDP (mW)"       1000 100000 ;;
            step_tdp)    edit_tdp STEP_TDP      "TDP Step (mW)"           100  10000 ;;
            battery_tdp) edit_tdp BATTERY_MAX_TDP "Battery Max TDP (mW)"  1000 100000 ;;
            device_prof) edit_device_profile ;;
            perf_mode)   edit_perf_mode ;;
            advanced)    advanced_settings ;;
            quit|"") break ;;
        esac
    done
    clear
}

create_default_config() {
    run_privileged tee "$CONFIG_FILE" > /dev/null <<EOF
MIN_TDP=$MIN_TDP
DEFAULT_TDP=$DEFAULT_TDP
MAX_CPU_TDP=$MAX_CPU_TDP
STEP_TDP=$STEP_TDP
RYZENADJ_EXEC=$RYZENADJ_EXEC
RYZENADJ_DELAY=$RYZENADJ_DELAY
MONITOR_INTERVAL=$MONITOR_INTERVAL
STABLE_SAMPLE_COUNT=$STABLE_SAMPLE_COUNT
BATTERY_MAX_TDP=$BATTERY_MAX_TDP
DEVICE_PROFILE=$DEVICE_PROFILE
DEVICE_PROFILE_FILE=$DEVICE_PROFILE_FILE
PERFORMANCE_MODE=$PERFORMANCE_MODE
GAME_PROFILE_FILE=$GAME_PROFILE_FILE
EOF

    run_privileged chmod 644 "$CONFIG_FILE"
}

# Main script

parse_arguments "$@"

if (( TEST_MODE == 1 )); then
    # Sandbox: everything lives in ./testenv next to the script
    CONFIG_DIR="$SCRIPT_DIR/testenv"
    CONFIG_FILE="$CONFIG_DIR/AutoTDP.config"
    LOG_DIR="$CONFIG_DIR/logs"
    LOG_FILE="$LOG_DIR/test_$(date +'%Y-%m-%d_%H-%M-%S').log"
    KNOWN_DEVICES_FILE="$SCRIPT_DIR/known_devices.json"
    GAME_PROFILES_FILE="$SCRIPT_DIR/game_profiles.json"
    mkdir -p "$CONFIG_DIR" "$LOG_DIR"

    # No privilege escalation in test mode
    run_privileged() { "$@"; }

    # The UI only actually needs jq (device profile listing)
    if ! command -v jq > /dev/null 2>&1; then
        echo "Test mode requires jq (for the device profile browser)"
        exit 1
    fi

    # Seed a config to edit if there isn't one yet
    if [[ ! -f "$CONFIG_FILE" ]]; then
        echo "Creating test config at $CONFIG_FILE"
        create_default_config
    fi

    # Load it exactly like the real path does
    source "$CONFIG_FILE"

    : "${MIN_TDP:=5000}"
    : "${DEFAULT_TDP:=10000}"
    : "${MAX_CPU_TDP:=18000}"
    : "${STEP_TDP:=1000}"
    : "${RYZENADJ_EXEC:=ryzenadj}"
    : "${RYZENADJ_DELAY:=4}"
    : "${MONITOR_INTERVAL:=5}"
    : "${STABLE_SAMPLE_COUNT:=2}"
    : "${BATTERY_MAX_TDP:=$MAX_CPU_TDP}"
    : "${DEVICE_PROFILE:=generic}"
    : "${DEVICE_PROFILE_FILE:=$KNOWN_DEVICES_FILE}"
    : "${PERFORMANCE_MODE:=balanced}"
    : "${GAME_PROFILE_FILE:=$GAME_PROFILES_FILE}"

    configui
    exit 0
fi

if [[ $ACTION == "help" ]]; then
    print_usage
    exit 0
fi

if [[ $ACTION == "list-modes" ]]; then
    print_modes
    exit 0
fi

if [[ $ACTION == "list-profiles" && -f "$KNOWN_DEVICES_SOURCE_FILE" ]]; then
    print_device_profiles "$KNOWN_DEVICES_SOURCE_FILE"
    exit 0
fi

elevate_privileges "$@"

# Create configuration and log directories if they don't exist
run_privileged install -d -m 755 "$CONFIG_DIR"
run_privileged install -d -m 755 "$LOG_DIR"
install_known_device_profiles
install_game_profiles

run_privileged touch "$LOG_FILE"
run_privileged chmod 644 "$LOG_FILE"

# Create config file if it doesn't exist
if [ ! -f "$CONFIG_FILE" ]; then
    echo "Creating configuration file at $CONFIG_FILE"
    create_default_config
fi

# Load configuration
source "$CONFIG_FILE"

: "${MIN_TDP:=5000}"
: "${DEFAULT_TDP:=10000}"
: "${MAX_CPU_TDP:=18000}"
: "${STEP_TDP:=1000}"
: "${RYZENADJ_EXEC:=ryzenadj}"
: "${RYZENADJ_DELAY:=4}"
: "${MONITOR_INTERVAL:=5}"
: "${STABLE_SAMPLE_COUNT:=2}"
: "${BATTERY_MAX_TDP:=$MAX_CPU_TDP}"
: "${DEVICE_PROFILE-=generic}" #only set if UNSET. do not set if "empty"
: "${DEVICE_PROFILE_FILE:=$KNOWN_DEVICES_FILE}"
: "${PERFORMANCE_MODE:=balanced}"
: "${GAME_PROFILE_FILE:=$GAME_PROFILES_FILE}"

# Check for required packages before attempting to parse profile JSON
check_packages

set_mcu_powersave

if [[ -n "$CLI_PROFILE_OVERRIDE" ]]; then
    DEVICE_PROFILE=$CLI_PROFILE_OVERRIDE
fi

apply_cli_overrides "pre-profile"

apply_device_profile "$DEVICE_PROFILE_FILE" "$DEVICE_PROFILE"

apply_cli_overrides "post-profile"

if [[ -n "$CLI_MODE_OVERRIDE" ]]; then
    PERFORMANCE_MODE=$CLI_MODE_OVERRIDE
fi

if ! [[ "$STEP_TDP" =~ ^[0-9]+$ ]] || ! [[ "$RYZENADJ_DELAY" =~ ^[0-9]+$ ]] || ! [[ "$MONITOR_INTERVAL" =~ ^[0-9]+$ ]] || ! [[ "$STABLE_SAMPLE_COUNT" =~ ^[0-9]+$ ]]; then
    log "Invalid numeric configuration detected"
    exit 1
fi

if ! [[ "$MIN_TDP" =~ ^[0-9]+$ ]] || ! [[ "$DEFAULT_TDP" =~ ^[0-9]+$ ]] || ! [[ "$MAX_CPU_TDP" =~ ^[0-9]+$ ]] || ! [[ "$BATTERY_MAX_TDP" =~ ^[0-9]+$ ]]; then
    log "TDP configuration values must be positive integers"
    exit 1
fi

if (( MIN_TDP > DEFAULT_TDP || DEFAULT_TDP > MAX_CPU_TDP || BATTERY_MAX_TDP < MIN_TDP || BATTERY_MAX_TDP > MAX_CPU_TDP || STEP_TDP <= 0 || RYZENADJ_DELAY <= 0 || MONITOR_INTERVAL <= 0 || STABLE_SAMPLE_COUNT <= 0 )); then
    log "Configuration values are inconsistent"
    exit 1
fi

if ! validate_performance_mode "$PERFORMANCE_MODE"; then
    log "Invalid performance mode: $PERFORMANCE_MODE"
    exit 1
fi

BASE_MIN_TDP=$MIN_TDP
BASE_DEFAULT_TDP=$DEFAULT_TDP
BASE_MAX_CPU_TDP=$MAX_CPU_TDP
BASE_STEP_TDP=$STEP_TDP
BASE_RYZENADJ_EXEC=$RYZENADJ_EXEC
BASE_RYZENADJ_DELAY=$RYZENADJ_DELAY
BASE_MONITOR_INTERVAL=$MONITOR_INTERVAL
BASE_STABLE_SAMPLE_COUNT=$STABLE_SAMPLE_COUNT
BASE_BATTERY_MAX_TDP=$BATTERY_MAX_TDP
BASE_PERFORMANCE_MODE=$PERFORMANCE_MODE

resolve_active_game_profile

# Trap exit signals
trap cleanup EXIT

if [[ $ACTION == "help" ]]; then
    SKIP_CLEANUP=1
    print_usage
    exit 0
fi

if [[ $ACTION == "list-modes" ]]; then
    SKIP_CLEANUP=1
    print_modes
    exit 0
fi

if [[ $ACTION == "list-profiles" ]]; then
    SKIP_CLEANUP=1
    print_device_profiles "$DEVICE_PROFILE_FILE"
    exit 0
fi

if [[ $ACTION == "configure" ]]; then
    SKIP_CLEANUP=1

    if (( PERSIST_PROFILE == 1 )); then
        set_config_value "DEVICE_PROFILE" "$DEVICE_PROFILE"
    fi

    if (( PERSIST_MODE == 1 )); then
        set_config_value "PERFORMANCE_MODE" "$PERFORMANCE_MODE"
    fi

    restart_service_if_running
    log "Configuration updated: profile=$DEVICE_PROFILE mode=$PERFORMANCE_MODE"
    exit 0
fi

# Install service if requested
if [[ $ACTION == "install" ]]; then
    SKIP_CLEANUP=1
    install_service
    exit 0
fi

if [[ $ACTION == "update" ]]; then
    SKIP_CLEANUP=1
    perform_self_update
    exit $?
fi

if [[ $ACTION == "configui" ]]; then
    SKIP_CLEANUP=1
    configui
    exit 0
fi

# Start monitoring and adjusting TDP
log "Running with profile=$DEVICE_PROFILE mode=$PERFORMANCE_MODE max_tdp=$ACTIVE_MAX_TDP battery_max_tdp=$ACTIVE_BATTERY_MAX_TDP"

if (( ${#GAME_COMMAND[@]} > 0 )); then
    run_wrapped_command
    exit "$EXIT_STATUS"
fi

monitor_and_adjust
