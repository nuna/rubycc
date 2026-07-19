# frozen_string_literal: true

require_relative "doctor/gemfile"
require_relative "doctor/verified_gems"
require_relative "doctor/fetcher"
require_relative "doctor/builder"
require_relative "doctor/cli"

module Rubycc
  # rubycc doctor: the adoption-check command (ROADMAP §6 "M3 完了後のツール").
  # Given an application's Gemfile.lock/Gemfile it reports, per gem, whether
  # rubycc can build its C extension — first from the shipped build-verified
  # database, then by an on-the-spot build for anything unverified.
  module Doctor
  end
end
