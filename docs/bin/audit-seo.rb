#!/usr/bin/env ruby
# frozen_string_literal: true

require 'cgi'
require 'json'
require 'pathname'
require 'rexml/document'
require 'uri'

site_dir = Pathname(ARGV.fetch(0)).expand_path
errors = []

def tags(html, name)
  html.scan(/<#{Regexp.escape(name)}\b[^>]*>/mi)
end

def attribute(tag, name)
  tag[/\b#{Regexp.escape(name)}=(["'])(.*?)\1/mi, 2]
end

def matching_tags(html, name, attribute_name, value)
  tags(html, name).select { |tag| attribute(tag, attribute_name) == value }
end

def page_url(site_root, site_dir, file)
  relative = file.relative_path_from(site_dir).to_s
  path = "/#{relative}".sub(%r{/index\.html\z}, '/')
  URI.join(site_root, path).to_s
end

index_path = site_dir.join('index.html')
abort "SEO audit failed: missing #{index_path}" unless index_path.file?

index_html = index_path.read
root_canonical = matching_tags(index_html, 'link', 'rel', 'canonical').first
site_root = URI(attribute(root_canonical.to_s, 'href'))

required_meta = {
  'name' => %w[description robots twitter:card twitter:title twitter:description twitter:image twitter:image:alt],
  'property' => %w[
    og:site_name og:title og:description og:url og:type og:locale og:image
    og:image:secure_url og:image:alt og:image:width og:image:height
  ]
}

indexable_canonicals = []
html_files = site_dir.glob('**/*.html').sort

# rubocop:disable Metrics/BlockLength
html_files.each do |file|
  html = file.read
  relative = file.relative_path_from(site_dir)
  links = matching_tags(html, 'link', 'rel', 'canonical')
  errors << "#{relative}: expected one canonical, found #{links.length}" unless links.one?
  canonical = attribute(links.first.to_s, 'href')

  required_meta.each do |attribute_name, values|
    values.each do |value|
      found = matching_tags(html, 'meta', attribute_name, value)
      errors << "#{relative}: expected one #{value} tag, found #{found.length}" unless found.one?
    end
  end

  robots_tag = matching_tags(html, 'meta', 'name', 'robots').first
  robots = attribute(robots_tag.to_s, 'content').to_s.downcase
  indexable = !robots.include?('noindex')
  expected_url = page_url(site_root, site_dir, file)
  if indexable
    errors << "#{relative}: canonical #{canonical.inspect} != #{expected_url}" unless canonical == expected_url
    unless robots.include?('index') && robots.include?('follow')
      errors << "#{relative}: robots must include index,follow"
    end
    errors << "#{relative}: robots contains nofollow" if robots.include?('nofollow')
    indexable_canonicals << canonical
  end

  description_tag = matching_tags(html, 'meta', 'name', 'description').first
  description = CGI.unescapeHTML(attribute(description_tag.to_s, 'content').to_s)
  unless (110..160).cover?(description.length)
    errors << "#{relative}: description length #{description.length} is outside 110..160"
  end

  title = CGI.unescapeHTML(html[%r{<title>(.*?)</title>}mi, 1].to_s.gsub(/<[^>]*>/, '').gsub(/\s+/, ' ').strip)
  errors << "#{relative}: title length #{title.length} is outside 20..60" unless (20..60).cover?(title.length)

  og_url = attribute(matching_tags(html, 'meta', 'property', 'og:url').first.to_s, 'content')
  errors << "#{relative}: og:url does not match canonical" unless og_url == canonical

  refresh = tags(html, 'meta').any? { |tag| attribute(tag, 'http-equiv').to_s.casecmp('refresh').zero? }
  errors << "#{relative}: meta-refresh redirect found" if refresh

  json_ld = html.scan(%r{<script\b[^>]*type="application/ld\+json"[^>]*>(.*?)</script>}mi).flatten
  errors << "#{relative}: expected one JSON-LD graph, found #{json_ld.length}" if indexable && !json_ld.one?
  json_ld.each do |json|
    JSON.parse(json)
  rescue JSON::ParserError => e
    errors << "#{relative}: invalid JSON-LD (#{e.message})"
  end

  tags(html, 'a').each do |tag|
    href = CGI.unescapeHTML(attribute(tag, 'href').to_s)
    next if href.empty? || href.start_with?('#', 'mailto:', 'tel:', 'javascript:')

    target = URI.join(expected_url, href)
    next unless target.host == site_root.host

    rel = attribute(tag, 'rel').to_s.split
    errors << "#{relative}: internal link has rel=nofollow (#{href})" if rel.include?('nofollow')
    errors << "#{relative}: generated Markdown is a crawlable link (#{href})" if target.path.end_with?('.md')
    errors << "#{relative}: internal link uses HTTP (#{href})" unless target.scheme == 'https'

    target_path = CGI.unescape(target.path).delete_prefix('/')
    local_target = site_dir.join(target_path)
    if target.path.end_with?('/')
      local_target = local_target.join('index.html')
    elsif local_target.directory?
      errors << "#{relative}: internal link relies on a trailing-slash redirect (#{href})"
      local_target = local_target.join('index.html')
    end
    errors << "#{relative}: broken internal link (#{href})" unless local_target.file?
  rescue URI::InvalidURIError
    errors << "#{relative}: invalid link (#{href})"
  end
end
# rubocop:enable Metrics/BlockLength

sitemap_path = site_dir.join('sitemap.xml')
robots_path = site_dir.join('robots.txt')
errors << 'sitemap.xml is missing' unless sitemap_path.file?
errors << 'robots.txt is missing' unless robots_path.file?

if sitemap_path.file?
  begin
    sitemap = sitemap_path.read
    REXML::Document.new(sitemap)
    locations = sitemap.scan(%r{<loc>(.*?)</loc>}m).flatten.map { |url| CGI.unescapeHTML(url.strip) }
    errors << 'sitemap.xml contains duplicate URLs' unless locations.length == locations.uniq.length
    missing = indexable_canonicals.uniq - locations
    extra = locations - indexable_canonicals.uniq
    missing.each { |url| errors << "sitemap.xml is missing #{url}" }
    extra.each { |url| errors << "sitemap.xml includes non-indexable or unknown URL #{url}" }
  rescue REXML::ParseException => e
    errors << "sitemap.xml is invalid XML (#{e.message})"
  end
end

if robots_path.file?
  robots = robots_path.read
  errors << 'robots.txt does not block generated Markdown duplicates' unless robots.include?('Disallow: /*.md$')
  unless robots.include?("Sitemap: #{site_root}sitemap.xml")
    errors << 'robots.txt does not advertise the canonical sitemap'
  end
end

if errors.empty?
  puts "SEO audit passed for #{html_files.length} HTML pages (#{indexable_canonicals.uniq.length} indexable)"
else
  warn "SEO audit failed with #{errors.length} error(s):"
  errors.each { |error| warn "- #{error}" }
  exit 1
end
