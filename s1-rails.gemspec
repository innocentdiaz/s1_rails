# frozen_string_literal: true

require_relative "lib/s1/rails_version"

Gem::Specification.new do |spec|
  spec.name = "s1-rails"
  spec.version = S1::RAILS_VERSION
  spec.authors = ["innocentdiaz"]
  spec.email = ["sdz.innocent@gmail.com"]

  spec.summary = "Rails integration for s1: records are measurable, and their columns are where measurements collapse."
  spec.description = <<~DESC
    ActiveRecord models declare how they are measurable (measurable_as), then judge / choose /
    score questions about themselves; update_measure collapses the distributions into columns,
    coerced by column type. Railtie wires the logger, the boot check against the schema, and
    ActiveSupport::Notifications for cost tracking.
  DESC
  spec.homepage = "https://github.com/innocentdiaz/s1_rails"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.2.0"

  spec.metadata["homepage_uri"] = spec.homepage
  spec.metadata["source_code_uri"] = spec.homepage
  spec.metadata["rubygems_mfa_required"] = "true"

  gemspec = File.basename(__FILE__)
  spec.files = IO.popen(%w[git ls-files -z], chdir: __dir__, err: IO::NULL) do |ls|
    ls.readlines("\x0", chomp: true).reject do |f|
      (f == gemspec) ||
        f.start_with?(*%w[bin/ test/ spec/ features/ .git .github appveyor Gemfile])
    end
  end
  spec.require_paths = ["lib"]

  spec.add_dependency "activejob", ">= 7.1"
  spec.add_dependency "activemodel", ">= 7.1"
  spec.add_dependency "activerecord", ">= 7.1"
  spec.add_dependency "activesupport", ">= 7.1"
  spec.add_dependency "railties", ">= 7.1"
  spec.add_dependency "s1", "~> 0.3"
end
