#!/bin/bash
set -e

# Plugin installation script for zig-plug
# Installs built plugins to standard system locations

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

# Default to user installation
INSTALL_SYSTEM=false
PLUGIN_DIR="zig-out/plugins"

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --system)
            INSTALL_SYSTEM=true
            shift
            ;;
        --user)
            INSTALL_SYSTEM=false
            shift
            ;;
        -h|--help)
            echo "Usage: $0 [OPTIONS]"
            echo ""
            echo "Install built plugins to system directories"
            echo ""
            echo "Options:"
            echo "  --user      Install to user directory (default)"
            echo "  --system    Install to system directory (requires sudo on macOS/Linux)"
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

# Set target directories
if [ "$INSTALL_SYSTEM" = true ]; then
    CLAP_TARGET="$CLAP_SYSTEM_DIR"
    VST3_TARGET="$VST3_SYSTEM_DIR"
    INSTALL_CMD="sudo"
    echo -e "${YELLOW}Installing to SYSTEM directories (requires sudo)${NC}"
else
    CLAP_TARGET="$CLAP_USER_DIR"
    VST3_TARGET="$VST3_USER_DIR"
    INSTALL_CMD=""
    echo -e "${GREEN}Installing to USER directories${NC}"
fi

# Check if plugins were built
if [ ! -d "$PLUGIN_DIR" ]; then
    echo -e "${RED}Error: Plugin directory '$PLUGIN_DIR' not found${NC}"
    echo "Run 'zig build' first to build the plugins"
    exit 1
fi

# Create target directories if they don't exist
echo "Creating target directories if needed..."
if [ "$INSTALL_SYSTEM" = true ]; then
    $INSTALL_CMD mkdir -p "$CLAP_TARGET" "$VST3_TARGET"
else
    mkdir -p "$CLAP_TARGET" "$VST3_TARGET"
fi

# Install CLAP plugins
echo ""
echo "Installing CLAP plugins..."
CLAP_COUNT=0
for clap in "$PLUGIN_DIR"/*.clap; do
    if [ -f "$clap" ]; then
        PLUGIN_NAME=$(basename "$clap")
        echo -e "  ${GREEN}→${NC} Installing $PLUGIN_NAME"
        $INSTALL_CMD cp -f "$clap" "$CLAP_TARGET/"
        CLAP_COUNT=$((CLAP_COUNT + 1))
    fi
done

if [ $CLAP_COUNT -eq 0 ]; then
    echo -e "  ${YELLOW}No CLAP plugins found${NC}"
else
    echo -e "  ${GREEN}✓ Installed $CLAP_COUNT CLAP plugin(s) to $CLAP_TARGET${NC}"
fi

# Install VST3 plugins
echo ""
echo "Installing VST3 plugins..."
VST3_COUNT=0
for vst3 in "$PLUGIN_DIR"/*.vst3; do
    if [ -d "$vst3" ]; then
        PLUGIN_NAME=$(basename "$vst3")
        echo -e "  ${GREEN}→${NC} Installing $PLUGIN_NAME"
        
        # Remove existing installation if present
        if [ -d "$VST3_TARGET/$PLUGIN_NAME" ]; then
            $INSTALL_CMD rm -rf "$VST3_TARGET/$PLUGIN_NAME"
        fi
        
        # Copy the bundle
        $INSTALL_CMD cp -R "$vst3" "$VST3_TARGET/"
        VST3_COUNT=$((VST3_COUNT + 1))
    fi
done

if [ $VST3_COUNT -eq 0 ]; then
    echo -e "  ${YELLOW}No VST3 plugins found${NC}"
else
    echo -e "  ${GREEN}✓ Installed $VST3_COUNT VST3 plugin(s) to $VST3_TARGET${NC}"
fi

# Summary
echo ""
echo -e "${GREEN}═══════════════════════════════════════${NC}"
if [ $((CLAP_COUNT + VST3_COUNT)) -eq 0 ]; then
    echo -e "${YELLOW}No plugins were installed${NC}"
    echo "Make sure to build the plugins first with 'zig build'"
    exit 1
else
    echo -e "${GREEN}Installation complete!${NC}"
    echo "Installed $CLAP_COUNT CLAP + $VST3_COUNT VST3 plugin(s)"
    echo ""
    echo "Restart your DAW to see the new plugins"
fi
echo -e "${GREEN}═══════════════════════════════════════${NC}"
