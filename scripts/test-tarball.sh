#!/bin/bash
set -e

TARBALL="$1"

if [ -z "$TARBALL" ] || [ ! -f "$TARBALL" ]; then
    echo "Usage: $0 <tarball.tar.gz>"
    exit 1
fi

TARBALL_ABS=$(cd "$(dirname "$TARBALL")" && pwd)/$(basename "$TARBALL")

echo "Testing: $TARBALL"

TEST_DIR="/tmp/test-libredwg-$$"
mkdir -p "$TEST_DIR"
cd "$TEST_DIR"
tar -xzf "$TARBALL_ABS"

PLATFORM_DIR=$(find . -maxdepth 1 -type d ! -name "." | head -1)
PLATFORM_DIR=$(basename "$PLATFORM_DIR")

if [[ "$PLATFORM_DIR" == darwin-* ]]; then
    PLATFORM_TYPE="darwin"
else
    PLATFORM_TYPE="linux"
fi

echo "Platform: $PLATFORM_DIR"
echo ""
echo "Checking dependencies..."

BINARIES=$(find "$PLATFORM_DIR/bin" -type f -perm +111 2>/dev/null || find "$PLATFORM_DIR/bin" -type f -perm /111)
FAIL_COUNT=0

for bin in $BINARIES; do
    bin_name=$(basename "$bin")
    
    if [ "$PLATFORM_TYPE" = "darwin" ]; then
        if ! file "$bin" | grep -q "Mach-O"; then continue; fi
        
        # Check dependencies
        if otool -L "$bin" | grep -E "(homebrew|/opt/)" | grep -v "@loader_path" | grep -v ":"; then
            echo "❌ $bin_name: Hardcoded external dependency found"
            FAIL_COUNT=$((FAIL_COUNT + 1))
        else
            echo "✅ $bin_name: Dependencies OK"
        fi
        
        # Check code signature
        if codesign --verify --verbose "$bin" 2>&1; then
            echo "✅ $bin_name: Code signature valid"
        else
            echo "❌ $bin_name: Invalid code signature"
            FAIL_COUNT=$((FAIL_COUNT + 1))
        fi
    else
        if ! file "$bin" | grep -q "ELF"; then continue; fi
        if ldd "$bin" 2>&1 | grep -q "not found"; then
            echo "❌ $bin_name: Missing library"
            FAIL_COUNT=$((FAIL_COUNT + 1))
        else
            echo "✅ $bin_name: Dependencies OK"
        fi
    fi
    
    # Test execution
    if "$bin" --version &>/dev/null || "$bin" --help &>/dev/null; then
        echo "✅ $bin_name: Execution OK"
    fi
done

# Check bundled libraries
if [ -d "$PLATFORM_DIR/lib" ]; then
    echo ""
    echo "Checking bundled libraries..."
    
    if [ "$PLATFORM_TYPE" = "darwin" ]; then
        for lib in "$PLATFORM_DIR/lib"/*.dylib; do
            if [ -f "$lib" ] && [ ! -L "$lib" ]; then
                lib_name=$(basename "$lib")
                
                # Check code signature
                if codesign --verify --verbose "$lib" 2>&1; then
                    echo "✅ $lib_name: Code signature valid"
                else
                    echo "❌ $lib_name: Invalid code signature"
                    FAIL_COUNT=$((FAIL_COUNT + 1))
                fi
            fi
        done
    fi
fi

if [ $FAIL_COUNT -gt 0 ]; then
    echo ""
    echo "❌ FAILED: $FAIL_COUNT binary(ies) have issues"
    cd /
    rm -rf "$TEST_DIR"
    exit 1
fi

echo ""
echo "✅ All tests passed - tarball is portable!"

cd /
rm -rf "$TEST_DIR"

