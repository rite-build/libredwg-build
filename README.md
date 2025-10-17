# LibreDWG Build Pipeline

Automated build pipeline for creating truly portable LibreDWG binaries for ARM64 (macOS and Linux).

## Problem

1. **Hardcoded dependencies** broke portability (Homebrew paths, missing libs)
2. **`--disable-write` caused corrupted DXF output** (files smaller than expected)

## Solution

1. **Enable write support** (removed `--disable-write` and `--disable-json`)
2. **Bundle dependencies** with relative paths (`@executable_path/../lib/`, `$ORIGIN/../lib`)

## How It Works

1. Build LibreDWG with write/JSON enabled + static/shared libs
2. Bundle all dependencies with `scripts/fix-*-dependencies.sh`
3. Update paths to relative loading
4. Verify and create portable tarball

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
# Should show: @executable_path/lib/libiconv.2.dylib ✅
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
├── bin/dwg2dxf              # Uses @executable_path/../lib/
├── lib/
│   ├── libredwg.0.dylib     # LibreDWG shared library (uses @loader_path/)
│   ├── libiconv.2.dylib     # Bundled iconv dependency (uses @loader_path/)
│   └── *.a                  # Static libraries
└── share/libredwg/          # Data files
```

### macOS: install_name_tool + codesign
- Scans binaries and shared libraries with `otool -L`
- Copies all dependencies (iconv, LibreDWG's own libs) to `lib/`
- Changes binary paths to `@executable_path/../lib/`
- Changes library-to-library paths to `@loader_path/`
- Re-signs all binaries/libraries (fixes invalid signatures after modification)

### Linux: patchelf
- Scans binaries and shared libraries with `ldd`
- Copies all dependencies (iconv, LibreDWG's own libs) to `lib/`
- Sets rpath to `$ORIGIN/../lib` for binaries
- Sets rpath to `$ORIGIN` for libraries

## Build Configuration

- ✅ Write/JSON support enabled (fixes corrupted output)
- ✅ Static + shared libraries
- ❌ Python/language bindings disabled

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
