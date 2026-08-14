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

# Give /api/ a real index page. GitHub Pages cannot emit a server-side redirect,
# and a crawlable landing is preferable to a client-side meta refresh.
cat > "$out/index.html" <<'HTML'
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<title>ArchSpec Ruby API Reference</title>
<meta name="description" content="Generated Ruby API documentation for ArchSpec classes, modules, and methods.">
<meta property="og:type" content="website">
<meta property="og:title" content="ArchSpec Ruby API Reference">
<meta property="og:description" content="Generated Ruby API documentation for ArchSpec classes, modules, and methods.">
<meta name="twitter:card" content="summary_large_image">
<meta name="twitter:title" content="ArchSpec Ruby API Reference">
<meta name="twitter:description" content="Generated Ruby API documentation for ArchSpec classes, modules, and methods.">
<link href="./css/rdoc.css?v=8.0.0" rel="stylesheet">
</head>
<body role="document">
<main class="main-content">
<h1>ArchSpec Ruby API Reference</h1>
<p>Generated documentation for ArchSpec classes, modules, and methods.</p>
<p><a href="ArchSpec.html">Open the ArchSpec module reference</a></p>
</main>
</body>
</html>
HTML

( cd "$repo" && bundle exec ruby docs/bin/postprocess_api_seo.rb "$out" "${SITE_BASE_URL:-https://archspecrb.dev}" )
