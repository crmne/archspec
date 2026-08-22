# frozen_string_literal: true

require 'json'

module ArchSpec
  module Formatters
    # Prints a SARIF 2.1.0 log with one run: a rule per rule id, carrying the
    # rule's reason and the docs page for its family, and a result per finding
    # with its span, its fingerprint, and the rest of what the evaluator knows
    # about it as properties. GitHub's code-scanning upload renders it in the
    # Security tab and on the diff, keyed by the fingerprint across runs.
    module SARIF
      SCHEMA = 'https://docs.oasis-open.org/sarif/sarif/v2.1.0/errata01/os/schemas/sarif-schema-2.1.0.json'
      SCHEMA_VERSION = '2.1.0'
      DOCS = 'https://archspecrb.dev'
      FINGERPRINT_KEY = 'archspec/v1'
      FAMILIES = {
        'dependencies' => 'dependencies',
        'methods' => 'methods',
        'objects' => 'objects',
        'constants' => 'constants',
        'concerns' => 'concerns',
        'protocol' => 'protocols',
        'naming' => 'naming',
        'components' => 'components'
      }.freeze

      module_function

      def print(output = $stdout, graph:, diagnostics:)
        output.puts ::JSON.pretty_generate(log(graph, diagnostics))
      end

      # The same document with each current finding's bucket and, under the
      # run, the mode, the baseline receipt and the edge counts. Resolved
      # findings are reported too, at no level, so the history shows them
      # going away.
      def print_delta(output = $stdout, graph:, diagnostics:, delta:, mode:)
        buckets = {}
        delta.introduced.each { |diagnostic| buckets[diagnostic.fingerprint(root: graph.root)] = 'introduced' }
        delta.declared.each { |diagnostic| buckets[diagnostic.fingerprint(root: graph.root)] = 'declared' }
        delta.carried.each { |diagnostic| buckets[diagnostic.fingerprint(root: graph.root)] = 'carried' }
        delta.resolved.each { |diagnostic| buckets[diagnostic.fingerprint(root: graph.root)] = 'resolved' }

        run_properties = {
          mode: mode,
          baseline: {
            commit: delta.receipt.commit,
            dirty: delta.receipt.dirty,
            archspec_version: delta.receipt.archspec_version
          },
          edges: { added: delta.edges_added, removed: delta.edges_removed },
          changed_files_read: delta.changed_files_read
        }
        output.puts ::JSON.pretty_generate(log(graph, diagnostics + delta.resolved, buckets: buckets,
                                                                                    run_properties: run_properties))
      end

      def log(graph, diagnostics, buckets: nil, run_properties: nil)
        rules = rules_for(diagnostics)
        indexes = rules.each_with_index.to_h { |rule, index| [rule.fetch(:id), index] }
        {
          '$schema': SCHEMA,
          version: SCHEMA_VERSION,
          runs: [
            {
              tool: {
                driver: {
                  name: 'archspec',
                  version: VERSION,
                  informationUri: DOCS,
                  rules: rules
                }
              },
              results: diagnostics.map { |diagnostic| result(graph, diagnostic, indexes, buckets) },
              properties: run_properties_for(graph, run_properties)
            }
          ]
        }
      end

      # One entry per distinct rule id, in order of first appearance, described
      # by the first reason seen for it or by the id when no rule gave one.
      def rules_for(diagnostics)
        diagnostics.each_with_object([]) do |diagnostic, rules|
          next if rules.any? { |rule| rule.fetch(:id) == diagnostic.rule }

          rules << {
            id: diagnostic.rule,
            shortDescription: { text: diagnostic.reason || diagnostic.rule },
            helpUri: help_uri(diagnostic.rule)
          }
        end
      end

      def help_uri(rule_id)
        family = FAMILIES[rule_id.split('.').first]
        family ? "#{DOCS}/rules/#{family}/" : "#{DOCS}/cli/"
      end

      def result(graph, diagnostic, indexes, buckets)
        fingerprint = diagnostic.fingerprint(root: graph.root)
        bucket = buckets && buckets[fingerprint]
        location = diagnostic.location
        {
          ruleId: diagnostic.rule,
          ruleIndex: indexes.fetch(diagnostic.rule),
          level: level_for(diagnostic, bucket),
          message: { text: diagnostic.message },
          locations: [
            {
              physicalLocation: {
                artifactLocation: { uri: location.relative_path(graph.root), uriBaseId: '%SRCROOT%' },
                region: {
                  startLine: location.line,
                  startColumn: location.column,
                  endLine: location.end_line,
                  endColumn: location.end_column
                }
              }
            }
          ],
          partialFingerprints: { FINGERPRINT_KEY => fingerprint },
          properties: result_properties(diagnostic, bucket)
        }
      end

      def level_for(diagnostic, bucket)
        return 'none' if bucket == 'resolved'

        diagnostic.predates_rule? ? 'warning' : 'error'
      end

      def result_properties(diagnostic, bucket)
        properties = {
          confidence: diagnostic.confidence.to_s,
          caveat: diagnostic.caveat,
          since: diagnostic.since&.to_s,
          suggestedAction: diagnostic.suggested_action,
          evidence: diagnostic.evidence
        }
        properties[:bucket] = bucket if bucket
        properties
      end

      def run_properties_for(graph, extra)
        properties = {
          files: graph.files.size,
          constants: graph.constants.size,
          facts: graph.edges.size,
          factsFiles: graph.facts_files.map do |file|
            { path: file.relative_path, producer: file.producer, producerVersion: file.producer_version }
          end,
          census: graph.census.to_h,
          datingNote: graph.dating_note
        }
        extra ? properties.merge(extra) : properties
      end
    end
  end
end
