# frozen_string_literal: true

module S1
  module Measurable
    # The Result a Measurable::State measures: an S1::Result that also remembers what was
    # asked — per id, the question, the form it went through and the labels its score
    # stores — so a write from another State still audits the question as asked. A plain
    # S1::Result assigned to a record carries no question, and its audit says so.
    class Result < S1::Result
      attr_reader :asked

      def initialize(asked: {}, **)
        @asked = asked.to_h.freeze
        super(**)
      end

      def self.wrap(result, asked)
        new(distributions: result.distributions, usage: result.usage, model: result.model, provider: result.provider,
            duration_ms: result.duration_ms, raw: result.raw, asked: asked.to_h.slice(*result.distributions.keys))
      end

      def with(**changes) = super(asked: asked, **changes)
    end
  end
end
