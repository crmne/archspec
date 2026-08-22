# frozen_string_literal: true

require 'fileutils'
require 'pathname'

require_relative 'error'
require_relative 'facts'
require_relative 'version'

module ArchSpec
  # Writes the Active Record facts file from the parsed tree alone, without
  # booting. An association becomes a reference in three determinations and
  # no fourth: its class_name: is a literal, its through: walks the
  # intermediates' own declarations hop by hop to a target, or its bare name matches exactly one
  # model the application declares. Everything else is counted by cause. A
  # collection name is matched by a lookup over the declared model names
  # with three plural spellings and no irregulars, never by an inflector.
  module Associations
    extend self

    PRODUCER = 'archspec-associations'
    RECORD_ROOTS = %w[ApplicationRecord ActiveRecord::Base].freeze
    SINGULAR_MACROS = %i[belongs_to has_one].freeze
    PLURAL_SPELLINGS = [['s', ''], ['es', ''], ['ies', 'y']].freeze

    def write(graph, output:, root:)
      facts = facts_for(graph)
      Facts.write_to(output, root: root, **facts)
      facts
    end

    def facts_file(graph)
      Facts.built(label: "#{PRODUCER} (built in)", **facts_for(graph))
    end

    def facts_for(graph)
      index = Index.new(graph)
      references = []
      misses = Hash.new(0)

      index.models.sort_by(&:name).each do |model|
        model.associations.each do |declaration|
          target, determination = index.resolve(declaration, model)
          next misses[determination] += 1 unless target

          references << FactsReference.new(
            owner: model.name,
            file: Pathname(model.path).relative_path_from(Pathname(graph.root)).to_s,
            line: declaration.location.line,
            target: target,
            macro: declaration.macro.to_s,
            name: declaration.name.to_s,
            determination: determination
          )
        end
      end

      index.unowned.each { |count| misses['unowned'] += count }

      {
        producer: PRODUCER,
        producer_version: VERSION,
        references: references,
        generated_methods: [],
        ancestry: ancestry_for(graph, index),
        misses: misses.sort.to_h
      }
    end

    # The superclass chain the index walked for each model, stated as the
    # inherits facts it trusted: one per hop, up to the last model before the
    # record root, with the same determination the walk gives an association.
    def ancestry_for(graph, index)
      index.models.sort_by(&:name).flat_map do |model|
        node = model
        index.ancestors_of(model).map do |ancestor|
          entry = FactsAncestry.new(
            owner: node.name,
            kind: 'inherits',
            target: ancestor.name,
            file: Pathname(node.path).relative_path_from(Pathname(graph.root)).to_s,
            line: node.location.line,
            determination: 'index'
          )
          node = ancestor
          entry
        end
      end.uniq
    end

    # The models an application declares: every class whose superclass chain
    # reaches an Active Record root, followed through subclasses to a fixed
    # point. Abstract classes and the roots themselves are records but never
    # owners or targets.
    class Index
      attr_reader :graph

      def initialize(graph)
        @graph = graph
        @records = collect_records
      end

      def models
        @models ||= @records.reject { |node| node.abstract? || RECORD_ROOTS.include?(node.name) }
      end

      def unowned
        graph.constants.reject { |node| models.include?(node) }.map { |node| node.associations.size }.reject(&:zero?)
      end

      def resolve(declaration, owner, walked = [])
        return [nil, 'restated'] if restated?(declaration, owner)
        return [nil, 'polymorphic'] if declaration.polymorphic
        return [nil, 'source_type'] if declaration.source_type
        return [nil, 'dynamic'] if declaration.class_name == :dynamic
        return resolve_declared(declaration, owner) if declaration.class_name
        return resolve_through(declaration, owner, walked) if declaration.through

        resolve_by_name(declaration, owner)
      end

      def ancestors_of(owner)
        chain = []
        node = owner
        while node&.superclass
          resolved = graph.resolve_constant_reference(node.superclass, node.name, lexical_nesting: node.nesting)
          node = @records.find { |record| record.name == resolved }
          break if node.nil? || chain.include?(node)

          chain << node
        end
        chain
      end

      private

      def collect_records
        records = Set.new
        loop do
          added = graph.constants.select do |node|
            node.class? && !records.include?(node) && node.superclass && reaches_record?(node, records)
          end
          break if added.empty?

          records.merge(added)
        end
        records.to_a
      end

      def reaches_record?(node, records)
        resolved = graph.resolve_constant_reference(node.superclass, node.name, lexical_nesting: node.nesting)
        RECORD_ROOTS.include?(resolved) || records.any? { |record| record.name == resolved }
      end


      def restated?(declaration, owner)
        ancestors_of(owner).any? do |ancestor|
          ancestor.associations.any? { |inherited| inherited.name == declaration.name }
        end
      end

      def resolve_declared(declaration, owner)
        target = graph.resolve_constant_reference(
          declaration.class_name, owner.name, lexical_nesting: [owner.name] + declaration.nesting
        )
        [target, 'declared']
      end

      # Each hop is an association resolved by the same rules as any other,
      # so a through: whose intermediate is itself a through: keeps walking.
      # The walk carries the declarations it has passed; meeting one again is
      # a cycle and a miss, not a loop.
      def resolve_through(declaration, owner, walked)
        hop = [owner.name, declaration.name]
        return [nil, 'unresolved_through'] if walked.include?(hop)

        walked += [hop]
        intermediate = own_association(owner, declaration.through)
        return [nil, 'unresolved_through'] unless intermediate

        intermediate_target, = resolve(intermediate, owner, walked)
        intermediate_model = intermediate_target && models.find { |model| model.name == intermediate_target }
        return [nil, 'unresolved_through'] unless intermediate_model

        source = source_association(intermediate_model, declaration)
        return [nil, 'unresolved_through'] unless source

        target, = resolve(source, intermediate_model, walked)
        target ? [target, 'through'] : [nil, 'unresolved_through']
      end

      def own_association(owner, name)
        ([owner] + ancestors_of(owner)).each do |model|
          found = model.associations.find { |candidate| candidate.name == name }
          return found if found
        end
        nil
      end

      def source_association(intermediate, declaration)
        return own_association(intermediate, declaration.source) if declaration.source

        own_association(intermediate, declaration.name) ||
          own_association(intermediate, singular_of(intermediate, declaration.name))
      end

      def singular_of(model, name)
        singulars = ([model] + ancestors_of(model)).flat_map(&:associations).map(&:name).uniq.select do |candidate|
          plural_spellings(candidate.to_s).include?(name.to_s)
        end
        singulars.size == 1 ? singulars.first : nil
      end

      # Active Record looks an association's class up inside the owner's own
      # namespace first, then each enclosing one: Account's join_code is
      # Account::JoinCode before it is JoinCode.
      def resolve_by_name(declaration, owner)
        scopes = owner.name.split('::')
        candidates = SINGULAR_MACROS.include?(declaration.macro) ? singular_candidates(declaration) : plural_candidates(declaration)

        scopes.size.downto(0) do |depth|
          prefix = scopes.first(depth).join('::')
          matches = candidates.select { |model| namespace_of(model.name) == prefix }
          next if matches.empty?
          return matches.size == 1 ? [matches.first.name, 'index'] : [nil, 'ambiguous']
        end

        [nil, 'unresolved']
      end

      def singular_candidates(declaration)
        wanted = camelize(declaration.name.to_s)
        models.select { |model| basename_of(model.name) == wanted }
      end

      def plural_candidates(declaration)
        models.select do |model|
          plural_spellings(underscore(basename_of(model.name))).include?(declaration.name.to_s)
        end
      end

      # The three spellings a collection name can take from a model name, and
      # nothing else: an irregular plural matches no model and is a miss.
      def plural_spellings(singular)
        PLURAL_SPELLINGS.map do |suffix, trimmed|
          next unless trimmed.empty? || singular.end_with?(trimmed)

          "#{singular[0, singular.size - trimmed.size]}#{suffix}"
        end.compact
      end

      def namespace_of(name)
        name.split('::')[0...-1].join('::')
      end

      def basename_of(name)
        name.split('::').last
      end

      def camelize(name)
        name.split('_').map(&:capitalize).join
      end

      def underscore(name)
        name.gsub(/([A-Z]+)([A-Z][a-z])/, '\1_\2').gsub(/([a-z\d])([A-Z])/, '\1_\2').downcase
      end
    end
  end
end
