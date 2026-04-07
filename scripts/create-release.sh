#!/bin/bash

# create-release.sh — Release helper for QA Dist Manager (qaDist)
#
# What it does:
#   1. Reads the current version from qaDist.lua
#   2. Lets you pick a version bump (patch / minor / major / custom)
#   3. Updates the version in qaDist.lua
#   4. Generates qaDist.fqa via plua -t pack
#   5. Updates CHANGELOG.md
#   6. Commits all changed files and pushes
#   7. Creates and pushes a vX.Y.Z git tag
#   8. Creates a GitHub release and uploads qaDist.fqa
#
# Usage:
#   ./scripts/create-release.sh              # interactive
#   ./scripts/create-release.sh --preview    # preview release notes, no release
#   ./scripts/create-release.sh --dry-run    # same as --preview

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
QA_FILE="$REPO_DIR/qaDist.lua"
STABLE_FQA="$REPO_DIR/qaDist.fqa"

# ── Colours ────────────────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

info()    { echo -e "${BLUE}[INFO]${NC} $1"; }
success() { echo -e "${GREEN}[OK]${NC} $1"; }
warning() { echo -e "${YELLOW}[WARN]${NC} $1"; }
error()   { echo -e "${RED}[ERROR]${NC} $1"; }

# ── Helpers ────────────────────────────────────────────────────────────────────
command_exists() { command -v "$1" >/dev/null 2>&1; }

get_current_version() {
    grep -E '^local VERSION = ' "$QA_FILE" | head -1 | sed 's/local VERSION = "\(.*\)"/\1/'
}


increment_version() {
    local version=$1 type=$2
    IFS='.' read -ra P <<< "$version"
    local major=${P[0]} minor=${P[1]} patch=${P[2]}
    case $type in
        patch) patch=$((patch + 1)) ;;
        minor) minor=$((minor + 1)); patch=0 ;;
        major) major=$((major + 1)); minor=0; patch=0 ;;
    esac
    echo "$major.$minor.$patch"
}

get_last_tag() { git -C "$REPO_DIR" describe --tags --abbrev=0 2>/dev/null || echo ""; }

# ── Dependency check ───────────────────────────────────────────────────────────
check_dependencies() {
    info "Checking dependencies..."
    local missing=()
    for cmd in git plua gh; do
        command_exists "$cmd" || missing+=("$cmd")
    done
    if [ ${#missing[@]} -ne 0 ]; then
        error "Missing: ${missing[*]}"
        echo "  git:  https://git-scm.com"
        echo "  plua: pip install plua"
        echo "  gh:   https://cli.github.com"
        exit 1
    fi
    if ! gh auth status >/dev/null 2>&1; then
        error "GitHub CLI not authenticated. Run: gh auth login"
        exit 1
    fi
    success "All dependencies available"
}

# ── Git status check ───────────────────────────────────────────────────────────
check_git_status() {
    info "Checking git status..."
    cd "$REPO_DIR"
    if ! git rev-parse --git-dir >/dev/null 2>&1; then
        error "Not a git repository"
        exit 1
    fi
    if ! git diff-index --quiet HEAD --; then
        error "Uncommitted changes. Commit or stash first."
        git status --porcelain
        exit 1
    fi
    local local_commit remote_commit
    local_commit=$(git rev-parse HEAD)
    remote_commit=$(git rev-parse "@{u}" 2>/dev/null || echo "")
    if [ -n "$remote_commit" ] && [ "$local_commit" != "$remote_commit" ]; then
        if git merge-base --is-ancestor "$remote_commit" "$local_commit"; then
            error "Unpushed commits exist. Push first."
            git log --oneline "${remote_commit}..HEAD"
            exit 1
        fi
        error "Branch is behind remote. Pull first."
        exit 1
    fi
    success "Git is clean and up-to-date"
}

# ── Release notes ──────────────────────────────────────────────────────────────
generate_release_notes() {
    local last_tag=$1 new_version=$2
    local range notes
    [ -n "$last_tag" ] && range="${last_tag}..HEAD" || range="HEAD"
    notes="## Changes in v${new_version}\n\n"

    local commits
    commits=$(git -C "$REPO_DIR" log "$range" --pretty=format:"%s" --no-merges 2>/dev/null)

    if [ -n "$commits" ]; then
        while IFS= read -r line; do
            [ -z "$line" ] && continue
            case "$line" in
                feat:*)    notes+="- ✨ **Feature**: ${line#feat: }\n" ;;
                fix:*)     notes+="- 🐛 **Fix**: ${line#fix: }\n" ;;
                docs:*)    notes+="- 📚 **Docs**: ${line#docs: }\n" ;;
                refactor:*)notes+="- ♻️ **Refactor**: ${line#refactor: }\n" ;;
                test:*)    notes+="- 🧪 **Test**: ${line#test: }\n" ;;
                *)         notes+="- ${line}\n" ;;
            esac
        done <<< "$commits"
    else
        notes+="- No new commits since last release\n"
    fi

    notes+="\n\n*Generated automatically from git commits*"
    echo -e "$notes"
}

# ── Update version in qaDist.lua ───────────────────────────────────────────────
update_version_in_source() {
    local new_ver=$1

    # local VERSION = "x.y.z"
    sed -i.bak "s/^local VERSION = \".*\"/local VERSION = \"${new_ver}\"/" "$QA_FILE"
    rm -f "${QA_FILE}.bak"
    success "Updated version in qaDist.lua → $new_ver"
}

# ── Build FQA ─────────────────────────────────────────────────────────────────
build_fqa() {
    info "Building FQA via plua..."
    cd "$REPO_DIR"
    plua -t pack qaDist.lua

    if [ ! -f "$STABLE_FQA" ]; then
        error "FQA not created: $STABLE_FQA"
        exit 1
    fi

    success "Created qaDist.fqa"
}

# ── Changelog ─────────────────────────────────────────────────────────────────
update_changelog() {
    local version=$1 notes=$2
    local date
    date=$(date '+%Y-%m-%d')
    local tmp
    tmp=$(mktemp)
    {
        echo "# Changelog"
        echo ""
        echo "## [v${version}] - ${date}"
        echo ""
        echo -e "$notes"
        echo ""
    } > "$tmp"

    if [ -s "$REPO_DIR/CHANGELOG.md" ]; then
        tail -n +3 "$REPO_DIR/CHANGELOG.md" >> "$tmp"
    fi
    mv "$tmp" "$REPO_DIR/CHANGELOG.md"
    success "Updated CHANGELOG.md"
}

# ── Commit & push ──────────────────────────────────────────────────────────────
commit_and_push() {
    local version=$1
    cd "$REPO_DIR"
    git add qaDist.lua qaDist.fqa dist.json CHANGELOG.md

    git commit -m "release: v${version}"
    git push origin "$(git branch --show-current)"
    success "Pushed release commit"
}

create_and_push_tag() {
    local version=$1
    cd "$REPO_DIR"
    git tag -a "v${version}" -m "Release v${version}"
    git push origin "v${version}"
    success "Pushed tag v${version}"
}

# ── GitHub release ─────────────────────────────────────────────────────────────
create_github_release() {
    local version=$1 notes=$2
    info "Creating GitHub release v${version}..."

    cd "$REPO_DIR"
    local release_url
    release_url=$(gh release create "v${version}" \
        --title "Release v${version}" \
        --notes "$notes" \
        --verify-tag)
    success "Release created: $release_url"

    # Upload qaDist.fqa
    if gh release upload "v${version}" "$STABLE_FQA"; then
        success "Uploaded qaDist.fqa"
    else
        warning "Failed to upload qaDist.fqa"
    fi
}

# ── Preview mode ───────────────────────────────────────────────────────────────
preview_release() {
    echo -e "${CYAN}[PREVIEW MODE]${NC}"
    check_dependencies

    local cur_ver last_tag
    cur_ver=$(get_current_version)
    last_tag=$(get_last_tag)
    info "Current version: $cur_ver"
    [ -n "$last_tag" ] && info "Last release: $last_tag" || warning "No previous releases found."
    echo ""

    for type in patch minor major; do
        local next_ver
        next_ver=$(increment_version "$cur_ver" "$type")
        echo -e "${YELLOW}=== v${next_ver} (${type}) ===${NC}"
        generate_release_notes "$last_tag" "$next_ver"
        echo ""
    done

    success "Preview complete. Run without --preview to create a release."
}

# ── Main ───────────────────────────────────────────────────────────────────────
main() {
    echo -e "${CYAN}🚀 QA Dist Manager — Release Helper${NC}"
    echo ""

    check_dependencies
    check_git_status

    local cur_ver last_tag
    cur_ver=$(get_current_version)
    last_tag=$(get_last_tag)
    info "Current version: $cur_ver"
    [ -n "$last_tag" ] && info "Last release: $last_tag" || info "No previous releases."
    echo ""

    echo "Select version bump:"
    echo "  1) Patch  ($cur_ver → $(increment_version "$cur_ver" patch))"
    echo "  2) Minor  ($cur_ver → $(increment_version "$cur_ver" minor))"
    echo "  3) Major  ($cur_ver → $(increment_version "$cur_ver" major))"
    echo "  4) Custom"
    echo ""

    local new_ver
    while true; do
        read -r -p "Choice (1-4): " choice
        case $choice in
            1) new_ver=$(increment_version "$cur_ver" patch); break ;;
            2) new_ver=$(increment_version "$cur_ver" minor); break ;;
            3) new_ver=$(increment_version "$cur_ver" major); break ;;
            4)
                read -r -p "Enter version (X.Y.Z): " new_ver
                [[ $new_ver =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] && break
                error "Invalid format. Use X.Y.Z."
                ;;
            *) error "Choose 1-4." ;;
        esac
    done

    echo ""
    echo "Release notes:"
    echo "  1) Auto-generate from git commits"
    echo "  2) Enter manually"
    echo "  3) Simple default message"
    echo ""

    local notes
    while true; do
        read -r -p "Choice (1-3): " choice
        case $choice in
            1) notes=$(generate_release_notes "$last_tag" "$new_ver"); break ;;
            2) echo "Enter notes (Ctrl+D to finish):"; notes=$(cat); break ;;
            3) notes="Release v${new_ver}."; break ;;
            *) error "Choose 1-3." ;;
        esac
    done

    echo ""
    info "Release notes:"
    echo -e "$notes"
    echo ""

    read -r -p "Use these notes? (Y/n): " yn
    if [[ $yn =~ ^[nN]$ ]]; then
        echo "Enter notes (Ctrl+D to finish):"
        notes=$(cat)
    fi

    echo ""
    info "Summary:"
    echo "  Version:  v${new_ver}"
    echo "  Tag:      v${new_ver}"
    echo "  Artifact: qaDist.fqa"
    echo ""
    read -r -p "Create release? (y/N): " confirm
    [[ ! $confirm =~ ^[yY]$ ]] && { info "Cancelled."; exit 0; }

    echo ""
    info "Step 1/6 — Updating version in source..."
    update_version_in_source "$new_ver"

    info "Step 2/6 — Building FQA..."
    build_fqa

    info "Step 3/6 — Updating CHANGELOG.md..."
    update_changelog "$new_ver" "$notes"

    info "Step 4/6 — Committing and pushing..."
    commit_and_push "$new_ver"

    info "Step 5/6 — Tagging..."
    create_and_push_tag "$new_ver"

    info "Step 6/6 — Creating GitHub release..."
    create_github_release "$new_ver" "$notes"

    echo ""
    success "🎉 Release v${new_ver} complete!"
    local repo_info
    repo_info=$(gh repo view --json owner,name -q '.owner.login + "/" + .name')
    info "https://github.com/${repo_info}/releases/tag/v${new_ver}"
}

# ── Entry point ────────────────────────────────────────────────────────────────
case "${1:-}" in
    --preview|--dry-run|-p) preview_release ;;
    --help|-h)
        echo "Usage: $0 [--preview | --dry-run | --help]"
        echo ""
        echo "  (no args)           Interactive release creation"
        echo "  --preview, -p       Preview release notes without creating a release"
        echo "  --dry-run           Same as --preview"
        ;;
    "") main ;;
    *) error "Unknown option: $1. Use --help for usage."; exit 1 ;;
esac
