#!/bin/bash
set -e

# Plugin uninstallation script for zig-plug
# Removes installed plugins from system directories

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Determine plugin directories based on OS
case "$(uname -s)" in
    Darwin)
        # macOS
        CLAP_USER_DIR="$HOME/Library/Audio/Plug-Ins/CLAP"
        CLAP_SYSTEM_DIR="/Library/Audio/Plug-Ins/CLAP"
        VST3_USER_DIR="$HOME/Library/Audio/Plug-Ins/VST3"
        VST3_SYSTEM_DIR="/Library/Audio/Plug-Ins/VST3"
        ;;
    Linux)
        # Linux
        CLAP_USER_DIR="$HOME/.clap"
        CLAP_SYSTEM_DIR="/usr/lib/clap"
        VST3_USER_DIR="$HOME/.vst3"
        VST3_SYSTEM_DIR="/usr/lib/vst3"
        ;;
    CYGWIN*|MINGW*|MSYS*)
        # Windows
        CLAP_USER_DIR="$APPDATA/CLAP"
        CLAP_SYSTEM_DIR="/Program Files/Common Files/CLAP"
        VST3_USER_DIR="$APPDATA/VST3"
        VST3_SYSTEM_DIR="/Program Files/Common Files/VST3"
        ;;
    *)
        echo -e "${RED}Unsupported OS: $(uname -s)${NC}"
        exit 1
        ;;
esac

# Default to user directories
REMOVE_FROM_SYSTEM=false
PLUGIN_DIR="zig-out/plugins"
DRY_RUN=false

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --system)
            REMOVE_FROM_SYSTEM=true
            shift
            ;;
        --user)
            REMOVE_FROM_SYSTEM=false
            shift
            ;;
        --all)
            echo -e "${YELLOW}Removing from BOTH user and system directories${NC}"
            REMOVE_FROM_SYSTEM="both"
            shift
            ;;
        --dry-run)
            DRY_RUN=true
            shift
            ;;
        -h|--help)
            echo "Usage: $0 [OPTIONS]"
            echo ""
            echo "Remove installed zig-plug plugins from system directories"
            echo ""
            echo "Options:"
            echo "  --user      Remove from user directories only (default)"
            echo "  --system    Remove from system directories only (requires sudo on macOS/Linux)"
            echo "  --all       Remove from both user and system directories"
            echo "  --dry-run   Show what would be removed without actually removing"
            echo "  -h, --help  Show this help message"
            echo ""
            echo "User directories:"
            echo "  CLAP: $CLAP_USER_DIR"
            echo "  VST3: $VST3_USER_DIR"
            echo ""
            echo "System directories:"
            echo "  CLAP: $CLAP_SYSTEM_DIR"
            echo "  VST3: $VST3_SYSTEM_DIR"
            exit 0
            ;;
        *)
            echo -e "${RED}Unknown option: $1${NC}"
            echo "Use --help for usage information"
            exit 1
            ;;
    esac
done

# Function to remove plugins from a directory
remove_plugins_from() {
    local clap_dir=$1
    local vst3_dir=$2
    local use_sudo=$3
    local removed_count=0
    
    # Check if plugin build directory exists to get list of plugins
    if [ ! -d "$PLUGIN_DIR" ]; then
        echo -e "${YELLOW}Warning: Build directory '$PLUGIN_DIR' not found${NC}"
        echo "Will try to remove any zig-plug plugins found in target directories"
    fi
    
    # Remove CLAP plugins
    if [ -d "$clap_dir" ]; then
        echo "Checking CLAP directory: $clap_dir"
        
        if [ -d "$PLUGIN_DIR" ]; then
            # Remove specific plugins from build
            for clap in "$PLUGIN_DIR"/*.clap; do
                if [ -f "$clap" ]; then
                    PLUGIN_NAME=$(basename "$clap")
                    TARGET_PATH="$clap_dir/$PLUGIN_NAME"
                    
                    if [ -f "$TARGET_PATH" ]; then
                        if [ "$DRY_RUN" = true ]; then
                            echo -e "  ${YELLOW}[DRY RUN]${NC} Would remove: $TARGET_PATH"
                        else
                            echo -e "  ${RED}✗${NC} Removing $PLUGIN_NAME"
                            if [ "$use_sudo" = true ]; then
                                sudo rm -f "$TARGET_PATH"
                            else
                                rm -f "$TARGET_PATH"
                            fi
                        fi
                        removed_count=$((removed_count + 1))
                    fi
                fi
            done
        else
            # Remove any .clap files that might be zig-plug plugins
            # Look for files with zig-plug vendor info
            for clap in "$clap_dir"/*.clap; do
                if [ -f "$clap" ]; then
                    # Check if it's one of our plugins by looking for zig-plug signature
                    if strings "$clap" 2>/dev/null | grep -q "zig-plug\|Zig Gain\|ZigGain"; then
                        PLUGIN_NAME=$(basename "$clap")
                        if [ "$DRY_RUN" = true ]; then
                            echo -e "  ${YELLOW}[DRY RUN]${NC} Would remove: $clap"
                        else
                            echo -e "  ${RED}✗${NC} Removing $PLUGIN_NAME (detected as zig-plug)"
                            if [ "$use_sudo" = true ]; then
                                sudo rm -f "$clap"
                            else
                                rm -f "$clap"
                            fi
                        fi
                        removed_count=$((removed_count + 1))
                    fi
                fi
            done
        fi
    fi
    
    # Remove VST3 plugins
    if [ -d "$vst3_dir" ]; then
        echo "Checking VST3 directory: $vst3_dir"
        
        if [ -d "$PLUGIN_DIR" ]; then
            # Remove specific plugins from build
            for vst3 in "$PLUGIN_DIR"/*.vst3; do
                if [ -d "$vst3" ]; then
                    PLUGIN_NAME=$(basename "$vst3")
                    TARGET_PATH="$vst3_dir/$PLUGIN_NAME"
                    
                    if [ -d "$TARGET_PATH" ]; then
                        if [ "$DRY_RUN" = true ]; then
                            echo -e "  ${YELLOW}[DRY RUN]${NC} Would remove: $TARGET_PATH"
                        else
                            echo -e "  ${RED}✗${NC} Removing $PLUGIN_NAME"
                            if [ "$use_sudo" = true ]; then
                                sudo rm -rf "$TARGET_PATH"
                            else
                                rm -rf "$TARGET_PATH"
                            fi
                        fi
                        removed_count=$((removed_count + 1))
                    fi
                fi
            done
        else
            # Remove any .vst3 bundles that might be zig-plug plugins
            for vst3 in "$vst3_dir"/*.vst3; do
                if [ -d "$vst3" ]; then
                    # Check if it's one of our plugins
                    if [ -f "$vst3/Contents/Info.plist" ]; then
                        if grep -q "com.zplugin\|zig-plug" "$vst3/Contents/Info.plist" 2>/dev/null; then
                            PLUGIN_NAME=$(basename "$vst3")
                            if [ "$DRY_RUN" = true ]; then
                                echo -e "  ${YELLOW}[DRY RUN]${NC} Would remove: $vst3"
                            else
                                echo -e "  ${RED}✗${NC} Removing $PLUGIN_NAME (detected as zig-plug)"
                                if [ "$use_sudo" = true ]; then
                                    sudo rm -rf "$vst3"
                                else
                                    rm -rf "$vst3"
                                fi
                            fi
                            removed_count=$((removed_count + 1))
                        fi
                    fi
                fi
            done
        fi
    fi
    
    return $removed_count
}

# Main execution
total_removed=0

if [ "$DRY_RUN" = true ]; then
    echo -e "${YELLOW}═══════════════════════════════════════${NC}"
    echo -e "${YELLOW}DRY RUN MODE - No files will be deleted${NC}"
    echo -e "${YELLOW}═══════════════════════════════════════${NC}"
    echo ""
fi

if [ "$REMOVE_FROM_SYSTEM" = "both" ]; then
    # Remove from user directories
    echo -e "${GREEN}Removing from USER directories${NC}"
    echo ""
    remove_plugins_from "$CLAP_USER_DIR" "$VST3_USER_DIR" false
    user_removed=$?
    total_removed=$((total_removed + user_removed))
    
    echo ""
    
    # Remove from system directories
    echo -e "${GREEN}Removing from SYSTEM directories (requires sudo)${NC}"
    echo ""
    remove_plugins_from "$CLAP_SYSTEM_DIR" "$VST3_SYSTEM_DIR" true
    system_removed=$?
    total_removed=$((total_removed + system_removed))
    
elif [ "$REMOVE_FROM_SYSTEM" = true ]; then
    echo -e "${GREEN}Removing from SYSTEM directories (requires sudo)${NC}"
    echo ""
    remove_plugins_from "$CLAP_SYSTEM_DIR" "$VST3_SYSTEM_DIR" true
    total_removed=$?
else
    echo -e "${GREEN}Removing from USER directories${NC}"
    echo ""
    remove_plugins_from "$CLAP_USER_DIR" "$VST3_USER_DIR" false
    total_removed=$?
fi

# Summary
echo ""
echo -e "${GREEN}═══════════════════════════════════════${NC}"
if [ "$DRY_RUN" = true ]; then
    echo -e "${YELLOW}DRY RUN: Would remove $total_removed plugin(s)${NC}"
    echo "Run without --dry-run to actually remove files"
elif [ $total_removed -eq 0 ]; then
    echo -e "${YELLOW}No zig-plug plugins found to remove${NC}"
else
    echo -e "${GREEN}Uninstallation complete!${NC}"
    echo "Removed $total_removed plugin(s)"
    echo ""
    echo "Restart your DAW and rescan plugins to complete removal"
fi
echo -e "${GREEN}═══════════════════════════════════════${NC}"
