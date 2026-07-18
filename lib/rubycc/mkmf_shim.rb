# frozen_string_literal: true

require "rbconfig"

# The mkmf integration shim: requiring this file (before `require "mkmf"`)
# reroutes every conftest command mkmf issues — compile, link, preprocess — to
# rubycc, without patching mkmf itself. mkmf builds its probe commands out of a
# handful of RbConfig keys (`$(CC)`, `$(LDSHARED)`, `$(CPP)`, `$(PKG_CONFIG)`)
# and runs them through `system(env, *command)`, so replacing just those keys
# with the rubycc executables makes `have_header`, `have_func`, `have_library`,
# `try_compile`/`try_link`/`try_run`, `check_sizeof` and the rest resolve
# against rubycc's own compiler and linker. mkmf.log stays untouched — mkmf
# writes it — so the log's format (the "checked program was:" sections, the
# echoed command lines) is the genuine article.
#
# Two RbConfig hashes are rewritten: CONFIG, which mkmf merges into every
# conftest command's expansion context, and MAKEFILE_CONFIG, which the generated
# Makefile's `CC = …`/`LDSHARED = …` assignments are drawn from — so both the
# probe phase and the eventual build route through rubycc. The change is
# in-process only (no file on disk is modified) and idempotent: requiring the
# shim twice is a no-op.
#
# The rubycc executables shebang-launch `require "rubycc"`, which needs the
# repository's `lib/` on the load path when rubycc is run from a checkout rather
# than an installed gem. The shim prepends that directory to `RUBYLIB` so the
# value propagates to the child processes mkmf spawns.
module Rubycc
  module MkmfShim
    # The repository's lib/ directory (this file lives at lib/rubycc/mkmf_shim.rb)
    # and the gcc-compatible executables that stand in for the external toolchain.
    LIB_DIR     = File.expand_path("..", __dir__)
    RUBYCC_EXE  = File.expand_path("../../exe/rubycc", __dir__)
    PKGCONF_EXE = File.expand_path("../../exe/rubycc-pkgconf", __dir__)

    # The RbConfig keys rewritten to point at rubycc. Each maps to the command
    # string mkmf embeds verbatim when it expands `$(CC)` and friends: a single
    # shell-metacharacter-free executable path (plus, for the compound tools, the
    # driver's own mode flag) so mkmf's `system(env, *command)` execs it directly.
    def self.replacements
      {
        "CC"        => RUBYCC_EXE,
        "LDSHARED"  => "#{RUBYCC_EXE} -shared",
        "CPP"       => "#{RUBYCC_EXE} -E",
        "PKG_CONFIG" => PKGCONF_EXE
      }
    end

    # Rewrites the toolchain keys in both RbConfig hashes and prepends the
    # repository lib/ to RUBYLIB. Idempotent: the RUBYLIB entry is added only
    # once, and re-assigning the same command strings is harmless.
    def self.install!
      configs = [RbConfig::CONFIG]
      configs << RbConfig::MAKEFILE_CONFIG if defined?(RbConfig::MAKEFILE_CONFIG)

      replacements.each do |key, value|
        configs.each do |config|
          # PKG_CONFIG is only meaningful if the host build already knew a
          # pkg-config; leave an absent key absent so mkmf's own "no pkg-config"
          # path is preserved, but override a present one (even the empty string
          # RbConfig ships when none was found) to point at rubycc-pkgconf.
          next if key == "PKG_CONFIG" && !config.key?(key)

          config[key] = value
        end
      end

      prepend_rubylib!
    end

    # Puts the repository lib/ at the front of RUBYLIB so a rubycc executable
    # spawned by mkmf can `require "rubycc"` from a source checkout. Skips the
    # work when the directory is already the leading entry.
    def self.prepend_rubylib!
      current = ENV["RUBYLIB"]
      entries = current.to_s.split(File::PATH_SEPARATOR)
      return if entries.first == LIB_DIR

      ENV["RUBYLIB"] = [LIB_DIR, *current&.split(File::PATH_SEPARATOR)].join(File::PATH_SEPARATOR)
    end
  end
end

Rubycc::MkmfShim.install!
