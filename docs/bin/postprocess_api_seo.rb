# frozen_string_literal: true

require 'cgi'
require 'json'
require 'pathname'

output_dir = Pathname(ARGV.fetch(0)).expand_path
site_root = ARGV.fetch(1).sub(%r{/+\z}, '')
image_url = "#{site_root}/assets/images/archspec-social.png"
default_robots = 'index,follow,max-image-preview:large,max-snippet:-1,max-video-preview:-1'
api_urls = []
description_suffix = [
  'Read the generated ArchSpec Ruby API reference for related classes, modules, methods,',
  'configuration, and architecture checks.'
].join(' ')

def tag(name, attributes)
  rendered = attributes.map { |key, value| %(#{key}="#{CGI.escapeHTML(value)}") }.join(' ')
  "<#{name} #{rendered}>"
end

def inject_head(html, content)
  html.sub(/<head>/i, "<head>\n#{content}")
end

def bounded_description(description, suffix)
  text = description.gsub(/<[^>]*>/, '').gsub(/\+([^+]+)\+/, '\\1').gsub(/\s+/, ' ').strip
  text = "ArchSpec Ruby API documentation. #{suffix}" if text.empty?
  text = "#{text.sub(/[.\s]*\z/, '')}. #{suffix}" if text.length < 110
  return text if text.length <= 155

  shortened = text[0, 152].sub(/\s+\S*\z/, '').rstrip
  "#{shortened}…"
end

def api_title(title)
  name = title.sub(/\A(?:class|module)\s+/, '')
              .sub(/\s+-\s+ArchSpec API(?: Documentation)?\z/, '')
              .sub(/\AArchSpec::/, '')
  return 'ArchSpec Ruby API Reference' if name == 'ArchSpec'

  name = "#{name} reference" if %w[CLI DSL].include?(name)
  "#{name} | ArchSpec API"
end

# rubocop:disable Metrics/BlockLength
output_dir.glob('**/*.html').sort.each do |path|
  relative_path = path.relative_path_from(output_dir).to_s
  html = path.read
  redirect = html.match?(/<meta[^>]+http-equiv="refresh"/i)
  main_alias = relative_path == 'ArchSpec.html'
  target = html[/<meta[^>]+http-equiv="refresh"[^>]+url=([^";]+)[^>]*>/i, 1]
  canonical = if relative_path == 'index.html' || main_alias
                "#{site_root}/api/"
              elsif redirect && target
                "#{site_root}/api/#{target}"
              else
                "#{site_root}/api/#{relative_path}"
              end
  robots = redirect || main_alias ? 'noindex,follow' : default_robots
  title = CGI.unescapeHTML(html[%r{<title>(.*?)</title>}mi, 1].to_s.gsub(/<[^>]*>/, '')).strip
  title = api_title(title)
  raw_description = CGI.unescapeHTML(html[/<meta\s+name="description"\s+content="([^"]*)"/mi, 1].to_s)
  description = bounded_description(raw_description, description_suffix)

  html.gsub!(%r{href="(?:\./)?(?:\.\./)*ArchSpec\.html(#[^"]*)?"}) do
    %(href="#{site_root}/api/#{Regexp.last_match(1)}")
  end
  html.sub!(%r{<title>.*?</title>}mi, "<title>#{CGI.escapeHTML(title)}</title>")
  html.gsub!(/<link\b(?=[^>]*\brel="canonical")[^>]*>\s*/mi, '')
  html.gsub!(/<meta\b(?=[^>]*\bname="(?:description|robots|twitter:[^"]+)")[^>]*>\s*/mi, '')
  html.gsub!(/<meta\b(?=[^>]*\bproperty="og:[^"]+")[^>]*>\s*/mi, '')
  html.gsub!(%r{<script\b[^>]*type="application/ld\+json"[^>]*>.*?</script>\s*}mi, '')
  metadata = [
    tag('link', 'rel' => 'canonical', 'href' => canonical),
    tag('meta', 'name' => 'description', 'content' => description),
    tag('meta', 'name' => 'robots', 'content' => robots),
    tag('meta', 'property' => 'og:site_name', 'content' => 'ArchSpec'),
    tag('meta', 'property' => 'og:title', 'content' => title),
    tag('meta', 'property' => 'og:description', 'content' => description),
    tag('meta', 'property' => 'og:url', 'content' => canonical),
    tag('meta', 'property' => 'og:type', 'content' => 'article'),
    tag('meta', 'property' => 'og:locale', 'content' => 'en_US'),
    tag('meta', 'property' => 'og:image', 'content' => image_url),
    tag('meta', 'property' => 'og:image:secure_url', 'content' => image_url),
    tag('meta', 'property' => 'og:image:alt', 'content' => 'ArchSpec — Architecture linter for Ruby and Rails'),
    tag('meta', 'property' => 'og:image:width', 'content' => '1200'),
    tag('meta', 'property' => 'og:image:height', 'content' => '630'),
    tag('meta', 'name' => 'twitter:card', 'content' => 'summary_large_image'),
    tag('meta', 'name' => 'twitter:title', 'content' => title),
    tag('meta', 'name' => 'twitter:description', 'content' => description),
    tag('meta', 'name' => 'twitter:image', 'content' => image_url),
    tag('meta', 'name' => 'twitter:image:alt', 'content' => 'ArchSpec — Architecture linter for Ruby and Rails')
  ]

  unless redirect || main_alias
    website_id = "#{site_root}/#website"
    webpage_id = "#{canonical}#webpage"
    graph = {
      '@context' => 'https://schema.org',
      '@graph' => [
        {
          '@type' => 'Organization', '@id' => "#{site_root}/#identity",
          'name' => 'ArchSpec', 'url' => site_root,
          'sameAs' => ['https://github.com/crmne/archspec', 'https://rubygems.org/gems/archspec']
        },
        {
          '@type' => 'WebSite', '@id' => website_id, 'url' => "#{site_root}/",
          'name' => 'ArchSpec', 'description' => 'Architecture linter for Ruby and Rails.',
          'inLanguage' => 'en-US', 'publisher' => { '@id' => "#{site_root}/#identity" }
        },
        {
          '@type' => 'ImageObject', '@id' => "#{image_url}#primaryimage",
          'url' => image_url, 'contentUrl' => image_url,
          'caption' => 'ArchSpec — Architecture linter for Ruby and Rails',
          'width' => 1200, 'height' => 630
        },
        {
          '@type' => 'WebPage', '@id' => webpage_id, 'url' => canonical,
          'name' => title, 'description' => description,
          'isPartOf' => { '@id' => website_id }, 'inLanguage' => 'en-US',
          'primaryImageOfPage' => { '@id' => "#{image_url}#primaryimage" },
          'mainEntity' => { '@id' => "#{canonical}#article" }
        },
        {
          '@type' => 'TechArticle', '@id' => "#{canonical}#article",
          'mainEntityOfPage' => { '@id' => webpage_id }, 'headline' => title,
          'description' => description, 'inLanguage' => 'en-US',
          'image' => { '@id' => "#{image_url}#primaryimage" },
          'publisher' => { '@id' => "#{site_root}/#identity" }
        }
      ]
    }
    metadata << %(<script type="application/ld+json">#{JSON.generate(graph)}</script>)
    api_urls << canonical
  end

  html = inject_head(html, metadata.join("\n"))
  html.sub!(/<body\b/i, "</head>\n<body") unless html.match?(%r{</head>}i)
  html = "#{html.rstrip}\n</html>\n" unless html.match?(%r{</html>}i)
  path.write(html)
end
# rubocop:enable Metrics/BlockLength

sitemap_path = output_dir.parent.join('sitemap.xml')
if sitemap_path.file?
  sitemap = sitemap_path.read
  api_prefix = Regexp.escape(CGI.escapeHTML("#{site_root}/api/"))
  sitemap.gsub!(%r{\s*<url>\s*<loc>#{api_prefix}[^<]*</loc>.*?</url>}m, '')
  rows = api_urls.uniq.sort.map do |url|
    "  <url>\n    <loc>#{CGI.escapeHTML(url)}</loc>\n  </url>"
  end.join("\n")
  sitemap.sub!(%r{</urlset>}, "#{rows}\n</urlset>")
  sitemap_path.write(sitemap)
end
