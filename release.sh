#!/bin/bash
set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Parse arguments
DRY_RUN=false
NEW_VERSION=""

while [[ $# -gt 0 ]]; do
    case $1 in
        --dry-run)
            DRY_RUN=true
            shift
            ;;
        -h|--help)
            echo "Usage: ./release.sh [--dry-run] <version>"
            echo "Example: ./release.sh 1.2.3"
            echo "         ./release.sh --dry-run 1.2.3"
            echo ""
            echo "Options:"
            echo "  --dry-run    Show what would be done without making changes"
            echo "  -h, --help   Show this help message"
            exit 0
            ;;
        *)
            NEW_VERSION=$1
            shift
            ;;
    esac
done

if [ -z "$NEW_VERSION" ]; then
    echo -e "${RED}Error: Please provide a version number${NC}"
    echo "Usage: ./release.sh [--dry-run] <version>"
    echo "Example: ./release.sh 1.2.3"
    exit 1
fi

if [ "$DRY_RUN" = true ]; then
    echo -e "${YELLOW}[DRY-RUN] Simulating release of version ${NEW_VERSION}...${NC}"
else
    echo -e "${YELLOW}Releasing version ${NEW_VERSION}...${NC}"
fi

if [ "$DRY_RUN" = false ] && [ -n "$(git status --porcelain)" ]; then
    echo -e "${RED}Error: Start the release from a clean checkout.${NC}"
    exit 1
fi

if ! [[ "$NEW_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?(\+[0-9A-Za-z.-]+)?$ ]]; then
    echo -e "${RED}Error: Invalid release version: ${NEW_VERSION}${NC}"
    exit 1
fi

sed_in_place() {
    if [[ $(uname -s) == Darwin ]]; then
        sed -i '' "$@"
    else
        sed -i "$@"
    fi
}

# Update version in build.zig.zon
echo -e "${GREEN}Updating build.zig.zon...${NC}"
if [ "$DRY_RUN" = true ]; then
    echo -e "${BLUE}[DRY-RUN] Would update .version to \"${NEW_VERSION}\" in build.zig.zon${NC}"
else
    sed_in_place "s/\.version = \"[^\"]*\"/.version = \"${NEW_VERSION}\"/" build.zig.zon
fi

# Update version in Cargo.toml
echo -e "${GREEN}Updating rust/Cargo.toml...${NC}"
if [ "$DRY_RUN" = true ]; then
    echo -e "${BLUE}[DRY-RUN] Would update version to \"${NEW_VERSION}\" in rust/Cargo.toml${NC}"
else
    sed_in_place "s/^version = \"[^\"]*\"/version = \"${NEW_VERSION}\"/" rust/Cargo.toml rust/prebuilt/*/Cargo.toml
    # zlob pins the zlob-prebuilt-* crates to its own version
    sed_in_place "/^zlob-prebuilt-/s/version = \"=[^\"]*\"/version = \"=${NEW_VERSION}\"/" rust/Cargo.toml
    (cd rust && cargo build)
fi

# Verify the changes (skip in dry-run)
if [ "$DRY_RUN" = false ]; then
    echo -e "${GREEN}Verifying changes...${NC}"
    grep -q "\.version = \"${NEW_VERSION}\"" build.zig.zon || { echo -e "${RED}Failed to update build.zig.zon${NC}"; exit 1; }
    for manifest in rust/Cargo.toml rust/prebuilt/*/Cargo.toml; do
        grep -Fxq "version = \"${NEW_VERSION}\"" "$manifest" || { echo -e "${RED}Failed to update ${manifest}${NC}"; exit 1; }
    done
fi

# Create commit
echo -e "${GREEN}Creating commit...${NC}"
if [ "$DRY_RUN" = true ]; then
    echo -e "${BLUE}[DRY-RUN] Would stage the Zig and Cargo manifests and Cargo.lock${NC}"
    echo -e "${BLUE}[DRY-RUN] Would run: git commit -m \"chore: version to ${NEW_VERSION}\"${NC}"
else
    git add -- build.zig.zon rust/Cargo.toml rust/Cargo.lock rust/prebuilt/*/Cargo.toml
    git commit -m "chore: version to ${NEW_VERSION}"
fi

echo -e "${GREEN}Pushing commit...${NC}"
if [ "$DRY_RUN" = true ]; then
    echo -e "${BLUE}[DRY-RUN] Would run: git push${NC}"
else
    git push
fi

# Create and push tag
echo -e "${GREEN}Creating tag v${NEW_VERSION}...${NC}"
if [ "$DRY_RUN" = true ]; then
    echo -e "${BLUE}[DRY-RUN] Would run: git tag -a \"v${NEW_VERSION}\" -m \"Release v${NEW_VERSION}\"${NC}"
else
    git tag -a "v${NEW_VERSION}" -m "Release v${NEW_VERSION}"
fi

echo -e "${GREEN}Pushing tag...${NC}"
if [ "$DRY_RUN" = true ]; then
    echo -e "${BLUE}[DRY-RUN] Would run: git push origin \"v${NEW_VERSION}\"${NC}"
    echo -e "${BLUE}[DRY-RUN] The tag would trigger the GitHub Actions publishing workflow${NC}"
else
    git push origin "v${NEW_VERSION}"
fi


if [ "$DRY_RUN" = true ]; then
    echo -e "${YELLOW}[DRY-RUN] Completed. No changes were made.${NC}"
else
    echo -e "${GREEN}Pushed v${NEW_VERSION}. GitHub Actions will build and publish the Rust crates.${NC}"
fi
