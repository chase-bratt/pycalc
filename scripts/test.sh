#!/bin/zsh
# Runs the Python kernel tests and the Swift core tests.
set -euo pipefail
cd "$(dirname "$0")/.."
uv run --no-project --python 3.9 --with 'pytest==8.3.*' --with 'pytest-cov==6.*' pytest kernel_tests -q --cov=Resources --cov-report=term-missing
# The macOS 27 SDK's SwiftUI macros ship only with full Xcode; the 26 SDK builds with Command Line Tools.
[[ -z "${SDKROOT:-}" && -d /Library/Developer/CommandLineTools/SDKs/MacOSX26.sdk ]] && export SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX26.sdk
PLUGIN=/Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing/libTestingMacros.dylib
if [[ -f $PLUGIN ]]; then
  swift test -Xswiftc -load-plugin-library -Xswiftc "$PLUGIN"
else
  swift test
fi
