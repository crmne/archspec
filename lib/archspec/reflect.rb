# frozen_string_literal: true

require 'fileutils'
require 'pathname'

require_relative 'error'
require_relative 'facts'
require_relative 'version'

module ArchSpec
  # Writes the Active Record facts file from inside a booted application. This
  # is the one place ArchSpec touches the running app, and only
  # <tt>archspec reflect</tt> calls it: +check+ stays static and merges the
  # file this writes. Every association whose class the app can name becomes a
  # reference; polymorphic associations and reflections that raise are
  # counted as misses rather than guessed.
  module Reflect
    extend self

    PRODUCER = 'archspec-reflect'
    SINGULAR_MACROS = %i[belongs_to has_one].freeze
    SINGULAR_HELPERS = ['build_%s', 'create_%s', 'create_%s!', 'reload_%s'].freeze
    COLLECTION_HELPERS = ['%s_ids', '%s_ids='].freeze

    def run(output:, root:)
      eager_load
      models = ::ActiveRecord::Base.descendants.reject(&:abstract_class?)
      facts = facts_for(models, root: root)
      FileUtils.mkdir_p(File.dirname(output))
      Facts.write(output, commit: Facts.commit_for(root), dirty: Facts.dirty?(root), **facts)
      facts
    end

    # Collects references and generated methods from model classes that
    # respond to +name+ and +reflect_on_all_associations+. Kept free of Rails
    # so the writer is tested with stand-ins.
    def facts_for(models, root:)
      references = []
      generated = []
      misses = Hash.new(0)

      models.sort_by(&:name).each do |model|
        location = source_location_for(model, root)
        names = []

        model.reflect_on_all_associations.sort_by(&:name).each do |reflection|
          next unless reflection.active_record.equal?(model)

          names.concat(helper_names(reflection))
          next misses['polymorphic'] += 1 if reflection.polymorphic?

          target = target_for(reflection)
          next misses['unresolved'] += 1 unless target

          references << FactsReference.new(
            owner: model.name,
            file: location.first,
            line: location.last,
            target: target,
            macro: reflection.macro.to_s,
            name: reflection.name.to_s,
            determination: 'reflected'
          )
        end

        generated << FactsGeneratedMethods.new(owner: model.name, names: names.uniq) if names.any?
      end

      {
        producer: PRODUCER,
        producer_version: VERSION,
        references: references,
        generated_methods: generated,
        misses: misses.sort.to_h
      }
    end

    private

    def eager_load
      ::Rails.application.eager_load! if defined?(::Rails) && ::Rails.respond_to?(:application)
    end

    def target_for(reflection)
      reflection.klass.name
    rescue StandardError
      nil
    end

    def helper_names(reflection)
      name = reflection.name.to_s
      names = [name, "#{name}="]
      templates = SINGULAR_MACROS.include?(reflection.macro) ? SINGULAR_HELPERS : COLLECTION_HELPERS
      names + templates.map { |template| format(template, name) }
    end

    def source_location_for(model, root)
      file, line = Object.const_source_location(model.name)
      return ['(unknown)', 1] unless file

      [Pathname(file).relative_path_from(Pathname(File.expand_path(root))).to_s, line]
    rescue NameError
      ['(unknown)', 1]
    rescue ArgumentError
      [file, line]
    end
  end
end
