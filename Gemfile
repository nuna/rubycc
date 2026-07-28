# frozen_string_literal: true

source "https://rubygems.org"

gemspec

group :development do
  gem "rake"
  gem "minitest"
  # fiddle moved from a default gem to a bundled gem in Ruby 4.0.0, so under
  # Bundler `require "fiddle"` raises LoadError unless it is declared here.
  # Only test/ dlopen's generated .so files with it to exercise them at
  # runtime; lib/ never requires fiddle, so it is not a gemspec runtime
  # dependency.
  gem "fiddle"
end
