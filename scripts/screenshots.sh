#!/bin/zsh
# Regenerates the README screenshots in docs/screenshots using the debug build's
# --snapshot mode (no Screen Recording permission needed).
set -euo pipefail
cd "$(dirname "$0")/.."
[[ -z "${SDKROOT:-}" && -d /Library/Developer/CommandLineTools/SDKs/MacOSX26.sdk ]] && export SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX26.sdk
swift build
BIN="$(swift build --show-bin-path)/PyCalc"
EX="$PWD/docs/examples"
OUT="$PWD/docs/screenshots"
mkdir -p "$OUT"

shot() {
  local name=$1; shift
  echo "› $name"
  "$BIN" --snapshot "$OUT/$name.png" "$@" >/dev/null 2>&1
  sips -Z 1600 "$OUT/$name.png" >/dev/null
}

shot overview   --script "$EX/welcome.py"
shot calculator --script "$EX/projectile.py"
shot formats    --script "$EX/fraction.py"
shot graphing   --script "$EX/curves.py"
shot errors     --script "$EX/error.py"
shot history    --script "$EX/welcome.py" --seed "$EX" --history
shot reference  --script "$EX/fraction.py" --reference --degrees --live
[[ -f "$OUT/reference.popover.png" ]] && mv "$OUT/reference.popover.png" "$OUT/reference-popover.png"
echo "✓ $OUT"
