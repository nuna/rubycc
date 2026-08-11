# frozen_string_literal: true

require "rbconfig"

# HostTarget is the single translation from MRI's CPU spelling to a rubycc
# backend name. Tests that compile an object for the machine running the test
# process must use this value; Compiler#compile's historical default is an
# x86_64 compatibility default and is not a host probe.
module HostTarget
  module_function

  def name
    case RbConfig::CONFIG["host_cpu"].to_s.downcase
    when "x86_64", "amd64" then "x86_64"
    when "aarch64", "arm64" then "aarch64"
    else RbConfig::CONFIG["host_cpu"].to_s
    end
  end
end
