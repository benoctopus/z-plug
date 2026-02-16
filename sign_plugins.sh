#!/bin/bash
set -e

# Plugin code-signing script for zig-plug
# Signs plugins with ad-hoc signature to satisfy DAW validation

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

PLUGIN_DIR="zig-out/plugins"

echo -e "${YELLOW}Signing plugins with ad-hoc signature...${NC}"
echo ""

# Sign CLAP plugins
echo "Signing CLAP plugins..."
CLAP_COUNT=0
for clap in "$PLUGIN_DIR"/*.clap; do
    if [ -f "$clap" ]; then
        PLUGIN_NAME=$(basename "$clap")
        echo -e "  ${GREEN}→${NC} Signing $PLUGIN_NAME"
        codesign --force --deep --sign - "$clap"
        CLAP_COUNT=$((CLAP_COUNT + 1))
    fi
done

if [ $CLAP_COUNT -eq 0 ]; then
    echo -e "  ${YELLOW}No CLAP plugins found${NC}"
fi

# Sign VST3 plugins
echo ""
echo "Signing VST3 plugins..."
VST3_COUNT=0
for vst3 in "$PLUGIN_DIR"/*.vst3; do
    if [ -d "$vst3" ]; then
        PLUGIN_NAME=$(basename "$vst3")
        echo -e "  ${GREEN}→${NC} Signing $PLUGIN_NAME"
        
        # Sign the binary first
        if [ -f "$vst3/Contents/MacOS/"* ]; then
            codesign --force --sign - "$vst3/Contents/MacOS/"*
        fi
        
        # Then sign the bundle
        codesign --force --deep --sign - "$vst3"
        
        # Verify signature
        echo -e "  ${GREEN}→${NC} Verifying signature..."
        if codesign --verify --deep --strict "$vst3" 2>&1; then
            echo -e "  ${GREEN}✓${NC} Signature valid"
        else
            echo -e "  ${RED}✗${NC} Signature verification failed"
        fi
        
        VST3_COUNT=$((VST3_COUNT + 1))
    fi
done

if [ $VST3_COUNT -eq 0 ]; then
    echo -e "  ${YELLOW}No VST3 plugins found${NC}"
fi

# Summary
echo ""
echo -e "${GREEN}═══════════════════════════════════════${NC}"
if [ $((CLAP_COUNT + VST3_COUNT)) -eq 0 ]; then
    echo -e "${YELLOW}No plugins were signed${NC}"
    echo "Make sure to build the plugins first with 'zig build'"
    exit 1
else
    echo -e "${GREEN}Signing complete!${NC}"
    echo "Signed $CLAP_COUNT CLAP + $VST3_COUNT VST3 plugin(s)"
    echo ""
    echo -e "${YELLOW}Note: Plugins are signed with ad-hoc signature${NC}"
    echo "This works for local testing but not for distribution"
    echo ""
    echo "Run ./install_plugins.sh to install the signed plugins"
fi
echo -e "${GREEN}═══════════════════════════════════════${NC}"
