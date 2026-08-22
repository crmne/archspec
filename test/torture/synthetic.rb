# frozen_string_literal: true

require 'fileutils'

# Writes the shape that hung the cycle rule in issue #3: a modular monolith
# of 879 files across 26 packs where every pack may use every other and does,
# so the component graph is one strongly connected component and the only
# diagnostic is the cycle. The files are
# generated from a fixed seed and the tree is the same on every run, which
# is what makes a time ceiling over it meaningful.
module TortureSynthetic
  PACKS = 26
  FILES = 879
  REACH = 3
  SHAPE = "synthetic-#{PACKS}x#{FILES}-v1".freeze

  module_function

  def write(root)
    names = Array.new(PACKS) { |index| "pack#{index.to_s.rjust(2, '0')}" }
    FILES.times do |number|
      pack = names[number % PACKS]
      ordinal = number / PACKS
      targets = (1..REACH).map { |step| names[(number + step * 7) % PACKS] }
      path = File.join(root, 'packs', pack, 'app', 'models', pack, "record#{ordinal}.rb")
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, source(pack, ordinal, targets))
    end
    File.write(File.join(root, 'Archspec.rb'), archspec)
    root
  end

  def source(pack, ordinal, targets)
    references = targets.each_with_index.map do |target, index|
      "    #{target.capitalize}::Record#{ordinal.zero? ? 1 : 0}.new.step#{index}"
    end
    <<~RUBY
      # frozen_string_literal: true

      module #{pack.capitalize}
        class Record#{ordinal}
          def run
      #{references.join("\n")}
          end

          def step0 = self
          def step1 = self
          def step2 = self
        end
      end
    RUBY
  end

  def archspec
    <<~RUBY
      # frozen_string_literal: true

      packs = each_directory('packs/*').to_h { |name, path| [name.to_sym, "\#{path}/app/**/*.rb"] }
      allow = packs.keys.to_h { |name| [name, packs.keys - [name]] }
      architecture :modular_monolith, components: packs, allow: allow
    RUBY
  end
end
