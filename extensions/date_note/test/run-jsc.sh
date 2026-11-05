#!/bin/zsh
# Usage: ./test/run-jsc.sh <path-to-antinote-extensions-base-v0.0.1.js>
set -e
HERE=${0:A:h}
JSC=/System/Library/Frameworks/JavaScriptCore.framework/Versions/A/Helpers/jsc
"$JSC" "$1" "$HERE/mock-prefs.js" "$HERE/../index.js" "$HERE/run.js"
