# frozen_string_literal: true

require 'json'
require 'stringio'
require_relative 'test_helper'

class ExplainTest < ArchSpecTest
  def test_explain_names_a_fresh_analysis_when_no_snapshot_was_taken
    with_shop do |root|
      out = explain(root, 'app/models/user.rb')
      assert_match(/\Aread from: a fresh analysis of the working tree, because no snapshot has been taken/, out)
    end
  end

  def test_explain_reads_the_snapshot_when_it_is_this_tree
    with_shop do |root|
      archspec(root, 'snapshot')
      out = explain(root, 'app/models/user.rb')
      assert_match(/\Aread from: the snapshot\n/, out)
      assert_match(/incoming facts:/, out)
    end
  end

  def test_explain_analyses_again_when_a_file_changed_since_the_snapshot
    with_shop do |root|
      archspec(root, 'snapshot')
      write "#{root}/app/models/user.rb", "class User\n  def renamed; end\nend\n"
      out = explain(root, 'app/models/user.rb')
      assert_match(/a fresh analysis of the working tree, because files the snapshot read have changed on disk/, out)
    end
  end

  def test_explain_analyses_again_when_a_file_was_added_since_the_snapshot
    with_shop do |root|
      archspec(root, 'snapshot')
      write "#{root}/app/models/session.rb", "class Session; end\n"
      out = explain(root, 'app/models/user.rb')
      assert_match(/because files have been added or removed since the snapshot/, out)
    end
  end

  def test_explain_declines_a_snapshot_taken_under_other_patterns
    with_shop do |root|
      archspec(root, 'snapshot')
      write "#{root}/Archspec.rb", "#{shop_definition}ignore 'lib/**'\n"
      out = explain(root, 'app/models/user.rb')
      assert_match(/because the source or ignore patterns changed since the snapshot was taken/, out)
    end
  end

  def test_explain_lists_incoming_edges_by_kind_and_source_component
    with_shop do |root|
      out = explain(root, 'app/models/user.rb')
      assert_match(%r{incoming facts:\n    references:\n\s+app/services/create_user.rb:3:5 │ CreateUser \(services\)}, out)
    end
  end

  def test_explain_marks_outgoing_edges_with_producer_and_determination
    with_shop do |root|
      write "#{root}/archspec_facts/rails.yml", {
        'format' => 1, 'producer' => 'archspec-reflect', 'producer_version' => '1.0.1', 'commit' => nil,
        'dirty' => false, 'generated_methods' => [], 'misses' => {},
        'references' => [{ 'owner' => 'User', 'file' => 'app/models/user.rb', 'line' => 1, 'target' => 'Session',
                           'macro' => 'belongs_to', 'name' => 'session' }]
      }.to_yaml
      write "#{root}/app/models/session.rb", "class Session; end\n"
      out = explain(root, 'app/models/user.rb')
      assert_match(/references Session \(facts, from archspec-reflect\)/, out)
      assert_match(/references CreateUser \(lexical\)/, out)
    end
  end

  def test_explain_prints_the_census_rows_for_the_file
    with_shop do |root|
      write "#{root}/app/models/user.rb", "class User < ApplicationRecord\n  send(:x)\n  CreateUser\nend\n"
      out = explain(root, 'app/models/user.rb')
      assert_match(/could not see:\n    unresolved references: ApplicationRecord\n    dynamic feature send at line 2/, out)
    end
  end

  def test_explain_prints_rules_and_findings_with_reason_and_action
    with_shop do |root|
      write "#{root}/app/models/user.rb", "class User\n  def go\n    UsersController\n  end\nend\n"
      out = explain(root, 'app/models/user.rb')
      assert_match(/rules:\n    dependencies.forbid -- models stay off the request/, out)
      assert_match(/findings:\n    \[dependencies.forbid\] models must not depend on controllers \(3:5\)/, out)
      assert_match(/reason: models stay off the request/, out)
      assert_match(/confidence: high/, out)
    end
  end

  def test_blast_radius_names_what_would_start_failing
    with_project do |root|
      write "#{root}/Archspec.rb", <<~RUBY
        component :billing, in: 'app/billing/**/*.rb'
        billing.public_api 'app/billing/api.rb'
      RUBY
      write "#{root}/app/billing/api.rb", "module Billing; class Api; end; end\n"
      write "#{root}/app/billing/secret.rb", "module Billing; class Secret; end; end\n"
      write "#{root}/app/billing/internal.rb", "module Billing\n  class Internal\n    Secret\n  end\nend\n"
      out = explain(root, 'app/billing/internal.rb')
      assert_match(/findings: \(none\)/, out)
      assert_match(/would start failing:\n\s+\[dependencies.privacy\] Billing::Secret is private to billing/, out)
    end
  end

  def test_blast_radius_names_what_would_stop_being_checked
    with_project do |root|
      write "#{root}/Archspec.rb", <<~RUBY
        component :commands, in: 'app/commands/**/*.rb'
        commands.must_implement :call
      RUBY
      write "#{root}/app/commands/import.rb", "class Import\n  def run; end\nend\n"
      out = explain(root, 'app/commands/import.rb')
      assert_match(/would stop being checked:\n\s+\[protocol.must_implement\]/, out)
    end
  end

  def test_blast_radius_lists_a_rule_it_could_not_recompute
    with_project do |root|
      write "#{root}/Archspec.rb", <<~RUBY
        component :models, in: 'app/models/**/*.rb'
        class Flaky
          def id = 'custom.flaky'
          def evaluate(graph)
            raise 'needs the component' if graph.components[:models].files.empty?
            []
          end
        end
        rule Flaky.new
      RUBY
      write "#{root}/app/models/user.rb", "class User; end\n"
      out = explain(root, 'app/models/user.rb')
      assert_match(/not computed: custom.flaky, needs the component/, out)
    end
  end

  def test_explain_constant_prints_resolved_ancestry_with_an_unresolved_link
    with_project do |root|
      write "#{root}/Archspec.rb", "component :models, in: 'app/models/**/*.rb'\n"
      write "#{root}/app/models/base.rb", "class Base < ApplicationRecord\n  include Trackable\nend\n"
      write "#{root}/app/models/trackable.rb", "module Trackable; end\n"
      write "#{root}/app/models/user.rb", "class User < Base; end\n"
      out = explain(root, 'User')
      assert_match(/ancestry:\n      superclass Base \(Base, lexical\)\n        superclass ApplicationRecord \(unresolved\)\n        include Trackable \(Trackable, lexical\)/, out)
    end
  end

  def test_explain_component_prints_members_public_face_and_fans
    with_shop do |root|
      write "#{root}/Archspec.rb", "#{shop_definition}models.public_api 'app/models/user.rb'\n"
      out = explain(root, 'models')
      assert_match(/\Aread from: a fresh analysis/, out)
      assert_match(/files: 1\n    app\/models\/user.rb/, out)
      assert_match(/constants: User/, out)
      assert_match(/public face:\n    files app\/models\/user.rb\n    constants User/, out)
      assert_match(/fan-in:\n    services: 1/, out)
      assert_match(/fan-out:\n    services: 1/, out)
      assert_match(/rules:\n    dependencies.forbid/, out)
    end
  end

  def test_explain_json_carries_the_same_sections
    with_shop do |root|
      document = JSON.parse(explain(root, 'app/models/user.rb', '--format', 'json'))
      assert_equal 'analysis', document.dig('origin', 'source')
      assert_equal 'file', document.dig('subject', 'kind')
      assert_equal ['services'], document.fetch('incoming').first.fetch('components')
      assert_equal %w[appearing not_computed vanishing], document.fetch('blast_radius').keys.sort
      assert_equal 'dependencies.forbid', document.fetch('rules').first.fetch('id')
      assert document.fetch('census').key?('unresolved_references')
    end
  end

  def test_explain_refuses_an_unknown_format
    with_shop do |root|
      error = StringIO.new
      status = Dir.chdir(root) do
        ArchSpec::CLI.run(['explain', 'app/models/user.rb', '--format', 'xml'], output: StringIO.new, error: error)
      end
      assert_equal ArchSpec::CLI::USAGE_ERROR_STATUS, status
      assert_match(/unknown format/, error.string)
    end
  end

  private

  def shop_definition
    <<~RUBY
      component :models, in: 'app/models/**/*.rb'
      component :services, in: 'app/services/**/*.rb'
      component :controllers, in: 'app/controllers/**/*.rb'
      models.cannot_use :controllers, because: 'models stay off the request'
    RUBY
  end

  def with_shop
    with_project do |root|
      write "#{root}/Archspec.rb", shop_definition
      write "#{root}/app/models/user.rb", "class User\n  CreateUser\nend\n"
      write "#{root}/app/services/create_user.rb", "class CreateUser\n  def call\n    User\n  end\nend\n"
      write "#{root}/app/controllers/users_controller.rb", "class UsersController; end\n"
      yield root
    end
  end

  def archspec(root, *argv)
    output = StringIO.new
    error = StringIO.new
    status = Dir.chdir(root) { ArchSpec::CLI.run(argv, output: output, error: error) }
    assert_equal 0, status, error.string + output.string
    output.string
  end

  def explain(root, *argv)
    archspec(root, 'explain', *argv)
  end

  def test_explain_shows_every_reopening_of_a_constant
    with_shop do |root|
      write "#{root}/app/models/twice.rb", "module Twice\n  def a; end\nend\n"
      write "#{root}/app/models/twice_again.rb", "module Twice\n  def b; end\nend\n"

      out = explain(root, 'Twice')

      assert_equal 2, out.scan(/^  file: /).size
      assert_match(%r{file: app/models/twice\.rb:1}, out)
      assert_match(%r{file: app/models/twice_again\.rb:1}, out)
    end
  end
end
