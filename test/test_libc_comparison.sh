#!/bin/bash

set -eou pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

DIR="${TEST_DIR:-/home/neogoose/dev/fff.nvim/big-repo}"
ZLOB_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

if [ ! -d "$DIR" ]; then
    echo -e "${YELLOW}Warning: Test directory '$DIR' not found${NC}"
    echo "Set TEST_DIR environment variable to a valid directory (e.g., Linux kernel source)"
    echo "Skipping libc comparison tests..."
    exit 0
fi

echo "Building compare-libc tool..."
cd "$ZLOB_ROOT"
zig build --release=fast

if [ ! -f "$ZLOB_ROOT/zig-out/bin/compare_libc" ]; then
    echo -e "${YELLOW}Warning: compare_libc not found, skipping libc comparison tests${NC}"
    exit 0
fi

PATTERNS=(
    # Basic wildcards
    "*.c"
    "*.h"
    "*.S"
    "*.txt"
    "*.rst"
    "Makefile"
    "Kconfig"
    
    # Directory patterns
    "kernel/*.c"
    "kernel/*.h"
    "drivers/base/*.c"
    "fs/ext4/*.c"
    "fs/xfs/*.c"
    "include/linux/*.h"
    "arch/x86/kernel/*.c"
    "net/ipv4/*.c"
    "sound/core/*.c"
    
    # Prefix patterns
    "kernel/s*.c"
    "kernel/t*.c"
    "drivers/base/d*.c"
    "fs/ext4/e*.c"
    "include/linux/a*.h"
    "include/linux/z*.h"
    
    # Suffix patterns
    "kernel/*_test.c"
    "drivers/base/*core*.c"
    
    # Question mark patterns
    "kernel/???.c"
    "kernel/????.c"
    "kernel/?????.c"
    "kernel/??????.c"
    "fs/ext4/???.c"
    
    # Character class patterns
    "kernel/[a-c]*.c"
    "kernel/[d-f]*.c"
    "kernel/[s-z]*.c"
    "kernel/[aeiou]*.c"
    "drivers/base/[a-m]*.c"
    "drivers/base/[n-z]*.c"
    "include/linux/[a-d]*.h"
    
    # Negated character class
    "kernel/[!a-m]*.c"
    "kernel/[!s-z]*.c"
    "drivers/base/[!a-c]*.c"
    "include/linux/[!a-m]*.h"
    
    # Mixed patterns
    "kernel/[a-z]???.c"
    "kernel/[a-z]????.c"
    "drivers/base/[a-z]*e*.c"
    "fs/ext4/[a-z]*t*.c"
    
    # Numeric ranges
    "arch/x86/kernel/*[0-9]*.c"
    "drivers/base/*[0-9].c"
    
    # Multiple wildcards
    "kernel/*_*_*.c"
    "drivers/base/*_*.c"
    "include/linux/*_*.h"
    
    # Deep paths
    "drivers/gpu/drm/*.c"
    "drivers/net/ethernet/*.c"
    "drivers/usb/core/*.c"
    "drivers/pci/*.c"
    "drivers/acpi/*.c"
    
    # Special characters in brackets
    "kernel/[_a-z]*.c"
    "include/linux/[_]*.h"
    
    # Edge cases
    "*"
    "kernel/*"
    
    # [[:alpha:]] - alphabetic characters
    "kernel/[[:alpha:]]*.c"
    "include/linux/[[:alpha:]]*.h"
    
    # [[:digit:]] - digits 0-9
    "arch/x86/kernel/*[[:digit:]]*.c"
    "drivers/base/*[[:digit:]].c"
    
    # [[:alnum:]] - alphanumeric
    "kernel/[[:alnum:]]*.c"
    
    # [[:lower:]] - lowercase letters
    "kernel/[[:lower:]]*.c"
    "include/linux/[[:lower:]]*.h"
    
    # [[:upper:]] - uppercase letters
    "include/linux/[[:upper:]]*.h"
    "Documentation/[[:upper:]]*.rst"
    
    # [[:space:]] - whitespace (unlikely to match filenames)
    # Skipped - filenames rarely have spaces
    
    # [[:punct:]] - punctuation
    "kernel/*[[:punct:]]*.c"
    
    # [[:xdigit:]] - hexadecimal digits
    "kernel/[[:xdigit:]]*.c"
    
    # Combined POSIX classes
    "kernel/[[:alpha:]_]*.c"
    "include/linux/[[:alnum:]_]*.h"
    
    # Negated POSIX classes
    "kernel/[^[:digit:]]*.c"
    "kernel/[![:upper:]]*.c"
    
    # Escaped special characters (if files exist with these names)
    # These test that backslash escaping works
    "kernel/\\[*.c"
    
    # Bracket as first character in class (] is literal)
    "kernel/[]a-z]*.c"
    
    # Hyphen at start (literal -)
    "kernel/[-a-z]*.c"
    
    # Hyphen at end (literal -)
    "kernel/[a-z-]*.c"
    
    # Empty result patterns
    "nonexistent/*.xyz"
    "kernel/*.nonexistent"
    
    # Patterns with dots
    "kernel/.*.c"
    ".*"
    
    # Single character filename patterns
    "kernel/?.c"
    "Documentation/?.rst"
)

echo ""
echo "========================================"
echo "zlob vs libc glob() Comparison Test"
echo "========================================"
echo "Test directory: $DIR"
echo "Patterns to test: ${#PATTERNS[@]}"
echo ""

PASSED=0
FAILED=0
FAILED_PATTERNS=()

for pattern in "${PATTERNS[@]}"; do
    result=$("$ZLOB_ROOT/zig-out/bin/compare_libc" "$DIR" "$pattern" 2>&1 | grep "Match count:" || echo "ERROR")
    
    if [ "$result" = "ERROR" ]; then
        echo -e "${RED}ERROR${NC}: Pattern '$pattern' - failed to run"
        FAILED=$((FAILED + 1))
        FAILED_PATTERNS+=("$pattern (error)")
        continue
    fi
    
    libc=$(echo "$result" | sed 's/.*libc=\([0-9]*\).*/\1/')
    zlob=$(echo "$result" | sed 's/.*zlob=\([0-9]*\).*/\1/')
    
    if [ "$libc" = "$zlob" ]; then
        echo -e "${GREEN}PASS${NC}: '$pattern' (libc=$libc, zlob=$zlob)"
        PASSED=$((PASSED + 1))
    else
        echo -e "${RED}FAIL${NC}: '$pattern' (libc=$libc, zlob=$zlob)"
        FAILED=$((FAILED + 1))
        FAILED_PATTERNS+=("$pattern (libc=$libc, zlob=$zlob)")
    fi
done

echo ""
echo "========================================"
echo "Summary"
echo "========================================"
echo -e "Passed: ${GREEN}$PASSED${NC}"
echo -e "Failed: ${RED}$FAILED${NC}"
echo "Total:  $((PASSED + FAILED))"

if [ $FAILED -gt 0 ]; then
    echo ""
    echo "Failed patterns:"
    for p in "${FAILED_PATTERNS[@]}"; do
        echo "  - $p"
    done
    exit 1
fi

echo ""
echo -e "${GREEN}All libc comparison tests passed!${NC}"
exit 0
