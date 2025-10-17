# LibreDWG Build Pipeline

Automated build pipeline for creating truly portable LibreDWG binaries for ARM64 (macOS and Linux).

## Problem

The binaries had hardcoded dependencies on external libraries:
- **macOS**: `/opt/homebrew/opt/libiconv/lib/libiconv.2.dylib` 
- **Linux**: Missing libraries on minimal distributions

This broke portability in Docker containers and systems without Homebrew.

## Solution

Bundle all dependencies and use relative paths:
- **macOS**: `@loader_path/../lib/` for library loading
- **Linux**: `$ORIGIN/../lib/` with patchelf rpath

## How It Works

1. Build LibreDWG with dependencies
2. Run `scripts/fix-*-dependencies.sh` to bundle libraries
3. Update binary paths to use relative loading
4. Verify in clean environment
5. Create portable tarball

## Usage

### Download Pre-built Binaries

```bash
wget https://github.com/rite-build/dwg2dxf/releases/latest/download/libredwg-darwin-arm64.tar.gz
tar -xzf libredwg-darwin-arm64.tar.gz
./darwin-arm64/bin/dwg2dxf input.dwg -o output.dxf
```

### Trigger a Build

1. Go to [Actions](https://github.com/rite-build/libredwg-build/actions)
2. Run "Build LibreDWG" workflow
3. Enter LibreDWG version (e.g., `0.13.3`)

### Test a Tarball

```bash
./scripts/test-tarball.sh libredwg-darwin-arm64.tar.gz
```

## Verification

**macOS** - Check dependencies:
```bash
otool -L darwin-arm64/bin/dwg2dxf
# Should show: @loader_path/../lib/libiconv.2.dylib ✅
```

**Linux** - Check dependencies:
```bash
ldd linux-arm64/bin/dwg2dxf
# Should resolve all libraries ✅
```

## Files

```
.github/workflows/build-libredwg.yml  # CI/CD pipeline
scripts/fix-macos-dependencies.sh     # macOS dependency bundling
scripts/fix-linux-dependencies.sh     # Linux dependency bundling  
scripts/test-tarball.sh               # Portability verification
```

## Technical Details

### Directory Structure
```
darwin-arm64/
├── bin/dwg2dxf              # Uses @loader_path/../lib/
├── lib/libiconv.2.dylib     # Bundled dependency
└── share/libredwg/          # Data files
```

### macOS: install_name_tool + codesign
- Scans binaries with `otool -L`
- Copies libraries to `lib/`
- Changes paths to `@loader_path/../lib/`
- Re-signs all binaries/libraries (fixes invalid signatures after modification)

### Linux: patchelf
- Scans binaries with `ldd`
- Copies libraries to `lib/`
- Sets rpath to `$ORIGIN/../lib`

## Troubleshooting

**"Library not found" error**: Run the fix script manually
```bash
./scripts/fix-macos-dependencies.sh artifacts/darwin-arm64
```

**Invalid code signature (macOS)**: After modifying binaries with `install_name_tool`, they must be re-signed
```bash
# Check signature
codesign --verify --verbose darwin-arm64/lib/libiconv.2.dylib

# Re-sign if needed
codesign --force --sign - darwin-arm64/lib/libiconv.2.dylib
```

**Test in Docker** (Linux):
```bash
docker run --rm -v $(pwd):/work -w /work arm64v8/ubuntu:22.04 \
  bash -c "tar -xzf libredwg-linux-arm64.tar.gz && ./linux-arm64/bin/dwg2dxf --version"
```

## References

- [LibreDWG](https://github.com/LibreDWG/libredwg)
- [Apple @rpath docs](https://developer.apple.com/library/archive/documentation/DeveloperTools/Conceptual/DynamicLibraries/100-Articles/RunpathDependentLibraries.html)
