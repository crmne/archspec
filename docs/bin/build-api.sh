#!/usr/bin/env bash
# Build the RDoc API docs into the given directory, landing on the ArchSpec module page.
#   docs/bin/build-api.sh <output-dir>
set -euo pipefail

out="${1:?usage: build-api.sh <output-dir>}"
repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
case "$out" in /*) ;; *) out="$repo/$out" ;; esac

# Drop the docs bundle's env so the root Gemfile (which has rdoc) resolves.
unset RUBYOPT RUBYLIB BUNDLE_GEMFILE BUNDLE_BIN_PATH BUNDLE_BIN BUNDLE_APP_CONFIG

( cd "$repo" && bundle exec rdoc --output "$out" --quiet lib )

# RDoc's main page must be a file, so the curated landing lives in the ArchSpec
# module doc and the index redirects there.
cat > "$out/index.html" <<'HTML'
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta http-equiv="refresh" content="0; url=ArchSpec.html">
<link rel="canonical" href="ArchSpec.html">
<title>ArchSpec API</title>
</head>
<body><a href="ArchSpec.html">ArchSpec API documentation</a></body>
</html>
HTML
