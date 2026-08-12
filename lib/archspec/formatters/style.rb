# frozen_string_literal: true

module ArchSpec
  module Formatters
    # ANSI styling for terminal output, shared by the formatters. Enabled only
    # when the output is a TTY and NO_COLOR is unset.
    class Style
      def initialize(output)
        @enabled = output.respond_to?(:tty?) && output.tty? && ENV['NO_COLOR'].to_s.empty?
      end

      def bold(text)
        paint(text, '1')
      end

      def severity(text)
        paint(text, '1;31')
      end

      def marker(text)
        paint(text, '1;31')
      end

      def note(text)
        paint(text, '1;36')
      end

      def faint(text)
        paint(text, '2')
      end

      private

      def paint(text, code)
        @enabled ? "\e[#{code}m#{text}\e[0m" : text
      end
    end
  end
end
