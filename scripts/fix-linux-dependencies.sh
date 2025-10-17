#!/bin/bash
set -e

# Script to fix Linux binary dependencies by bundling required libraries
# and updating rpath to use $ORIGIN

ARTIFACT_DIR="$1"

if [ -z "$ARTIFACT_DIR" ]; then
    echo "Usage: $0 <artifact_directory>"
    echo "Example: $0 artifacts/linux-arm64"
    exit 1
fi

if [ ! -d "$ARTIFACT_DIR" ]; then
    echo "Error: Directory $ARTIFACT_DIR does not exist"
    exit 1
fi

echo "=== Fixing Linux dependencies for $ARTIFACT_DIR ==="

BIN_DIR="$ARTIFACT_DIR/bin"
LIB_DIR="$ARTIFACT_DIR/lib"

# Ensure lib directory exists
mkdir -p "$LIB_DIR"

# Check if patchelf is available
if ! command -v patchelf &> /dev/null; then
    echo "Installing patchelf..."
    sudo apt-get update -qq
    sudo apt-get install -y -qq patchelf
fi

# Function to copy a library and its dependencies
copy_library() {
    local lib_path="$1"
    local lib_name=$(basename "$lib_path")
    local target_path="$LIB_DIR/$lib_name"
    
    if [ ! -f "$target_path" ]; then
        echo "  Copying $lib_name..."
        cp "$lib_path" "$target_path"
        chmod 644 "$target_path"
        
        # Set rpath for the library itself
        patchelf --set-rpath '$ORIGIN' "$target_path" 2>/dev/null || true
        
        # Check if this library has dependencies on other non-system libraries
        ldd "$target_path" 2>/dev/null | grep "=>" | grep -v "ld-linux" | awk '{print $3}' | while read -r dep; do
            if [ -n "$dep" ] && [ -f "$dep" ]; then
                # Skip system libraries
                if echo "$dep" | grep -qE "^/(lib|usr/lib)"; then
                    # Check if it's a common system library
                    if ! echo "$dep" | grep -qE "(libc\.|libm\.|libpthread\.|libdl\.|librt\.)"; then
                        # This might be a non-standard library, copy it
                        copy_library "$dep"
                    fi
                else
                    # Non-system path, definitely copy it
                    copy_library "$dep"
                fi
            fi
        done
    fi
}

# Function to get the real path of a library (following symlinks)
get_real_lib_path() {
    local lib_name="$1"
    
    # Try common library paths
    for dir in /usr/lib /usr/lib/aarch64-linux-gnu /usr/lib/x86_64-linux-gnu /usr/local/lib /lib /lib/aarch64-linux-gnu /lib/x86_64-linux-gnu; do
        if [ -f "$dir/$lib_name" ]; then
            readlink -f "$dir/$lib_name"
            return
        fi
    done
    
    # Try using ldconfig
    ldconfig -p 2>/dev/null | grep "$lib_name" | head -1 | awk '{print $NF}'
}

# Function to fix a binary
fix_binary() {
    local binary_path="$1"
    local binary_name=$(basename "$binary_path")
    
    echo "Fixing $binary_name..."
    
    # Get all dependencies
    ldd "$binary_path" 2>/dev/null | grep "=>" | while read -r line; do
        lib_name=$(echo "$line" | awk '{print $1}')
        lib_path=$(echo "$line" | awk '{print $3}')
        
        if [ -n "$lib_path" ] && [ -f "$lib_path" ]; then
            # Skip common system libraries that should always be present
            if echo "$lib_path" | grep -qE "^/(lib|usr/lib)/(ld-linux|libc\.|libm\.|libpthread\.|libdl\.|librt\.|libgcc|libstdc)"; then
                continue
            fi
            
            # Copy the library if not already present
            echo "  Found dependency: $lib_name -> $lib_path"
            copy_library "$lib_path"
        fi
    done
    
    # Set rpath to look in ../lib relative to the binary
    echo "  Setting rpath to \$ORIGIN/../lib"
    patchelf --set-rpath '$ORIGIN/../lib' "$binary_path"
    
    # Also check for any versioned libraries (e.g., libiconv.so.2)
    # and create non-versioned symlinks
    for lib in "$LIB_DIR"/*.so*; do
        if [ -f "$lib" ] && [ ! -L "$lib" ]; then
            lib_name=$(basename "$lib")
            # Extract base name without version (e.g., libiconv.so.2 -> libiconv.so)
            base_name=$(echo "$lib_name" | sed 's/\.so\.[0-9]*$/.so/')
            if [ "$base_name" != "$lib_name" ] && [ ! -e "$LIB_DIR/$base_name" ]; then
                echo "  Creating symlink: $base_name -> $lib_name"
                (cd "$LIB_DIR" && ln -sf "$lib_name" "$base_name")
            fi
        fi
    done
}

# Process all executables in the bin directory
if [ -d "$BIN_DIR" ]; then
    for binary in "$BIN_DIR"/*; do
        if [ -f "$binary" ] && [ -x "$binary" ]; then
            # Check if it's an ELF binary
            if file "$binary" | grep -q "ELF"; then
                fix_binary "$binary"
            fi
        fi
    done
else
    echo "Warning: No bin directory found in $ARTIFACT_DIR"
fi

echo ""
echo "=== Verification ==="
echo "Checking all binaries for dependencies..."
echo ""

ALL_GOOD=true
for binary in "$BIN_DIR"/*; do
    if [ -f "$binary" ] && [ -x "$binary" ]; then
        if file "$binary" | grep -q "ELF"; then
            echo "Dependencies for $(basename "$binary"):"
            echo "  RPATH: $(patchelf --print-rpath "$binary" 2>/dev/null || echo "not set")"
            ldd "$binary" 2>/dev/null || true
            echo ""
            
            # Check for any missing libraries
            if ldd "$binary" 2>&1 | grep -q "not found"; then
                echo "❌ WARNING: Missing dependencies in $(basename "$binary")"
                ALL_GOOD=false
            fi
        fi
    fi
done

if [ -d "$LIB_DIR" ] && [ "$(ls -A $LIB_DIR 2>/dev/null)" ]; then
    echo "Bundled libraries:"
    ls -lh "$LIB_DIR"
    echo ""
    
    # Verify each library
    for lib in "$LIB_DIR"/*.so*; do
        if [ -f "$lib" ] && [ ! -L "$lib" ]; then
            echo "Dependencies for $(basename "$lib"):"
            echo "  RPATH: $(patchelf --print-rpath "$lib" 2>/dev/null || echo "not set")"
            ldd "$lib" 2>/dev/null | head -10 || true
            echo ""
        fi
    done
fi

if [ "$ALL_GOOD" = true ]; then
    echo "✅ All binaries are properly configured!"
else
    echo "❌ Some binaries have issues"
    exit 1
fi

echo ""
echo "=== Summary ==="
echo "Binaries fixed: $(find "$BIN_DIR" -type f -perm /111 | wc -l | tr -d ' ')"
echo "Libraries bundled: $(find "$LIB_DIR" -type f -name '*.so*' ! -type l 2>/dev/null | wc -l | tr -d ' ')"
echo "All dependencies are now relative using \$ORIGIN"

