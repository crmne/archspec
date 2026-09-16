# frozen_string_literal: true

module ArchSpec
  module Facts
    # Framework-neutral facts, established by source semantics or by reflection.
    # Owners are graph ConstantNodes; locations retain the original evidence,
    # even when it lives in a different file from the owner.
    #
    # Use #apply for an in-memory semantic pass, or #to_document and Facts.write
    # for an explicit external producer. Both routes use the same validation and
    # application code. Building facts never mutates the graph.
    class Builder
      def initialize(graph, producer:)
        @graph = graph
        @producer = producer
        @entries = LIST_KEYS.to_h { |key| [key, []] }
      end

      def reference(source:, target:, location:)
        @entries['references'] << entry_for(source, location).merge('source' => source.name, 'target' => target)
      end

      def methods(owner:, names:, location:, scope: :instance, visibility: :public,
                  signatures: [], alias_target: nil, mode: :if_missing, installation: nil)
        unless alias_target.nil? || alias_target.is_a?(String) || alias_target.is_a?(Symbol)
          raise Error, 'alias target must be a String or Symbol'
        end
        entry = entry_for(owner, location).merge('owner' => owner.name, 'names' => names.map(&:to_s),
          'scope' => scope.to_s, 'visibility' => visibility.to_s, 'mode' => mode.to_s,
          'signatures' => signatures.map do |signature|
            signature.to_h.transform_keys(&:to_s).transform_values do |value|
              value.is_a?(Array) ? value.map(&:to_s) : value
            end
          end)
        entry['alias_target'] = alias_target.to_s unless alias_target.nil?
        entry['installation'] = location_for(installation) if installation
        @entries['methods'] << entry
      end

      # Preserve a source definition's metadata while installing it on an owner.
      # An installation site gives callback definitions their Ruby precedence:
      # later local definitions win, earlier definitions are replaced.
      def method_definition(owner:, definition:, installation: nil)
        methods(owner: owner, names: [definition.name], scope: definition.scope, location: definition.location,
          visibility: definition.visibility, signatures: definition.signatures, alias_target: definition.alias_target,
          mode: installation ? :define : :append, installation: installation)
      end

      # Emit mixins in installation order, including singleton prepends.
      def mixin(owner:, target:, kind:, location:)
        @entries['mixins'] << entry_for(owner, location).merge('owner' => owner.name,
          'target' => target, 'kind' => kind.to_s)
      end

      # Bind an existing receiverless call without changing its lexical owner.
      # Emit every consumer of a shared callback before applying the batch.
      def bind_receiver(edge:, receiver:, scope:)
        source = @graph.constants_named(edge.from_constant).find { |node| node.path == edge.from_path }
        raise Error, 'receiver fact requires a call owned by an analyzed constant' unless source

        @entries['receivers'] << entry_for(source, edge.location).merge('source' => source.name,
          'name' => edge.to, 'receiver' => receiver, 'scope' => scope.to_s)
      end

      def expose_methods(source:, owner:, scope:)
        @entries['exposures'] << entry_for(source, source.location).merge('source' => source.name,
          'owner' => owner.name, 'scope' => scope.to_s)
      end

      def gap(source:, message:, location:)
        @entries['gaps'] << entry_for(source, location).merge('source' => source.name, 'message' => message)
      end

      def apply
        document = Document.new(@graph, facts, @producer)
        Application.apply(@graph, [document.compile])
      end

      # Validate before publication, so malformed evidence cannot replace a
      # producer's previous snapshot. Environment remains the optional Rails
      # environment used by the version 1 contract.
      def to_document(facts_path: 'archspec_facts', environment: nil)
        document = facts.merge('environment' => environment)
        reader = Document.new(@graph, document, @producer)
        Application.validate(@graph, [reader.compile])
        document.merge('snapshot' => Facts.snapshot(@graph, excluding: facts_path))
      end

      private

      def facts
        { 'version' => VERSION, 'producer' => @producer }.merge(@entries)
      end

      def entry_for(source, location)
        location_for(location).merge('source_path' => Pathname(source.path).relative_path_from(Pathname(@graph.root)).to_s)
      end

      def location_for(location)
        location.to_h.transform_keys(&:to_s).merge('path' => location.relative_path(@graph.root))
      end
    end
  end
end
