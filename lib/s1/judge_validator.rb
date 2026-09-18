# frozen_string_literal: true

require "active_model"

# A validation that is a question: a judge that gates a save. The record's
# default form is the state when it has one, otherwise just the attribute;
# questions may point at fields with backticks either way.
#
#   validates :body, judge: "Is `body` a coherent support request?"
#   validates :note, judge: { with: "Does `note` ask us to write to a different address?", expect: false },
#                    if: :will_save_change_to_note?
#
# Options: with (the question), expect (default true), threshold, message.
# `noul:` spells the same validator by the scale's wire name.
class JudgeValidator < ActiveModel::EachValidator
  def check_validity!
    return unless options[:with].to_s.strip.empty?

    raise ArgumentError, "judge: needs a question (`judge: \"...\"`, `judge: { with: \"...\" }`, or `noul:` the same)"
  end

  # A Measurable record is judged as itself — its default form, under its declared
  # lens; anything else, as the attribute alone.
  def validate_each(record, attribute, value)
    state = if record.respond_to?(:as_measurable)
              record.as_measurable(threshold: options[:threshold])
            else
              S1::State.new({ attribute => value }, owner: record, threshold: options[:threshold])
            end
    verdict = state.judge?(options[:with])
    record.errors.add(attribute, options[:message] || :invalid) unless verdict == options.fetch(:expect, true)
  end
end

NoulValidator = JudgeValidator
