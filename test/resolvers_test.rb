# frozen_string_literal: true

require 'test_helper'
require 'json'
require 'stringio'
require 'yaml'

class ResolversTest < ArchSpecTest
  POST_AND_USER = {
    'app/models/post.rb' => "class Post\n  def author = User.new\nend\n",
    'app/models/user.rb' => "class User; end\n"
  }.freeze

  def test_an_unknown_resolver_is_refused_by_name
    error = assert_raises(ArchSpec::Error) { ArchSpec.define { resolver :sorbet } }

    assert_match 'unknown resolver :sorbet; the resolvers are :rubydex', error.message
  end

  def test_both_resolvers_naming_the_same_constant_converge
    with_answers(POST_AND_USER, resolution('app/models/post.rb', 2, 'User')) do |graph|
      edge = reference_edge(graph, 'Post', 'User')
      resolution = graph.resolve_edge(edge)

      assert_equal :converged, resolution.determination
      assert_equal 'User', resolution.name
      assert_equal Set[:models], graph.target_components_for(edge)
      assert_equal({ converged: 1, parser_only: 0, resolver_only: 0, disagreed: 0, cache: 'miss', seconds: 0.0 },
                   graph.census.resolvers.fetch('rubydex'))
    end
  end

  def test_a_line_the_resolver_did_not_answer_keeps_the_parsers_resolution
    with_answers(POST_AND_USER) do |graph|
      resolution = graph.resolve_edge(reference_edge(graph, 'Post', 'User'))

      assert_equal :lexical, resolution.determination
      assert_equal 1, graph.census.resolvers.fetch('rubydex').fetch(:parser_only)
    end
  end

  def test_a_reference_only_the_resolver_answered_becomes_its_edge
    files = { 'app/models/post.rb' => "class Post\n  include Searchable\nend\n" }
    with_answers(files, resolution('app/models/post.rb', 2, 'Searchable', in_workspace: false)) do |graph|
      edges = graph.edges.select { |edge| edge.to == 'Searchable' && edge.type == :references_constant }
      from_resolver = edges.find { |edge| graph.facts_file_for(edge) }

      assert_equal 'archspec-rubydex (resolver)', graph.facts_file_for(from_resolver)
      assert_equal :from_facts_file, from_resolver.confidence
      assert_equal 1, graph.census.resolvers.fetch('rubydex').fetch(:resolver_only)
    end
  end

  def test_a_disagreement_is_no_edge_and_is_counted
    with_answers(POST_AND_USER, resolution('app/models/post.rb', 2, 'Admin::User')) do |graph|
      edge = reference_edge(graph, 'Post', 'User')
      resolution = graph.resolve_edge(edge)

      refute resolution.resolved?
      assert_equal :disagreed, resolution.cause
      assert_equal 'User', resolution.name
      assert_equal 'Admin::User', resolution.other
      assert_empty graph.target_components_for(edge)
      assert_equal 1, graph.census.resolvers.fetch('rubydex').fetch(:disagreed)
      assert_includes graph.census.clauses, '1 reference the resolvers disagree on'
      assert_includes graph.census.refused_names, 'User or Admin::User'
    end
  end

  def test_a_disagreement_removes_the_dependency_finding_and_doubts_the_rest_of_the_constant
    files = {
      'app/models/post.rb' => "class Post\n  def author = User.new\n  def show = render\nend\n",
      'app/models/user.rb' => "class User; end\n"
    }
    definition = ArchSpec.define do
      component :models, in: 'app/models/**/*.rb'
      component :users, in: 'app/models/user.rb'
      models.cannot_use :users
      models.cannot_call :render, receiver: :none
      resolver :rubydex
    end

    with_answers(files, resolution('app/models/post.rb', 2, 'Admin::User'), definition: definition) do |graph|
      diagnostics = ArchSpec::Evaluator.evaluate(definition, graph)

      assert_equal ['methods.forbid'], diagnostics.map(&:rule)
      assert_equal :medium, diagnostics.first.confidence
      assert_equal 'the resolvers disagree: parser User, rubydex Admin::User', diagnostics.first.caveat
    end
  end

  def test_an_answer_for_a_neighbouring_reference_on_the_line_is_not_a_disagreement
    files = {
      'app/models/post.rb' => "class Post\n  def pair = [User, Admin]\nend\n",
      'app/models/user.rb' => "class User; end\n",
      'app/models/admin.rb' => "class Admin; end\n"
    }
    with_answers(files, resolution('app/models/post.rb', 2, 'User')) do |graph|
      assert_equal :converged, graph.resolve_edge(reference_edge(graph, 'Post', 'User')).determination
      assert_equal :lexical, graph.resolve_edge(reference_edge(graph, 'Post', 'Admin')).determination
    end
  end

  def test_a_declared_resolver_whose_gem_is_absent_fails_the_check_by_name
    with_project do |root|
      POST_AND_USER.each { |path, source| write "#{root}/#{path}", source }
      write "#{root}/Archspec.rb", "component :models, in: 'app/models/**/*.rb'\nresolver :rubydex\n"
      write "#{root}/Gemfile", "source 'https://rubygems.org'\n"
      error = StringIO.new

      status = without_rubydex do
        Dir.chdir(root) { ArchSpec::CLI.run(['check'], output: StringIO.new, error: error) }
      end

      assert_equal 1, status
      assert_match 'rubydex gem is not loadable', error.string
    end
  end

  def test_a_declared_resolver_without_a_gemfile_fails_the_check_by_name
    with_project do |root|
      POST_AND_USER.each { |path, source| write "#{root}/#{path}", source }
      definition = ArchSpec.define do
        component :models, in: 'app/models/**/*.rb'
        resolver :rubydex
      end

      error = with_gem_stubbed { assert_raises(ArchSpec::Error) { ArchSpec::Analyzer.analyze(definition, root: root) } }

      assert_match 'no Gemfile', error.message
    end
  end

  def test_the_index_is_kept_between_runs_and_read_when_tree_and_bundle_are_unchanged
    with_project do |root|
      POST_AND_USER.each { |path, source| write "#{root}/#{path}", source }
      write "#{root}/Gemfile", "source 'https://rubygems.org'\n"
      write "#{root}/Gemfile.lock", lockfile
      definition = ArchSpec.define do
        component :models, in: 'app/models/**/*.rb'
        resolver :rubydex
      end
      indexed = 0
      found = index_of(resolution('app/models/post.rb', 2, 'User'))

      graphs = with_gem_stubbed(lockfile: "#{root}/Gemfile.lock", index: -> { indexed += 1; found }) do
        [ArchSpec::Analyzer.analyze(definition, root: root), ArchSpec::Analyzer.analyze(definition, root: root)]
      end

      assert_equal 1, indexed
      assert_equal %w[miss hit], graphs.map { |graph| graph.census.resolvers.fetch('rubydex').fetch(:cache) }
      assert_equal :converged, graphs.last.resolve_edge(reference_edge(graphs.last, 'Post', 'User')).determination
      cached = Dir.glob("#{root}/.archspec/resolvers/rubydex-*.yml")
      assert_equal 1, cached.size
      assert_equal 'archspec-rubydex-index', YAML.safe_load_file(cached.first)['producer']
      assert_equal "*\n", File.read("#{root}/.archspec/.gitignore")
    end
  end

  def test_a_changed_bundle_indexes_again
    with_project do |root|
      POST_AND_USER.each { |path, source| write "#{root}/#{path}", source }
      write "#{root}/Gemfile", "source 'https://rubygems.org'\n"
      write "#{root}/Gemfile.lock", lockfile
      definition = ArchSpec.define do
        component :models, in: 'app/models/**/*.rb'
        resolver :rubydex
      end
      indexed = 0
      found = index_of(resolution('app/models/post.rb', 2, 'User'))

      with_gem_stubbed(lockfile: "#{root}/Gemfile.lock", index: -> { indexed += 1; found }) do
        ArchSpec::Analyzer.analyze(definition, root: root)
        write "#{root}/Gemfile.lock", lockfile('rake (13.0.0)')
        ArchSpec::Analyzer.analyze(definition, root: root)
      end

      assert_equal 2, indexed
    end
  end

  def test_without_a_resolver_nothing_about_one_is_printed_or_recorded
    with_project do |root|
      POST_AND_USER.each { |path, source| write "#{root}/#{path}", source }
      definition = ArchSpec.define { component :models, in: 'app/models/**/*.rb' }
      graph = ArchSpec::Analyzer.analyze(definition, root: root)
      output = StringIO.new
      ArchSpec::Formatters::Text.print(output, graph: graph, diagnostics: [])

      assert_empty graph.resolvers
      assert_equal({}, graph.census.to_h.fetch(:resolvers))
      refute_match(/resolvers:/, output.string)
    end
  end

  def test_the_summary_and_json_carry_the_convergence_counts
    with_answers(POST_AND_USER, resolution('app/models/post.rb', 2, 'User')) do |graph|
      text = StringIO.new
      ArchSpec::Formatters::Text.print(text, graph: graph, diagnostics: [])
      json = StringIO.new
      ArchSpec::Formatters::JSON.print(json, graph: graph, diagnostics: [])
      resolvers = JSON.parse(json.string).fetch('census').fetch('resolvers')

      assert_match(/^resolvers: rubydex: converged 1, parser only 0, rubydex only 0, disagreed 0 \(index miss, 0\.00s\)$/,
                   text.string)
      assert_equal %w[cache converged disagreed parser_only resolver_only seconds], resolvers.fetch('rubydex').keys.sort
    end
  end

  def test_explain_prints_both_answers_on_every_edge
    files = {
      'app/models/post.rb' => "class Post\n  def author = User.new\n  def editor = Admin.new\n  include Searchable\nend\n",
      'app/models/user.rb' => "class User; end\n",
      'app/models/admin.rb' => "class Admin; end\n"
    }
    answers = [resolution('app/models/post.rb', 2, 'User'), resolution('app/models/post.rb', 3, 'Staff::Admin'),
               resolution('app/models/post.rb', 4, 'Searchable', in_workspace: false)]

    with_answers(files, *answers) do |graph, definition, root|
      explanation = ArchSpec::Explanation.build(
        graph: graph, rules: definition.rules, diagnostics: [], todo: ArchSpec::Todo.empty,
        subject: File.join(root, 'app/models/post.rb'),
        origin: ArchSpec::Explanation::Origin.new(source: :analysis, commit: nil, dirty: false, cause: nil)
      ) { |rule, unassigned| rule.evaluate(unassigned) }
      determinations = explanation.outgoing.map { |edge| [edge.target, edge.determination.to_s] }

      assert_includes determinations, ['User', 'converged, both User']
      assert_includes determinations, ['Admin', 'disagreed, parser Admin, resolver Staff::Admin']
      assert_includes determinations, %w[Searchable rubydex]
    end
  end

  def test_reflect_writes_the_facts_the_check_merged
    with_project do |root|
      files = { 'app/models/post.rb' => "class Post\n  include Searchable\nend\n" }
      files.each { |path, source| write "#{root}/#{path}", source }
      write "#{root}/Gemfile", "source 'https://rubygems.org'\n"
      write "#{root}/Gemfile.lock", lockfile
      write "#{root}/Archspec.rb", "component :models, in: 'app/models/**/*.rb'\nresolver :rubydex\n"
      found = index_of(resolution('app/models/post.rb', 2, 'Searchable', in_workspace: false))

      with_gem_stubbed(lockfile: "#{root}/Gemfile.lock", index: -> { found }) do
        status = Dir.chdir(root) { ArchSpec::CLI.run(['reflect', '--rubydex'], output: StringIO.new, error: StringIO.new) }
        assert_equal 0, status
        definition, = ArchSpec::CLI.send(:load_definition, File.join(root, 'Archspec.rb'))
        graph = ArchSpec::Analyzer.analyze(definition, root: root)
        written = ArchSpec::Facts.load_file("#{root}/archspec_facts/rubydex.yml", root: root)
        merged = graph.facts_files.find { |file| file.relative_path == 'archspec-rubydex (resolver)' }

        assert_equal written.references, merged.references
        assert_equal written.producer_version, merged.producer_version
      end
    end
  end

  private

  def resolution(file, line, target, in_workspace: true)
    ArchSpec::Rubydex::Resolution.new(file: file, line: line, target: target, in_workspace: in_workspace)
  end

  def reference_edge(graph, owner, target)
    graph.edges.find do |edge|
      edge.type == :references_constant && edge.from_constant == owner && edge.to == target && !graph.facts_file_for(edge)
    end
  end

  def index_of(*resolutions)
    { resolutions: resolutions, ancestry: [], definitions: [], calls: [], misses: {}, engine_version: '0.0.0' }
  end

  def lockfile(gem = 'rake (13.2.0)')
    "GEM\n  remote: https://rubygems.org/\n  specs:\n    #{gem}\n\nPLATFORMS\n  ruby\n\nDEPENDENCIES\n\nBUNDLED WITH\n   2.5.0\n"
  end

  def with_answers(files, *resolutions, definition: nil)
    with_project do |root|
      files.each { |path, source| write "#{root}/#{path}", source }
      write "#{root}/Gemfile", "source 'https://rubygems.org'\n"
      write "#{root}/Gemfile.lock", lockfile
      definition ||= ArchSpec.define do
        component :models, in: 'app/models/**/*.rb'
        resolver :rubydex
      end
      found = index_of(*resolutions)
      with_gem_stubbed(lockfile: "#{root}/Gemfile.lock", index: -> { found }, seconds: 0.0) do
        yield ArchSpec::Analyzer.analyze(definition, root: root), definition, root
      end
    end
  end

  def with_gem_stubbed(lockfile: nil, index: nil, seconds: nil)
    singleton = ArchSpec::Rubydex.singleton_class
    Object.const_set(:Rubydex, Module.new { const_set(:VERSION, '0.0.0') }) unless Object.const_defined?(:Rubydex)
    singleton.define_method(:load_gem) { nil }
    singleton.define_method(:bundle!) do |root|
      lockfile || raise(ArchSpec::Error, "no Gemfile.lock at #{root}; reflect --rubydex indexes the locked bundle, never the workspace alone")
    end
    singleton.define_method(:index) { |_root| index.call } if index
    if seconds
      original = singleton.instance_method(:resolve)
      singleton.define_method(:resolve) do |graph, root:, cache_directory: nil|
        result = original.bind(self).call(graph, root: root, cache_directory: cache_directory)
        result[3] = seconds
        result
      end
    end
    yield
  ensure
    singleton.remove_method(:load_gem)
    singleton.remove_method(:bundle!)
    singleton.remove_method(:index) if index
    singleton.remove_method(:resolve) if seconds
  end

  def without_rubydex
    ArchSpec::Rubydex.singleton_class.define_method(:require) do |name|
      raise LoadError, name if name == 'rubydex'

      super(name)
    end
    yield
  ensure
    ArchSpec::Rubydex.singleton_class.remove_method(:require)
  end
end
