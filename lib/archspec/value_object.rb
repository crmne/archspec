# frozen_string_literal: true

module ArchSpec
  module ValueObject
    def self.define(*members, &block)
      klass = Struct.new(*members) do
        members.each { |member| undef_method :"#{member}=" }

        def initialize(*values, **keywords)
          member_names = self.class.members

          if keywords.any?
            raise ArgumentError, 'expected positional arguments or keyword arguments, not both' unless values.empty?

            unknown = keywords.keys - member_names
            raise ArgumentError, "unknown keyword: #{unknown.first.inspect}" if unknown.any?

            missing = member_names - keywords.keys
            raise ArgumentError, "missing keyword: #{missing.first.inspect}" if missing.any?

            values = member_names.map { |member| keywords.fetch(member) }
          elsif values.length != member_names.length
            raise ArgumentError, "wrong number of arguments (given #{values.length}, expected #{member_names.length})"
          end

          super(*values)
          freeze
        end

        def with(**changes)
          unknown = changes.keys - self.class.members
          raise ArgumentError, "unknown keyword: #{unknown.first.inspect}" if unknown.any?

          self.class.new(**to_h.merge(changes))
        end
      end

      klass.class_eval(&block) if block
      klass
    end
  end
end
