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

# Validate version format (semver)
if ! [[ "$NEW_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo -e "${RED}Error: Invalid version format. Please use semver (e.g., 1.2.3)${NC}"
    exit 1
fi

if [ "$DRY_RUN" = true ]; then
    echo -e "${YELLOW}[DRY-RUN] Simulating release of version ${NEW_VERSION}...${NC}"
else
    echo -e "${YELLOW}Releasing version ${NEW_VERSION}...${NC}"
fi

# Check for uncommitted changes
if [ -n "$(git status --porcelain)" ]; then
    echo -e "${RED}Error: You have uncommitted changes. Please commit or stash them first.${NC}"
    exit 1
fi

# Update version in build.zig.zon
echo -e "${GREEN}Updating build.zig.zon...${NC}"
if [ "$DRY_RUN" = true ]; then
    echo -e "${BLUE}[DRY-RUN] Would update .version to \"${NEW_VERSION}\" in build.zig.zon${NC}"
else
    sed -i '' "s/\.version = \"[0-9]*\.[0-9]*\.[0-9]*\"/.version = \"${NEW_VERSION}\"/" build.zig.zon
fi

# Update version in Cargo.toml
echo -e "${GREEN}Updating rust/Cargo.toml...${NC}"
if [ "$DRY_RUN" = true ]; then
    echo -e "${BLUE}[DRY-RUN] Would update version to \"${NEW_VERSION}\" in rust/Cargo.toml${NC}"
else
    sed -i '' "s/^version = \"[0-9]*\.[0-9]*\.[0-9]*\"/version = \"${NEW_VERSION}\"/" rust/Cargo.toml
fi

# Verify the changes (skip in dry-run)
if [ "$DRY_RUN" = false ]; then
    echo -e "${GREEN}Verifying changes...${NC}"
    grep -q "\.version = \"${NEW_VERSION}\"" build.zig.zon || { echo -e "${RED}Failed to update build.zig.zon${NC}"; exit 1; }
    grep -q "^version = \"${NEW_VERSION}\"" rust/Cargo.toml || { echo -e "${RED}Failed to update rust/Cargo.toml${NC}"; exit 1; }
fi

# Create commit
echo -e "${GREEN}Creating commit...${NC}"
if [ "$DRY_RUN" = true ]; then
    echo -e "${BLUE}[DRY-RUN] Would run: git add build.zig.zon rust/Cargo.toml${NC}"
    echo -e "${BLUE}[DRY-RUN] Would run: git commit -m \"chore: bump version to ${NEW_VERSION}\"${NC}"
else
    git add --all
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
else
    git push origin "v${NEW_VERSION}"
fi

# Publish to crates.io
echo -e "${GREEN}Publishing to crates.io...${NC}"
if [ "$DRY_RUN" = true ]; then
    echo -e "${BLUE}[DRY-RUN] Would run: cd rust && cargo publish${NC}"
else
    cd rust
    cargo publish
fi

if [ "$DRY_RUN" = true ]; then
    echo -e "${YELLOW}[DRY-RUN] Completed. No changes were made.${NC}"
else
    echo -e "${GREEN}Successfully released version ${NEW_VERSION}!${NC}"
fi
