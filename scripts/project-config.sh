#!/bin/bash

# project-config.sh — qaDist project configuration for setversion.sh
#
# setversion.sh sources this file and expects:
#   PROJECT_NAME, VERSION_FILE, VERSION_FILES, validate_config

PROJECT_NAME="QA Dist Manager"

# No separate .version file — version lives only in qaDist.lua
VERSION_FILE=""

# Files where the version string should be updated.
# Format: "filepath:pattern"  — setversion.sh replaces: pattern = "old" → pattern = "new"
VERSION_FILES=(
    "qaDist.lua:local VERSION"
)

# Validate that required variables are set
validate_config() {
    if [ -z "$PROJECT_NAME" ]; then
        echo "Error: PROJECT_NAME is not set"
        return 1
    fi
    return 0
}
