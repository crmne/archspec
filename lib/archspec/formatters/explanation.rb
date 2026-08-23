# frozen_string_literal: true

module ArchSpec
  module Formatters
    # Renders <tt>archspec explain</tt>: where the answer was read from, why a
    # file, constant or component belongs to its components, what reaches it
    # and what it reaches, what the rules say about it, and what would change
    # if its file left every component, in the same visual language as the
    # check output. The Explanation is built before printing; nothing here
    # reads the graph.
    module Explanation
      module_function

      def print(output = $stdout, explanation:)
        style = Style.new(output)
        print_origin(output, style, explanation.origin)
        output.puts

        if explanation.file?
          explain_file(output, style, explanation)
        elsif explanation.constant?
          explain_constant(output, style, explanation)
        else
          explain_component(output, style, explanation)
        end
      end

      def print_origin(output, style, origin)
        if origin.snapshot?
          at = origin.commit ? " at #{origin.commit[0, 12]}#{' (dirty)' if origin.dirty}" : ''
          output.puts "#{style.note('read from:')} the snapshot#{at}"
        else
          output.puts "#{style.note('read from:')} a fresh analysis of the working tree, because #{origin.cause}"
        end
      end

      def explain_file(output, style, explanation)
        output.puts style.bold(explanation.name)
        output.puts
        output.puts "  #{style.note('defined constants:')} #{explanation.defined_constants.join(', ')}"
        print_parse_errors(output, style, explanation.parse_errors)
        print_component_reasons(output, style, explanation.components)
        print_component_exclusions(output, style, explanation.exclusions)
        print_suppressions(output, style, explanation.suppressions)
        print_subject_sections(output, style, explanation)
      end

      def explain_constant(output, style, explanation)
        explanation.constants.each_with_index do |entry, index|
          output.puts unless index.zero?
          output.puts style.bold(entry[:name])
          output.puts
          output.puts "  #{style.note('kind:')} #{entry[:kind]}"
          if entry[:external]
            output.puts "  #{style.note('external:')} #{entry[:external]} (no file, never a member)"
          else
            output.puts "  #{style.note('file:')} #{entry[:path]}:#{entry[:line]}"
          end
          print_component_reasons(output, style, entry[:components])
          output.puts "  #{style.note('superclass:')} #{entry[:superclass] || '(none)'}"
          output.puts "  #{style.note('instance methods:')} #{entry[:instance_methods].join(', ')}"
          output.puts "  #{style.note('class methods:')} #{entry[:class_methods].join(', ')}"
          print_ancestry(output, style, entry[:ancestry])
        end
        print_subject_sections(output, style, explanation)
      end

      def explain_component(output, style, explanation)
        output.puts style.bold(explanation.name)
        output.puts
        members = explanation.members
        output.puts "  #{style.note('files:')} #{members[:files].empty? ? '(none)' : members[:files].size}"
        members[:files].each { |file| output.puts "    #{file}" }
        output.puts "  #{style.note('constants:')} #{members[:constants].empty? ? '(none)' : members[:constants].join(', ')}"
        output.puts "  #{style.note('externals:')} #{members[:externals].join(', ')} (owned by name, never members)" if members[:externals].any?
        print_public_face(output, style, explanation.public_face)
        print_fans(output, style, 'fan-in:', explanation.fan_in)
        print_fans(output, style, 'fan-out:', explanation.fan_out)
        print_rules(output, style, explanation.rules)
        print_diagnostics(output, style, explanation.diagnostics)
      end

      def print_subject_sections(output, style, explanation)
        print_incoming(output, style, explanation.incoming)
        print_outgoing(output, style, explanation.outgoing)
        print_census(output, style, explanation.census)
        print_rules(output, style, explanation.rules)
        print_diagnostics(output, style, explanation.diagnostics)
        print_blast_radius(output, style, explanation.blast_radius)
      end

      def print_component_reasons(output, style, assignments)
        if assignments.empty?
          output.puts "  #{style.note('components:')} (none)"
          return
        end

        output.puts "  #{style.note('components:')}"
        assignments.sort_by { |name, _reasons| name.to_s }.each do |name, reasons|
          output.puts "    #{name}: #{reasons.empty? ? '(no recorded reason)' : reasons.join('; ')}"
        end
      end

      def print_component_exclusions(output, style, exclusions)
        return if exclusions.empty?

        output.puts "  #{style.note('excluded from:')}"
        exclusions.sort_by { |name, _reasons| name.to_s }.each do |name, reasons|
          output.puts "    #{name}: #{reasons.join('; ')}"
        end
      end

      def print_suppressions(output, style, suppressions)
        return if suppressions.empty?

        output.puts "  #{style.note('suppressions:')}"
        in_gutters(suppressions.map { |suppression| line_range(suppression) }) do |gutter, index|
          suppression = suppressions[index]
          rule = suppression.rule || '*'
          reason = suppression.reason ? " -- #{suppression.reason}" : ''
          output.puts "    #{style.faint(gutter)} #{rule}#{reason}"
        end
      end

      def print_parse_errors(output, style, parse_errors)
        return if parse_errors.empty?

        output.puts "  #{style.note('parse errors:')}"
        locations = parse_errors.map { |error| "#{error.location.line}:#{error.location.column}" }
        in_gutters(locations) do |gutter, index|
          output.puts "    #{style.faint(gutter)} #{parse_errors[index].message}"
        end
      end

      def print_ancestry(output, style, links)
        if links.empty?
          output.puts "  #{style.note('ancestry:')} (none)"
          return
        end

        output.puts "  #{style.note('ancestry:')}"
        links.each do |link|
          indent = '  ' * link.depth
          resolved = link.resolution == :unresolved ? 'unresolved' : "#{link.resolved}, #{link.resolution}"
          origin = link.origin == 'parser' ? '' : ", from #{link.origin}"
          output.puts "    #{indent}#{link.kind} #{link.name} (#{resolved}#{origin})"
        end
      end

      def print_incoming(output, style, incoming)
        if incoming.empty?
          output.puts "  #{style.note('incoming facts:')} (none)"
          return
        end

        output.puts "  #{style.note('incoming facts:')}"
        incoming.group_by(&:kind).sort.each do |kind, edges|
          output.puts "    #{kind}:"
          locations = edges.map { |edge| "#{edge.path}:#{edge.line}:#{edge.column}" }
          in_gutters(locations) do |gutter, index|
            edge = edges[index]
            components = edge.components.empty? ? 'no component' : edge.components.join(', ')
            output.puts "      #{style.faint(gutter)} #{edge.from} (#{components})"
          end
        end
      end

      def print_outgoing(output, style, outgoing)
        if outgoing.empty?
          output.puts "  #{style.note('outgoing facts:')} (none)"
          return
        end

        output.puts "  #{style.note('outgoing facts:')}"
        locations = outgoing.map { |edge| "#{edge.line}:#{edge.column}" }
        in_gutters(locations) do |gutter, index|
          edge = outgoing[index]
          output.puts "    #{style.faint(gutter)} #{edge.kind} #{edge.target}#{provenance(edge)}"
        end
      end

      def provenance(edge)
        parts = []
        parts << edge.determination if edge.determination
        parts << "from #{edge.producer}" unless edge.producer == 'parser'
        parts.empty? ? '' : " (#{parts.join(', ')})"
      end

      def print_census(output, style, census)
        rows = []
        unless census[:unresolved_references].empty?
          rows << "unresolved references: #{census[:unresolved_references].join(', ')}"
        end
        census[:dynamic_features].each do |feature|
          rows << "dynamic feature #{feature[:feature]} at line #{feature[:line]}"
        end
        rows << "calls on receivers of unknown kind: #{census[:unknown_receiver_calls]}" if census[:unknown_receiver_calls].positive?

        if rows.empty?
          output.puts "  #{style.note('could not see:')} nothing"
          return
        end

        output.puts "  #{style.note('could not see:')}"
        rows.each { |row| output.puts "    #{row}" }
      end

      def print_rules(output, style, rules)
        if rules.empty?
          output.puts "  #{style.note('rules:')} (none name its components)"
          return
        end

        output.puts "  #{style.note('rules:')}"
        rules.each do |rule|
          reason = rule.reason ? " -- #{rule.reason}" : ''
          output.puts "    #{rule.id}#{reason}"
        end
      end

      def print_diagnostics(output, style, diagnostics)
        if diagnostics.empty?
          output.puts "  #{style.note('findings:')} (none)"
          return
        end

        output.puts "  #{style.note('findings:')}"
        diagnostics.each { |diagnostic| print_finding(output, style, diagnostic, '    ') }
      end

      def print_finding(output, style, diagnostic, indent)
        location = diagnostic.location
        output.puts "#{indent}#{style.severity("[#{diagnostic.rule}]")} #{diagnostic.message} " \
                    "#{style.faint("(#{location.line}:#{location.column})")}"
        output.puts "#{indent}  #{style.note('evidence:')} #{diagnostic.evidence}" unless diagnostic.evidence.to_s.empty?
        output.puts "#{indent}  #{style.note('reason:')} #{diagnostic.reason}" if diagnostic.reason
        output.puts "#{indent}  #{style.note('action:')} #{diagnostic.suggested_action}" if diagnostic.suggested_action
        output.puts "#{indent}  #{style.note('since:')} #{diagnostic.since}" if diagnostic.since
        detail = [diagnostic.confidence, diagnostic.caveat].compact.join(', ')
        output.puts "#{indent}  #{style.note('confidence:')} #{detail}"
      end

      def print_blast_radius(output, style, radius)
        if radius.appearing.empty? && radius.vanishing.empty? && radius.not_computed.empty?
          output.puts "  #{style.note('if this left every component:')} no rule's verdict changes"
          return
        end

        output.puts "  #{style.note('if this left every component:')}"
        print_radius_bucket(output, style, 'would start failing:', radius.appearing)
        print_radius_bucket(output, style, 'would stop being checked:', radius.vanishing)
        radius.not_computed.each do |entry|
          output.puts "    #{style.note('not computed:')} #{entry[:rule]}, #{entry[:cause]}"
        end
      end

      def print_radius_bucket(output, style, label, diagnostics)
        return if diagnostics.empty?

        output.puts "    #{style.note(label)}"
        diagnostics.each { |diagnostic| print_finding(output, style, diagnostic, '      ') }
      end

      def print_public_face(output, style, face)
        if face[:constants].empty? && face[:files].empty?
          output.puts "  #{style.note('public face:')} (none declared)"
          return
        end

        output.puts "  #{style.note('public face:')}"
        face[:files].each { |pattern| output.puts "    files #{pattern}" }
        output.puts "    constants #{face[:constants].join(', ')}" unless face[:constants].empty?
      end

      def print_fans(output, style, label, fans)
        if fans.empty?
          output.puts "  #{style.note(label)} (none)"
          return
        end

        output.puts "  #{style.note(label)}"
        fans.each { |component, count| output.puts "    #{component}: #{count}" }
      end

      # Yields each label right-justified to the widest one, with the frame
      # gutter bar appended, so columns line up like the check output.
      def in_gutters(labels)
        width = labels.map(&:length).max

        labels.each_with_index do |label, index|
          yield "#{label.rjust(width)} │", index
        end
      end

      def line_range(suppression)
        if suppression.end_line == Float::INFINITY
          "#{suppression.start_line}-EOF"
        elsif suppression.start_line == suppression.end_line
          suppression.start_line.to_s
        else
          "#{suppression.start_line}-#{suppression.end_line}"
        end
      end
    end
  end
end
