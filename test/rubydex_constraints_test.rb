# frozen_string_literal: true

require 'test_helper'
require 'json'
require 'stringio'

# What a resolver lets the rules state: gem code owned by name, calls on a
# named receiver, protocols through the engine's chain, signatures, aliases,
# descendants and the engine's own doubts. Every run here feeds the resolver
# a stand-in index, so nothing depends on the gem being installed.
class RubydexConstraintsTest < ArchSpecTest
  MODELS = {
    'app/models/user.rb' => "class User < ApplicationRecord\n  def fetch = Net::HTTP.get('x')\n  def all = User.find_by_sql('x')\nend\n",
    'app/models/post.rb' => "class Post < ApplicationRecord\n  def fetch = Net::FTP.new\nend\n"
  }.freeze

  def test_a_component_owns_gem_code_by_namespace_and_a_dependency_rule_sees_it
    definition = ArchSpec.define do
      component :models, in: 'app/models/**/*.rb'
      component :http, namespace: 'Net'
      models.cannot_use :http
      resolver :rubydex
    end
    externals = [external('Net::HTTP', 'class', 'net-http'), external('Net::FTP', 'class', 'net-ftp')]
    answers = [resolution('app/models/user.rb', 2, 'Net::HTTP', in_workspace: false),
               resolution('app/models/post.rb', 2, 'Net::FTP', in_workspace: false)]

    with_index(MODELS, definition, *answers, externals: externals) do |graph|
      diagnostics = ArchSpec::Evaluator.evaluate(definition, graph)

      assert_equal ['models must not depend on http'] * 2, diagnostics.map(&:message).sort
      assert_equal Set['Net::FTP', 'Net::HTTP'], graph.components.fetch(:http).externals
      assert_empty graph.components.fetch(:http).constants
      assert_equal 2, graph.census.external_references
    end
  end

  def test_an_external_is_never_a_member
    definition = ArchSpec.define do
      component :models, in: 'app/models/**/*.rb'
      component :http, namespace: 'Net'
      http.must_be_empty because: 'nothing of ours lives there'
      http.must_implement :perform
      resolver :rubydex
    end

    with_index(MODELS, definition, resolution('app/models/user.rb', 2, 'Net::HTTP', in_workspace: false),
               externals: [external('Net::HTTP', 'class', 'net-http')]) do |graph|
      assert_empty ArchSpec::Evaluator.evaluate(definition, graph)
      assert_empty graph.constants_for_component(:http)
      assert_equal 'net-http', graph.constants_named('Net::HTTP').first.external
    end
  end

  def test_an_external_never_shadows_a_workspace_constant
    files = MODELS.merge('app/models/net/http.rb' => "module Net\n  class HTTP; end\nend\n")
    definition = ArchSpec.define do
      component :models, in: 'app/models/**/*.rb'
      resolver :rubydex
    end

    with_index(files, definition, externals: [external('Net::HTTP', 'class', 'net-http')]) do |graph|
      nodes = graph.constants_named('Net::HTTP')

      assert_equal 1, nodes.size
      refute nodes.first.external?
      merged = graph.facts_files.find { |file| file.relative_path == 'archspec-rubydex (resolver)' }
      assert_equal({ 'external_defined_in_workspace' => 1 }, merged.misses)
    end
  end

  def test_cannot_call_on_a_named_receiver_fires_through_its_descendants_and_not_on_an_untyped_one
    files = {
      'app/models/user.rb' => "class User < ApplicationRecord\n  def all = User.find_by_sql('x')\n  def some = conn.find_by_sql('y')\nend\n"
    }
    definition = ArchSpec.define do
      component :models, in: 'app/models/**/*.rb'
      models.cannot_call :find_by_sql, receiver: 'ActiveRecord::Base'
      resolver :rubydex
    end
    ancestors = [chain('User', %w[User ApplicationRecord ActiveRecord::Base Object], [['User', 'class'], ['ApplicationRecord', 'class'], ['ActiveRecord::Base', 'class']])]
    externals = [external('ApplicationRecord', 'class', 'workspace-gem'), external('ActiveRecord::Base', 'class', 'activerecord', class_methods: %w[find_by_sql])]

    with_index(files, definition, externals: externals, ancestors: ancestors) do |graph|
      diagnostics = ArchSpec::Evaluator.evaluate(definition, graph)

      assert_equal ['User calls find_by_sql on User'], diagnostics.map(&:evidence)
      assert_equal [2], diagnostics.map { |diagnostic| diagnostic.location.line }
    end
  end

  def test_cannot_call_on_a_named_receiver_is_refused_for_anything_but_a_constant_name
    error = assert_raises(ArchSpec::Error) do
      ArchSpec.define do
        component :models, in: 'app/models/**/*.rb'
        models.cannot_call :save, receiver: :self
      end
    end

    assert_match 'must be :any, :none or a constant name', error.message
  end

  def test_a_protocol_is_satisfied_through_a_gem_ancestor_the_engine_linearised
    files = { 'app/jobs/mail_job.rb' => "class MailJob < ApplicationJob\nend\n" }
    definition = ArchSpec.define do
      component :jobs, in: 'app/jobs/**/*.rb'
      jobs.must_implement :perform_later, scope: :class
      jobs.must_implement :enqueue
      resolver :rubydex
    end
    externals = [external('ApplicationJob', 'class', 'workspace-gem'),
                 external('ActiveJob::Base', 'class', 'activejob', instance_methods: %w[enqueue]),
                 external('ActiveJob::Enqueuing::ClassMethods', 'module', 'activejob', instance_methods: %w[perform_later])]
    ancestors = [chain('MailJob', %w[MailJob ApplicationJob ActiveJob::Base Object],
                       [['MailJob', 'class'], ['ApplicationJob', 'class'], ['ActiveJob::Enqueuing::ClassMethods', 'instance'], ['ActiveJob::Base', 'class']])]

    with_index(files, definition, externals: externals, ancestors: ancestors) do |graph|
      assert_empty ArchSpec::Evaluator.evaluate(definition, graph)
      methods, unresolved = graph.effective_class_methods('MailJob')
      assert_includes methods, :perform_later
      assert_empty unresolved
    end
  end

  def test_a_chain_the_engine_marked_dynamic_keeps_the_parsers_walk_and_doubts_the_finding
    files = { 'app/jobs/mail_job.rb' => "class MailJob < (ENV['FAST'] ? FastJob : SlowJob)\n  def perform = render\nend\n" }
    definition = ArchSpec.define do
      component :jobs, in: 'app/jobs/**/*.rb'
      jobs.cannot_call :render, receiver: :none
      resolver :rubydex
    end

    with_index(files, definition, diagnostics: [diagnostic('DynamicAncestor', 'app/jobs/mail_job.rb', 1)]) do |graph|
      diagnostics = ArchSpec::Evaluator.evaluate(definition, graph)

      assert_equal %i[medium], diagnostics.map(&:confidence)
      assert_equal 'DynamicAncestor at line 1', diagnostics.first.caveat
      assert_equal({ 'DynamicAncestor' => 1 }, graph.census.engine_diagnostics)
      assert_includes graph.census.clauses, '1 engine diagnostic'
    end
  end

  def test_must_implement_checks_arity_and_keywords_against_the_recorded_signature
    files = {
      'app/services/charge.rb' => "class Charge\n  def call(amount, actor:) = amount\nend\n",
      'app/services/refund.rb' => "class Refund\n  def call = nil\nend\n"
    }
    definition = ArchSpec.define do
      component :services, in: 'app/services/**/*.rb'
      services.must_implement :call, arity: 1, keyword: :actor
      resolver :rubydex
    end

    with_index(files, definition) do |graph|
      diagnostics = ArchSpec::Evaluator.evaluate(definition, graph)

      assert_equal ['Refund must implement #call taking 1 positional with keyword actor:'], diagnostics.map(&:message)
      assert_equal ['Refund #call takes 0 positional, lacks keyword actor:'], diagnostics.map(&:evidence)
    end
  end

  def test_a_definition_without_a_signature_is_a_miss_not_a_match
    files = { 'app/services/charge.rb' => "class Charge\n  delegate :call, to: :inner\nend\n" }
    definition = ArchSpec.define do
      component :services, in: 'app/services/**/*.rb'
      services.must_implement :call, arity: 1
      resolver :rubydex
    end

    with_index(files, definition) do |graph|
      diagnostics = ArchSpec::Evaluator.evaluate(definition, graph)

      assert_equal ['Charge #call has no recorded signature'], diagnostics.map(&:evidence)
    end
  end

  def test_a_signature_the_engine_states_fills_a_definition_the_parser_had_none_for
    files = { 'app/services/charge.rb' => "class Charge\n  delegate :call, to: :inner\nend\n" }
    definition = ArchSpec.define do
      component :services, in: 'app/services/**/*.rb'
      services.must_implement :call, arity: 1
      resolver :rubydex
    end
    definitions = [definition_fact('Charge', 'call', 'app/services/charge.rb', 2, signature: signature(required: 1))]

    with_index(files, definition, definitions: definitions) do |graph|
      assert_empty ArchSpec::Evaluator.evaluate(definition, graph)
      assert_equal 1, graph.constants_named('Charge').first.definition_of(:call, :instance).signature.required
    end
  end

  def test_cannot_take_forbids_a_block_a_rest_parameter_or_a_keyword_on_public_methods
    files = {
      'app/api/client.rb' => "class Client\n  def get(path, *rest) = path\n  def post(path, &blk) = path\n  def put(path, options: {}) = path\n  private\n  def hidden(*all) = all\nend\n"
    }
    definition = ArchSpec.define do
      component :api, in: 'app/api/**/*.rb'
      api.cannot_take :block, :rest, keyword: :options
    end

    with_project do |root|
      files.each { |path, source| write "#{root}/#{path}", source }
      diagnostics = diagnostics_for(definition, root)

      assert_equal ['Client#get takes a rest parameter', 'Client#post takes a block', 'Client#put takes keyword options'],
                   diagnostics.map(&:evidence)
      assert_equal ['methods.take_forbid'], diagnostics.map(&:rule).uniq
    end
  end

  def test_cannot_take_refuses_a_shape_it_does_not_know
    error = assert_raises(ArchSpec::Error) do
      ArchSpec.define do
        component :api, in: 'app/api/**/*.rb'
        api.cannot_take :hash
      end
    end

    assert_match 'cannot_take takes :block, :rest or keyword:', error.message
  end

  def test_a_forbidden_constant_is_matched_under_its_alias
    files = {
      'app/models/page.rb' => "class Page\n  def parse = Nokogiri::HTML4.parse('')\nend\n",
      'app/models/loader.rb' => "module Loader\n  Parser = Nokogiri::HTML4\nend\n"
    }
    definition = ArchSpec.define do
      component :models, in: 'app/models/**/*.rb'
      models.cannot_reference_constants 'Nokogiri::HTML'
      resolver :rubydex
    end
    aliases = [alias_fact('Nokogiri', 'constant', 'Nokogiri::HTML4', 'Nokogiri::HTML', 'app/models/loader.rb', 2)]
    externals = [external('Nokogiri::HTML4', 'module', 'nokogiri'), external('Nokogiri::HTML', 'module', 'nokogiri')]

    with_index(files, definition, resolution('app/models/page.rb', 2, 'Nokogiri::HTML4', in_workspace: false),
               aliases: aliases, externals: externals) do |graph|
      diagnostics = ArchSpec::Evaluator.evaluate(definition, graph)

      assert_equal ['models must not reference Nokogiri::HTML4'], diagnostics.map(&:message).uniq
      assert_includes diagnostics.first.evidence, 'Nokogiri::HTML4 is an alias of Nokogiri::HTML'
    end
  end

  def test_a_forbidden_method_is_matched_under_its_alias
    files = {
      'app/models/user.rb' => "class User\n  def wipe = User.destroy_everything\nend\n",
      'app/models/base.rb' => "class Base\n  def self.destroy_all = nil\n  class << self\n    alias_method :destroy_everything, :destroy_all\n  end\nend\n"
    }
    definition = ArchSpec.define do
      component :models, in: 'app/models/**/*.rb'
      models.cannot_call :destroy_all
      resolver :rubydex
    end
    aliases = [alias_fact('User', 'method', 'destroy_everything', 'destroy_all', 'app/models/base.rb', 4)]

    with_index(files, definition, aliases: aliases) do |graph|
      diagnostics = ArchSpec::Evaluator.evaluate(definition, graph)

      assert_equal ['User calls destroy_everything'], diagnostics.map(&:evidence)
    end
  end

  def test_a_component_selects_the_descendants_of_a_constant
    files = {
      'app/models/user.rb' => "class User < ApplicationRecord\nend\n",
      'app/models/report.rb' => "class Report\nend\n",
      'app/models/application_record.rb' => "class ApplicationRecord < ActiveRecord::Base\nend\n"
    }
    definition = ArchSpec.define do
      component :records, descendants_of: 'ApplicationRecord'
      records.must_implement :audited
    end

    with_project do |root|
      files.each { |path, source| write "#{root}/#{path}", source }
      graph = ArchSpec::Analyzer.analyze(definition, root: root)

      assert_equal Set['ApplicationRecord', 'User'], graph.components.fetch(:records).constants
      assert_equal ['descends from ApplicationRecord'],
                   graph.component_assignment_reasons_for_constant('User').fetch(:records)
    end
  end

  def test_a_component_that_needs_a_resolver_reads_not_asked_without_one
    definition = ArchSpec.define do
      component :models, in: 'app/models/**/*.rb'
      component :http, namespace: 'Net'
      component :records, descendants_of: 'ActiveRecord::Base'
      models.cannot_use :http
    end

    with_project do |root|
      MODELS.each { |path, source| write "#{root}/#{path}", source }
      graph = ArchSpec::Analyzer.analyze(definition, root: root)
      diagnostics = ArchSpec::Evaluator.evaluate(definition, graph)
      output = StringIO.new
      ArchSpec::Formatters::Text.print(output, graph: graph, diagnostics: diagnostics)

      assert_empty diagnostics
      assert_equal({ 'http' => 'gem code under Net', 'records' => 'descendants of ActiveRecord::Base' }, graph.census.not_asked)
      assert_match(/could not see: .*2 components not asked \(http: gem code under Net; records: descendants of ActiveRecord::Base\)/,
                   output.string)
    end
  end

  def test_a_snapshot_keeps_externals_chains_aliases_signatures_and_diagnostics
    definition = ArchSpec.define do
      component :models, in: 'app/models/**/*.rb'
      component :http, namespace: 'Net'
      resolver :rubydex
    end
    ancestors = [chain('User', %w[User ApplicationRecord Object], [['User', 'class']])]
    aliases = [alias_fact('User', 'method', 'everything', 'all', 'app/models/user.rb', 3)]

    with_index(MODELS, definition, resolution('app/models/user.rb', 2, 'Net::HTTP', in_workspace: false),
               externals: [external('Net::HTTP', 'class', 'net-http', instance_methods: %w[get])],
               ancestors: ancestors, aliases: aliases,
               diagnostics: [diagnostic('DynamicAncestor', 'app/models/post.rb', 1)]) do |graph, _definition, root|
      directory = File.join(root, '.archspec')
      ArchSpec::Snapshot.write(directory, graph: graph, definition: definition, definition_digest: 'x', commit: nil, dirty: false)
      restored = ArchSpec::Snapshot.load(directory, root: root).graph

      external = restored.constants_named('Net::HTTP').first
      assert_equal 'net-http', external.external
      assert_equal Set[:get], external.instance_methods
      assert_equal Set['Net::HTTP'], restored.components.fetch(:http).externals
      assert_equal %w[User ApplicationRecord Object], restored.engine_ancestors('User', :instance).map(&:first)
      assert_equal Set[:all], restored.method_alias_targets('User', :everything)
      assert_equal [['DynamicAncestor', File.join(root, 'app/models/post.rb'), 1]], restored.engine_diagnostics
      assert_equal 0, restored.constants_named('User').first.definition_of(:fetch, :instance).signature.required
    end
  end

  def test_a_facts_file_refuses_a_malformed_external_or_signature
    with_project do |root|
      write "#{root}/app/models/user.rb", "class User; end\n"
      write "#{root}/archspec_facts/x.yml", <<~YAML
        format: 2
        producer: test
        producer_version: '1'
        references: []
        generated_methods: []
        externals:
          - name: Net::HTTP
            kind: gem
            origin: net-http
      YAML
      definition = ArchSpec.define { component :models, in: 'app/models/**/*.rb' }
      error = assert_raises(ArchSpec::Error) { ArchSpec::Analyzer.analyze(definition, root: root) }

      assert_match 'external 1 has kind "gem", not one of class, module, constant', error.message

      write "#{root}/archspec_facts/x.yml", <<~YAML
        format: 2
        producer: test
        producer_version: '1'
        references: []
        generated_methods: []
        definitions:
          - owner: User
            name: call
            scope: instance
            file: app/models/user.rb
            line: 1
            arity: { required: one }
      YAML
      error = assert_raises(ArchSpec::Error) { ArchSpec::Analyzer.analyze(definition, root: root) }

      assert_match 'definition 1 has a malformed signature', error.message
    end
  end

  def test_the_producer_writes_what_the_engine_stated_and_counts_what_the_parser_had
    with_project do |root|
      MODELS.each { |path, source| write "#{root}/#{path}", source }
      definition = ArchSpec.define { component :models, in: 'app/models/**/*.rb' }
      graph = ArchSpec::Analyzer.analyze(definition, root: root)
      facts = ArchSpec::Rubydex.facts_for(
        graph, [],
        externals: [external('Net::HTTP', 'class', 'net-http'), external('User', 'class', 'elsewhere')],
        ancestors: [chain('User', %w[User Object], [['User', 'class']]), chain('Gone', %w[Gone], [])],
        aliases: [alias_fact('User', 'method', 'everything', 'all', 'app/models/user.rb', 3),
                  alias_fact('Gem', 'constant', 'Gem::Thing', 'Gem::Other', 'vendor/gem.rb', 1)],
        diagnostics: [diagnostic('DynamicAncestor', 'app/models/post.rb', 1), diagnostic('ParseWarning', 'vendor/gem.rb', 9)],
        calls: [ArchSpec::Rubydex::Call.new(file: 'app/models/user.rb', line: 3, method: 'find_by_sql', receiver: 'User',
                                            scope: 'class', in_workspace: true)]
      )

      assert_equal ['Net::HTTP'], facts[:externals].map(&:name)
      assert_equal ['User'], facts[:ancestors].map(&:owner)
      assert_equal %w[everything], facts[:aliases].map(&:name)
      assert_equal %w[DynamicAncestor], facts[:diagnostics].map(&:rule)
      assert_equal({ 'alias_outside_source' => 1, 'ancestors_outside_source' => 1, 'call_already_resolved' => 1,
                     'external_defined_in_workspace' => 1 }, facts[:misses])
    end
  end

  def test_the_real_engine_states_externals_chains_and_receivers_for_this_gem
    skip 'set ARCHSPEC_RUBYDEX=1 to run the resolver against the installed gem' unless ENV['ARCHSPEC_RUBYDEX']
    begin
      require 'rubydex'
    rescue LoadError
      skip 'the rubydex gem is not installed for this Ruby'
    end

    root = File.expand_path('..', __dir__)
    Dir.mktmpdir('archspec-rubydex') do |cache|
      definition = ArchSpec.define do
        source 'lib/**/*.rb'
        component :library, in: 'lib/**/*.rb'
        component :stdlib_sets, namespace: 'Set'
        component :value_objects, descendants_of: 'ArchSpec::ValueObject'
        library.cannot_call :load, receiver: 'Marshal'
        resolver :rubydex
      end
      definition.cache(cache)
      graph = ArchSpec::Analyzer.analyze(definition, root: root)
      merged = graph.facts_files.find { |file| file.relative_path == 'archspec-rubydex (resolver)' }
      diagnostics = ArchSpec::Evaluator.evaluate(definition, graph)

      assert_operator merged.externals.size, :>, 0
      assert_operator merged.ancestors.size, :>, 0
      assert graph.externals.all? { |node| node.path.nil? && node.external }
      assert_includes graph.components.fetch(:stdlib_sets).externals, 'Set'
      assert_empty graph.components.fetch(:stdlib_sets).constants
      assert_equal ['methods.forbid'], diagnostics.map(&:rule).uniq
      assert diagnostics.all? { |diagnostic| diagnostic.evidence.end_with?('on Marshal') }
    end
  end

  private

  def resolution(file, line, target, in_workspace: true, column: nil)
    ArchSpec::Rubydex::Resolution.new(file: file, line: line, column: column, target: target, in_workspace: in_workspace)
  end

  def external(name, kind, origin, instance_methods: [], class_methods: [])
    ArchSpec::Rubydex::External.new(name: name, kind: kind, origin: origin, instance_methods: instance_methods,
                                    class_methods: class_methods)
  end

  def chain(owner, instance, class_side)
    ArchSpec::Rubydex::Ancestors.new(owner: owner, instance: instance, class_side: class_side, in_workspace: true)
  end

  def alias_fact(owner, kind, name, target, file, line)
    ArchSpec::Rubydex::Alias.new(owner: owner, kind: kind, name: name, target: target, file: file, line: line)
  end

  def diagnostic(rule, file, line)
    ArchSpec::Rubydex::Diagnostic.new(rule: rule, file: file, line: line)
  end

  def signature(required: 0, optional: 0, rest: false, keywords: [], optional_keywords: [], keyword_rest: false, block: false)
    ArchSpec::Signature.new(required, optional, rest, keywords, optional_keywords, keyword_rest, block)
  end

  def definition_fact(owner, name, file, line, scope: 'instance', signature: nil)
    ArchSpec::Rubydex::Definition.new(owner: owner, name: name, scope: scope, visibility: 'public', file: file, line: line,
                                      signature: signature)
  end

  def lockfile
    "GEM\n  remote: https://rubygems.org/\n  specs:\n    rake (13.2.0)\n\nPLATFORMS\n  ruby\n\nDEPENDENCIES\n\nBUNDLED WITH\n   2.5.0\n"
  end

  def with_index(files, definition, *resolutions, externals: [], ancestors: [], aliases: [], diagnostics: [],
                 definitions: [], calls: [])
    with_project do |root|
      files.each { |path, source| write "#{root}/#{path}", source }
      write "#{root}/Gemfile", "source 'https://rubygems.org'\n"
      write "#{root}/Gemfile.lock", lockfile
      found = { resolutions: resolutions, ancestry: [], definitions: definitions, calls: calls, misses: {},
                engine_version: '0.0.0', externals: externals, ancestors: ancestors, aliases: aliases,
                diagnostics: diagnostics }
      with_gem_stubbed(lockfile: "#{root}/Gemfile.lock", index: -> { found }) do
        yield ArchSpec::Analyzer.analyze(definition, root: root), definition, root
      end
    end
  end

  def with_gem_stubbed(lockfile:, index:)
    singleton = ArchSpec::Rubydex.singleton_class
    Object.const_set(:Rubydex, Module.new { const_set(:VERSION, '0.0.0') }) unless Object.const_defined?(:Rubydex)
    singleton.define_method(:load_gem) { nil }
    singleton.define_method(:bundle!) { |_root| lockfile }
    singleton.define_method(:index) { |_root| index.call }
    yield
  ensure
    singleton.remove_method(:load_gem)
    singleton.remove_method(:bundle!)
    singleton.remove_method(:index)
  end
end
