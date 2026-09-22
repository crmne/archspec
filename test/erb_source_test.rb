# frozen_string_literal: true

require 'test_helper'
require 'minitest/mock'

class ErbSourceTest < ArchSpecTest
  def test_ruby_is_extracted_and_parsed_once_eagerly
    with_project do |root|
      path = "#{root}/source.erb"
      template = "<%# note %>\n<%= User.count # Ruby comment\n%>\n"
      write path, template
      extract = Herb.method(:extract_ruby)
      parse = Prism.method(:parse)
      extractions = 0
      parses = 0
      track_extraction = lambda do |*args, **options|
        extractions += 1
        assert_equal [template], args
        assert_empty options
        extract.call(*args, **options)
      end
      track_parse = lambda do |*args, **options|
        parses += 1
        parse.call(*args, **options)
      end

      Herb.stub(:extract_ruby, track_extraction) do
        Prism.stub(:parse, track_parse) do
          source = ArchSpec::Sources::Erb.new(path)
          assert_equal [1, 1], [extractions, parses]
          write path, '<div>'
          root_node = source.prism
          assert_instance_of Prism::ProgramNode, root_node
          assert_equal ['User.count'], root_node.statements.body.map(&:slice)

          2.times do
            assert_equal ['# Ruby comment', 'note'], source.comments.map { |comment| comment.text.strip }.sort
            assert_same root_node, source.prism
          end
          assert_equal [1, 1], [extractions, parses]
        end
      end
    end
  end

  def test_extensions_and_index_paths
    assert_equal %w[.erb], ArchSpec::Sources::Erb.extensions
    refute ArchSpec::Sources::Erb.rubydex_indexable?
  end

  def test_empty_and_html_only_templates_yield_one_empty_program
    with_project do |root|
      path = "#{root}/source.erb"
      ['', '<h1>Users</h1>'].each do |template|
        write path, template
        source = ArchSpec::Sources::Erb.new(path)

        assert_instance_of Prism::ProgramNode, source.prism
        assert_empty source.prism.statements.body
      end
    end
  end

  def test_lexer_comments_preserve_byte_positions_and_adjacent_expressions
    with_project do |root|
      path = "#{root}/source.erb"
      template = "\u00e9<%# \u00e9 -%><%= First.count %><%# note %><%= Second.count %>\r\n"
      write path, template
      source = ArchSpec::Sources::Erb.new(path)
      statements = source.prism.statements.body

      assert_equal %w[First.count Second.count], statements.map(&:slice)
      assert_equal [template.b.index('First'), template.b.index('Second')],
                   statements.map { |node| node.location.start_offset }
      assert_equal ["\u00e9", 'note'], source.comments.map { |comment| comment.text.strip }
      assert_equal [5, template.b.index(' note ')], source.comments.map(&:column)
      assert_empty source.parse_errors
    end
  end

  def test_escaped_erb_comment_openings_are_not_comments
    with_project do |root|
      path = "#{root}/source.erb"
      write path, '<%%# archspec:disable * %>'
      source = ArchSpec::Sources::Erb.new(path)

      assert_empty source.comments
      assert_empty source.prism.statements.body
    end
  end

  def test_unterminated_erb_comment_is_collected_without_a_ruby_syntax_error
    with_project do |root|
      path = "#{root}/source.erb"
      write path, "<%# first\narchspec:disable *"
      source = ArchSpec::Sources::Erb.new(path)

      assert_equal [['first', 1, 3], ['archspec:disable *', 2, 0]],
                   source.comments.map { |comment| [comment.text.strip, comment.line, comment.column] }
      assert_empty source.parse_errors
      assert_empty source.prism.statements.body
    end
  end

  def test_local_variables_are_shared_across_erb_tags
    with_project do |root|
      path = "#{root}/source.erb"
      write path, "<% user = User.new %>\n<%= user.count %>\n"
      source = ArchSpec::Sources::Erb.new(path)
      program = source.prism

      assert_equal [:user], program.locals
      assert_instance_of Prism::LocalVariableReadNode, program.statements.body.last.receiver
      assert_empty source.parse_errors
    end
  end

  def test_erb_comments_map_multiline_and_incomplete_fragments_to_template_positions
    with_project do |root|
      path = "#{root}/source.erb"
      write path, <<~ERB
          <%# note
        archspec:disable * %>
          <% # archspec:enable * %>
        <% if true # archspec:disable-next-line
          # archspec:disable-line *
        %>
        <% end %>
      ERB
      source = ArchSpec::Sources::Erb.new(path)

      assert_equal [
        ['note', 1, 5],
        ['archspec:disable *', 2, 0],
        ['# archspec:disable-next-line', 4, 11],
        ['# archspec:disable-line *', 5, 2]
      ], source.comments.sort_by { |comment| [comment.line, comment.column] }
               .map { |comment| [comment.text.strip, comment.line, comment.column] }
      assert_empty source.parse_errors
    end
  end

  def test_comment_only_templates_yield_an_empty_program
    with_project do |root|
      path = "#{root}/source.erb"
      write path, "<%# User.count %>\n<% # Ruby comment %>\n<%# ordinary prose %>\n"
      source = ArchSpec::Sources::Erb.new(path)

      assert_instance_of Prism::ProgramNode, source.prism
      assert_empty source.prism.statements.body
      assert_equal ['User.count', 'ordinary prose'],
                   source.comments.map { |comment| comment.text.strip }
    end
  end

  def test_erb_html_comments_and_ruby_strings_are_not_comments
    with_project do |root|
      path = "#{root}/source.erb"
      write path, <<~ERB
        <!-- archspec:disable * -->
        <%= '# archspec:disable *' %>
        <%= 'archspec:disable *' %>
      ERB

      assert_empty ArchSpec::Sources::Erb.new(path).comments
    end
  end

  def test_erb_yields_one_program_with_complete_control_flow
    with_project do |root|
      path = "#{root}/source.erb"
      write path, <<~ERB
        <section>
          <%= First.count %>
          <% if true %>
            <div><%= Second.count %></div>
          <% end %>
          <%= Third.count %>
        </section>
      ERB
      source = ArchSpec::Sources::Erb.new(path)
      write path, '<div>'
      assert_instance_of Prism::ProgramNode, source.prism
      statements = source.prism.statements.body
      assert_equal [Prism::CallNode, Prism::IfNode, Prism::CallNode], statements.map(&:class)
      assert_equal 'First.count', statements.first.slice
      assert_equal 'Second.count', statements[1].statements.body.first.slice
      assert_equal 'Third.count', statements.last.slice
      assert_empty source.parse_errors
    end
  end

  def test_html_structure_is_not_validated
    with_project do |root|
      erb_path = "#{root}/source.erb"
      write erb_path, "\n  <div>\n"
      assert_empty ArchSpec::Sources::Erb.new(erb_path).parse_errors
    end
  end

  def test_ruby_parse_errors_use_template_locations
    with_project do |root|
      erb_path = "#{root}/source.erb"
      write erb_path, "\n  <%= User.count) %>\n"
      errors = ArchSpec::Sources::Erb.new(erb_path).parse_errors

      refute_empty errors
      errors.each do |error|
        assert_equal ArchSpec::SourceLocation.new(erb_path, 2, 17, 2, 18), error.location
        assert_match(/unexpected '\)'/, error.message)
      end
    end
  end
end
