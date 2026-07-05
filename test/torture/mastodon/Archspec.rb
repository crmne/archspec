# frozen_string_literal: true

# Acronyms from Mastodon's config/initializers/inflections.rb.
inflect 'activitypub' => 'ActivityPub',
        'ascii' => 'ASCII',
        'cli' => 'CLI',
        'deepl' => 'DeepL',
        'dsl' => 'DSL',
        'jsonld' => 'JsonLd',
        'oauth' => 'OAuth',
        'oembed' => 'OEmbed',
        'ostatus' => 'OStatus',
        'pubsubhubbub' => 'PubSubHubbub',
        'rest' => 'REST',
        'rss' => 'RSS',
        'statsd' => 'StatsD',
        'seo' => 'SEO',
        'toc' => 'TOC',
        'url' => 'URL'

architecture :rails

# lib/ is required manually (config.autoload_lib is off), so its files are not
# Zeitwerk-named. Verify only the autoloaded app/ tree.
verify_zeitwerk_names! 'app/**/*.rb'
