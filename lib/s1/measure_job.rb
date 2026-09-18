# frozen_string_literal: true

require "active_job"

module S1
  # update_measure off the request thread. Questions travel as their #to_h — a
  # declared score's with the labels its column stores beside it (stores:), so the
  # job writes the label and not the description shown — declared columns as their
  # names, built here, on the reloaded record, so a dynamic scale or a field's lens
  # reads the record as it is now; transient provider failures retry with ActiveJob's backoff.
  #
  #   ticket.update_measure_later(as: :with_plan) { |q| q.choose :department, "Which team?", **departments }
  #   ticket.update_measure_later(:department, :severity)
  class MeasureJob < ActiveJob::Base
    retry_on TransientError, wait: :polynomially_longer, attempts: 5

    def perform(record, form, questions, args = {}, given = nil, columns = nil)
      # A worker running other code than the enqueuer (a deploy in progress, a
      # branch switched under it) can load the record's class without the mixin.
      raise ArgumentError, "#{record} is not measurable? Does it include S1::Measurable?" unless record.is_a?(S1::Measurable)

      fields = Array(columns).map(&:to_sym)
      record.as(form&.to_sym, given: given&.symbolize_keys, **args.symbolize_keys).update_measure!(fields.presence) do |q|
        questions.each do |id, h|
          q.add(id.to_sym, S1::Question.from_h(h))
          stores = h.to_h.transform_keys(&:to_s)["stores"]
          q.stores(id.to_sym, stores) if stores
        end
      end
    end
  end

  # The job's earlier name; a payload enqueued under it still deserializes.
  AskJob = MeasureJob
end
