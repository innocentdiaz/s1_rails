# frozen_string_literal: true

require "s1"
require_relative "s1/rails_version"
require_relative "s1/measurable"
S1::Evaluable = S1::Measurable # the earlier name
require_relative "s1/judge_validator"
require_relative "s1/measure_job"
require_relative "s1/railtie" if defined?(Rails::Railtie)
