#!/usr/bin/env bash
# Build the RDoc API docs into the given directory, landing on the ArchSpec module page.
#   docs/bin/build-api.sh <output-dir> [source-root]
# source-root is the checkout whose lib/ is documented (a release worktree
# when building an older version); it defaults to this repository.
set -euo pipefail

out="${1:?usage: build-api.sh <output-dir> [source-root]}"
repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source_root="${2:-$repo}"
case "$out" in /*) ;; *) out="$repo/$out" ;; esac

# Drop the docs bundle's env so the root Gemfile (which has rdoc) resolves.
unset RUBYOPT RUBYLIB BUNDLE_GEMFILE BUNDLE_BIN_PATH BUNDLE_BIN BUNDLE_APP_CONFIG

( cd "$source_root" && BUNDLE_GEMFILE="$repo/Gemfile" bundle exec rdoc --output "$out" --quiet lib )

# RDoc normally makes /api/ a meta-refresh to ArchSpec.html. Publish the full
# module reference at the canonical landing URL so readers arrive directly at
# the documentation and crawlers see real content.
cp "$out/ArchSpec.html" "$out/index.html"

( cd "$repo" && bundle exec ruby docs/bin/postprocess_api_seo.rb "$out" "${SITE_BASE_URL:-https://archspecrb.dev}" )
