set shell := ["bash", "-euo", "pipefail", "-c"]

default:
    @just --list

# Run BitMachineKit's tests (headless)
test:
    swift test

# Regenerate BitMachine.xcodeproj from project.yml
gen:
    xcodegen generate --use-cache

# Build the macOS app
build: gen
    xcodebuild -project BitMachine.xcodeproj -scheme BitMachine build

# Build and launch the app
run: build
    open "$(xcodebuild -project BitMachine.xcodeproj -scheme BitMachine -showBuildSettings 2>/dev/null | awk '/ BUILT_PRODUCTS_DIR /{print $3}')/BitMachine.app"

# Launch a Debug build in the background, listening on a socket for scripts/debug.py to drive (snapshots, menus),
# without taking focus; files are opened with it
[positional-arguments]
debug-app *files: build
    mkdir -p "$HOME/Library/Application Support/BitMachine"
    rm -f "$HOME/Library/Application Support/BitMachine/debug.sock"
    open -n -g --env DEBUG_SOCKET="$HOME/Library/Application Support/BitMachine/debug.sock" -a "$(xcodebuild -project BitMachine.xcodeproj -scheme BitMachine -showBuildSettings 2>/dev/null | awk '/ BUILT_PRODUCTS_DIR /{print $3}')/BitMachine.app" "$@"
    scripts/debug.py ping >/dev/null && echo "BitMachine is listening; try: just debug snapshot out.png"

# Send a command to the Debug build started by debug-app (try: just debug help)
[positional-arguments]
debug *args:
    @scripts/debug.py "$@"

# Remove build artifacts and the generated Xcode project
clean:
    rm -rf .build DerivedData BitMachine.xcodeproj

# The release recipes (release-check, doctor, bump, ship and the rest): app-release, in release.just, which
# apple-template keeps up to date
import 'release.just'
