#!/bin/bash
# Compiles and runs both check suites: the pure pixel engine, and the canvas view.
#
# Exits non-zero if any check fails, so it works as a CI gate. Both suites are
# always run, even if the first one fails — one combined report beats having to
# fix, re-push and wait to discover the second failure.
set -uo pipefail
cd "$(dirname "$0")/.."
TMP=$(mktemp -d)

ENGINE_SOURCES=(
  Sources/iPaint/PaintEngine.swift
  Sources/iPaint/Layer.swift
  Sources/iPaint/LayerOperations.swift
  Sources/iPaint/Shapes.swift
  Sources/iPaint/Palette.swift
  Sources/iPaint/Presets.swift
  Sources/iPaint/Tooltip.swift
)

failed=0

echo "=== engine ==="
if swiftc -O -o "$TMP/engine" "${ENGINE_SOURCES[@]}" tests/main.swift; then
  "$TMP/engine" | tee "$TMP/engine.out" || failed=1
  # tee hides the binary's exit code, so recover it from PIPESTATUS
  [ "${PIPESTATUS[0]}" -eq 0 ] || failed=1
else
  echo "engine suite failed to COMPILE"
  failed=1
fi

echo
echo "=== canvas view (zoom, pinch, text, tooltips) ==="
if swiftc -O -o "$TMP/ui" "${ENGINE_SOURCES[@]}" \
     Sources/iPaint/TextBox.swift Sources/iPaint/CanvasView.swift tests/ui/main.swift; then
  "$TMP/ui" | tee "$TMP/ui.out" || failed=1
  [ "${PIPESTATUS[0]}" -eq 0 ] || failed=1
else
  echo "canvas suite failed to COMPILE"
  failed=1
fi

# A combined total, which CI quotes in the release notes.
passed=$(cat "$TMP"/*.out 2>/dev/null | grep -c '^  ok' || true)
failures=$(cat "$TMP"/*.out 2>/dev/null | grep -c '^  FAIL' || true)
echo
if [ "$failed" -ne 0 ]; then
  echo "=== $passed passed, $failures FAILED ==="
  exit 1
fi
echo "=== total: $passed checks passed ==="
if [ -n "${GITHUB_OUTPUT:-}" ]; then
  echo "checks=$passed" >> "$GITHUB_OUTPUT"
fi
