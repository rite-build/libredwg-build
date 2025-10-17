#!/bin/bash
set -e

# Script to fix macOS binary dependencies by bundling required libraries
# and updating install names to use @loader_path

ARTIFACT_DIR="$1"

if [ -z "$ARTIFACT_DIR" ]; then
    echo "Usage: $0 <artifact_directory>"
    echo "Example: $0 artifacts/darwin-arm64"
    exit 1
fi

if [ ! -d "$ARTIFACT_DIR" ]; then
    echo "Error: Directory $ARTIFACT_DIR does not exist"
    exit 1
fi

echo "=== Fixing macOS dependencies for $ARTIFACT_DIR ==="

BIN_DIR="$ARTIFACT_DIR/bin"
LIB_DIR="$ARTIFACT_DIR/lib"

# Ensure lib directory exists
mkdir -p "$LIB_DIR"

# Function to copy a library and its dependencies
copy_library() {
    local lib_path="$1"
    local lib_name=$(basename "$lib_path")
    local target_path="$LIB_DIR/$lib_name"
    
    if [ ! -f "$target_path" ]; then
        echo "  Copying $lib_name..."
        cp "$lib_path" "$target_path"
        chmod 644 "$target_path"
        
        # Set the library's install name to use @loader_path
        install_name_tool -id "@loader_path/$lib_name" "$target_path"
        
        # Check if this library has dependencies on other non-system libraries
        otool -L "$target_path" | grep -v ":" | grep -v "@loader_path" | grep -v "/usr/lib" | grep -v "/System/" | while read -r dep; do
            dep=$(echo "$dep" | awk '{print $1}')
            if [ -f "$dep" ]; then
                # Recursively copy dependencies
                copy_library "$dep"
                local dep_name=$(basename "$dep")
                # Update the reference in the current library
                install_name_tool -change "$dep" "@loader_path/$dep_name" "$target_path" 2>/dev/null || true
            fi
        done
    fi
}

# Function to fix a binary
fix_binary() {
    local binary_path="$1"
    local binary_name=$(basename "$binary_path")
    
    echo "Fixing $binary_name..."
    
    # Get all non-system dependencies
    otool -L "$binary_path" | grep -v ":" | grep -v "@loader_path" | grep -v "/usr/lib" | grep -v "/System/" | while read -r line; do
        lib_path=$(echo "$line" | awk '{print $1}')
        
        if [ -f "$lib_path" ]; then
            lib_name=$(basename "$lib_path")
            
            # Copy the library if not already present
            copy_library "$lib_path"
            
            # Update the binary to use @loader_path
            echo "  Updating reference: $lib_path -> @loader_path/../lib/$lib_name"
            install_name_tool -change "$lib_path" "@loader_path/../lib/$lib_name" "$binary_path"
        fi
    done
    
    # Also check for any versioned libraries (e.g., libiconv.2.dylib)
    # and create non-versioned symlinks
    for lib in "$LIB_DIR"/*.dylib; do
        if [ -f "$lib" ]; then
            lib_name=$(basename "$lib")
            # Extract base name without version (e.g., libiconv.2.dylib -> libiconv.dylib)
            base_name=$(echo "$lib_name" | sed 's/\.[0-9]*\.dylib$/.dylib/')
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
            # Check if it's a Mach-O binary
            if file "$binary" | grep -q "Mach-O"; then
                fix_binary "$binary"
            fi
        fi
    done
else
    echo "Warning: No bin directory found in $ARTIFACT_DIR"
fi

echo ""
echo "=== Verification ==="
echo "Checking all binaries for remaining external dependencies..."
echo ""

ALL_GOOD=true
for binary in "$BIN_DIR"/*; do
    if [ -f "$binary" ] && [ -x "$binary" ]; then
        if file "$binary" | grep -q "Mach-O"; then
            echo "Dependencies for $(basename "$binary"):"
            otool -L "$binary"
            echo ""
            
            # Check for any Homebrew or non-system paths
            if otool -L "$binary" | grep -E "(homebrew|/opt/|/usr/local)" | grep -v "@loader_path"; then
                echo "❌ WARNING: Found external dependency in $(basename "$binary")"
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
    for lib in "$LIB_DIR"/*.dylib; do
        if [ -f "$lib" ] && [ ! -L "$lib" ]; then
            echo "Dependencies for $(basename "$lib"):"
            otool -L "$lib"
            echo ""
            
            if otool -L "$lib" | grep -E "(homebrew|/opt/|/usr/local)" | grep -v "@loader_path" | grep -v "$(basename "$lib")"; then
                echo "❌ WARNING: Found external dependency in $(basename "$lib")"
                ALL_GOOD=false
            fi
        fi
    done
fi

if [ "$ALL_GOOD" = true ]; then
    echo "✅ All binaries are properly configured with bundled dependencies!"
else
    echo "❌ Some binaries still have external dependencies"
    exit 1
fi

echo ""
echo "=== Summary ==="
echo "Binaries fixed: $(find "$BIN_DIR" -type f -perm +111 | wc -l | tr -d ' ')"
echo "Libraries bundled: $(find "$LIB_DIR" -type f -name '*.dylib' ! -type l 2>/dev/null | wc -l | tr -d ' ')"
echo "All dependencies are now relative using @loader_path"

