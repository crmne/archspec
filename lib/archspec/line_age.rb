# frozen_string_literal: true

require 'date'

module ArchSpec
  # When a line last changed, asked of git once per witness file and remembered
  # for the run. Only rules that carry a date ask, so an undated check never
  # pays for blame. A missing git, a directory that is not a repository, or a
  # line not yet committed all answer +:unknown+, and the first such cause is
  # kept so the run can say it once.
  class LineAge
    UNCOMMITTED = /\A0+\z/

    attr_reader :note

    def initialize(root)
      @root = root
      @files = {}
      @note = nil
    end

    def verdict(path, line, date)
      committed = committed_on(path, line)
      return :unknown unless committed

      committed < date ? :before : :after
    end

    BOUNDARY = :boundary

    private

    def committed_on(path, line)
      dates = @files.fetch(path) { @files[path] = blame(path) }
      return unless dates

      committed = dates[line]
      return unknown('the history is shallow at the witness line') if committed == BOUNDARY

      committed || unknown('the witness line is not committed')
    end

    # Git marks a root commit as a boundary too; only a shallow clone's
    # boundary hides history, so the date of a true root stands.
    def shallow?
      return @shallow if defined?(@shallow)

      answer = IO.popen(['git', '-C', @root, 'rev-parse', '--is-shallow-repository'], err: File::NULL, &:read)
      @shallow = $?.success? && answer.to_s.strip == 'true'
    rescue SystemCallError
      @shallow = false
    end

    # Porcelain output is read as bytes: author names are whatever encoding the
    # committer used, and a C locale would otherwise refuse the first accented one.
    def blame(path)
      output = IO.popen(['git', '-C', @root, 'blame', '--porcelain', '--', path],
                        err: File::NULL, binmode: true, &:read)
      return unknown('git could not read the history of this tree') unless $?.success?

      parse(output.force_encoding(Encoding::UTF_8).scrub)
    rescue SystemCallError
      unknown('git is not installed')
    end

    # A commit git marks as a boundary is the edge of a shallow clone: the line
    # is older than the history, and its date is the clone's, not the line's.
    def parse(output)
      dates = {}
      times = {}
      commit = nil
      line = nil
      output.each_line do |text|
        if (header = text.match(/\A([0-9a-f]{40}) \d+ (\d+)(?: \d+)?$/))
          commit = header[1]
          line = header[2].to_i
          dates[line] = commit.match?(UNCOMMITTED) ? nil : times[commit]
        elsif (stamp = text.match(/\Aauthor-time (\d+)$/))
          times[commit] = Time.at(stamp[1].to_i).utc.to_date unless times[commit] == BOUNDARY
          dates[line] = times[commit] unless commit.match?(UNCOMMITTED)
        elsif text.start_with?('boundary') && shallow?
          times[commit] = BOUNDARY
          dates[line] = BOUNDARY
        end
      end
      dates
    end

    def unknown(cause)
      @note ||= cause
      nil
    end
  end
end
