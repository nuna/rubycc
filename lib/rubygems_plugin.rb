# frozen_string_literal: true

# RubyGems auto-loads every installed gem's `rubygems_plugin.rb` at startup
# (Gem.load_plugins), so this file runs in the `gem install <native-ext-gem>`
# process before any extension is built. Its whole job is to decide whether the
# build should go through rubycc and, if so, to inject the environment that makes
# RubyGems' extension build route to rubycc's toolchain instead of gcc/make —
# without the user passing any flags (DESIGN 5.4, ROADMAP §6 B6).
#
# The decision:
#   * ENV["RUBYCC"] == "1"  -> force on;
#   * ENV["RUBYCC"] == "0"  -> force off;
#   * unset                 -> on only when neither `cc`, `gcc` nor `make` is on
#                              PATH (a toolchain-less host that needs rubycc).
#
# When off, the plugin must be inert — it is loaded on *every* `gem` command, so
# the disabled path does no work and touches no state. When on it rewrites four
# environment variables the RubyGems build inherits:
#   * MAKE       -> exe/rmake *launched through this Ruby*, which RubyGems runs as
#                   `$(MAKE)`; rmake builds the generated Makefile with rubycc
#                   always substituted for $(CC);
#   * PKG_CONFIG -> exe/rubycc-pkgconf, the pkg-config shim;
#   * RUBYLIB    <- gains this gem's lib/ so the extconf child can require rubycc;
#   * RUBYOPT    <- gains `-rrubycc/mkmf_shim` so the extconf child's mkmf issues
#                   its conftests through rubycc and writes a `CC = <rubycc>`
#                   Makefile.
# Every rewrite is idempotent: re-running install! adds no duplicate PATH/RUBYOPT
# entries and re-assigns the same MAKE/PKG_CONFIG values.
#
# `MAKE` names the interpreter explicitly (`<RbConfig.ruby> <path>/exe/rmake`)
# rather than the executable alone. rmake's shebang is `#!/usr/bin/env ruby`,
# which the kernel cannot resolve on an image without /usr/bin/env — the minimal
# environment DESIGN R5 targets, where every exec of it would fail with status
# 127 — and which would otherwise pick whichever `ruby` PATH happens to lead to
# rather than the one the gem is being installed into. RubyGems shellsplits
# `ENV["MAKE"]` (Gem::Ext::Builder.make), so a two-word value is the supported
# spelling; both words are quoted, since an installation path may contain a
# space.
#
# Everything that spelling needs — rbconfig and rubycc's own splitter — is
# required inside install!, not at the top of this file: the disabled path must
# load nothing, and this file is loaded by every `gem` command there is.
module Rubycc
  module GemPlugin
    # This file lives at lib/rubygems_plugin.rb, so __dir__ is the gem's lib/ and
    # the executables sit at ../exe relative to it.
    LIB_DIR     = __dir__
    RMAKE_EXE   = File.expand_path("../exe/rmake", __dir__)
    PKGCONF_EXE = File.expand_path("../exe/rubycc-pkgconf", __dir__)

    # The require the extconf child needs so mkmf's conftests route to rubycc.
    MKMF_SHIM_FEATURE = "rubycc/mkmf_shim"

    # The external programs whose absence (all three) turns rubycc on by default:
    # a host with no C compiler and no make is one that cannot build extensions
    # the conventional way, which is exactly where rubycc takes over.
    AUTO_ENABLE_ABSENT_TOOLS = %w[cc gcc make].freeze

    module_function

    # Whether the rubycc build path should be active for this process.
    def enabled?
      case ENV["RUBYCC"]
      when "1" then true
      when "0" then false
      else auto_enable?
      end
    end

    # The unset-RUBYCC default: on only when none of the conventional tools is
    # available, so a host that already has gcc/make is left completely alone.
    def auto_enable?
      AUTO_ENABLE_ABSENT_TOOLS.none? { |tool| on_path?(tool) }
    end

    # Inject the environment that makes the RubyGems extension build use rubycc.
    def install!
      ENV["MAKE"] = make_command
      # PKG_CONFIG stays a bare path: mkmf stats the value with find_executable0
      # before running it, so it has to be one file name. The mkmf shim puts the
      # interpreter in front of it when the command is actually spawned.
      ENV["PKG_CONFIG"] = PKGCONF_EXE
      prepend_path_entry("RUBYLIB", LIB_DIR)
      prepend_ruby_require(MKMF_SHIM_FEATURE)
    end

    # rmake as `$(MAKE)`: this very interpreter, then the script, each word
    # quoted so RubyGems' Shellwords.split (and rmake's own splitter, which sees
    # the value again through `$(MAKE)`) reads back the two paths intact.
    def make_command
      require "rbconfig"
      require_relative "rubycc/command_line"

      [RbConfig.ruby, RMAKE_EXE].map { |word| Rubycc::CommandLine.quote(word) }.join(" ")
    end

    # A PATH lookup that spawns nothing: scan the PATH directories for an
    # executable file of that name (the same resolution `command -v` performs).
    def on_path?(name)
      ENV["PATH"].to_s.split(File::PATH_SEPARATOR).any? do |dir|
        next false if dir.empty?

        candidate = File.join(dir, name)
        File.file?(candidate) && File.executable?(candidate)
      end
    end

    # Prepend +dir+ to a PATH-style environment variable (RUBYLIB) unless it is
    # already the leading entry — so the extconf child can require rubycc from
    # this gem's lib/.
    def prepend_path_entry(var, dir)
      entries = ENV[var].to_s.split(File::PATH_SEPARATOR)
      return if entries.first == dir

      ENV[var] = [dir, *entries].join(File::PATH_SEPARATOR)
    end

    # Add `-r<feature>` to RUBYOPT (at the front, so the shim loads before the
    # extconf script's own requires) unless it is already present.
    def prepend_ruby_require(feature)
      flag = "-r#{feature}"
      current = ENV["RUBYOPT"].to_s
      return if current.split(/\s+/).include?(flag)

      ENV["RUBYOPT"] = current.empty? ? flag : "#{flag} #{current}"
    end
  end
end

Rubycc::GemPlugin.install! if Rubycc::GemPlugin.enabled?
