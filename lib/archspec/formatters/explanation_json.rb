# frozen_string_literal: true

require 'json'

module ArchSpec
  module Formatters
    # The explanation as one object with the same sections the text form
    # prints, for an agent that asks the reverse questions before it edits.
    module ExplanationJSON
      module_function

      def print(output = $stdout, explanation:)
        output.puts ::JSON.pretty_generate(explanation.to_h)
      end
    end
  end
end
