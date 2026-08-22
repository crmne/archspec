# frozen_string_literal: true

require 'date'

module ArchSpec
  # When a line last changed, asked of git one line at a time and remembered
  # for the run. Only rules that carry a date ask, so an undated check never
  # pays for blame. A missing git, a directory that is not a repository, or a
  # line not yet committed all answer +:unknown+, and the first such cause is
  # kept so the run can say it once.
  class LineAge
    UNCOMMITTED = /\A0+\z/

    attr_reader :note

    def initialize(root)
      @root = root
      @dates = {}
      @note = nil
    end

    def verdict(path, line, date)
      committed = committed_on(path, line)
      return :unknown unless committed

      committed < date ? :before : :after
    end

    private

    def committed_on(path, line)
      @dates.fetch([path, line]) { @dates[[path, line]] = blame(path, line) }
    end

    def blame(path, line)
      output = IO.popen(['git', '-C', @root, 'blame', '-L', "#{line},#{line}", '--porcelain', '--', path],
                        err: File::NULL, &:read)
      return unknown('git could not read the history of this tree') unless $?.success?

      commit = output.lines.first.to_s.split.first.to_s
      return unknown('the witness line is not committed') if commit.empty? || commit.match?(UNCOMMITTED)

      seconds = output[/^author-time (\d+)$/, 1]
      return unknown('git blame carried no date') unless seconds

      Time.at(seconds.to_i).utc.to_date
    rescue SystemCallError
      unknown('git is not installed')
    end

    def unknown(cause)
      @note ||= cause
      nil
    end
  end
end
