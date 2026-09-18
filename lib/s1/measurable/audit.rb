# frozen_string_literal: true

module S1
  module Measurable
    # The s1_answers entry a measurement leaves beside its collapse — the whole measurement,
    # so `measurement(:col)` rebuilds the distribution and `Model.stale(:col)` reads the
    # question it was taken under:
    #   kind · value (the collapse as text: true/false, the category, the level's label) ·
    #   position (a score's rank on its scale) · probabilities (a score's by rank — "0", "1", …
    #   in the scale's order — whatever keys the wire used) · confidence · scale (the labels the
    #   question was asked over) · threshold (a noul's) · question_digest (the question as
    #   asked, whichever State asked it; absent when a plain S1::Result was assigned, so the row
    #   reads stale rather than current) · form · provider · model · measured_at
    module Audit
      private

      def audit(result)
        now = Time.now.utc.iso8601
        asked = result.is_a?(Measurable::Result) ? result.asked : {}
        result.distributions.to_h do |id, d|
          question, through, labels = asked[id.to_sym]
          score = d.is_a?(S1::Answer::Score)
          entry = { "kind" => d.kind, "value" => d.collapse.to_s, "position" => (d.level.position if score),
                    "probabilities" => score ? by_rank(d) : d.probabilities, "confidence" => d.confidence, "scale" => scale_of(d),
                    "threshold" => (d.threshold if d.is_a?(S1::Answer::Noul)), **asked_entry(question, through, labels),
                    "provider" => result.provider&.to_s, "model" => result.model, "measured_at" => now }
          [id.to_s, entry.compact]
        end
      end

      # The digest of the question as asked — with the labels a score stored, as the declaration
      # digests them; none when the Result carries no question.
      def asked_entry(question, through, labels)
        { "question_digest" => (Declarations.digest(question, labels) if question), "form" => (through || form).to_s }
      end

      # The labels the distribution speaks: a score's levels (the stored labels, not the descriptions
      # shown), a choice's categories, a noul's true / false.
      def scale_of(distribution)
        case distribution
        when S1::Answer::Score then distribution.levels.map(&:to_s)
        else distribution.probabilities.keys
        end
      end
    end
  end
end
