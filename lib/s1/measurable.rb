# frozen_string_literal: true

require "active_support/concern"
require_relative "measurable/declarations"
require_relative "measurable/plan"
require_relative "measurable/relation"
require_relative "measurable/questions"
require_relative "measurable/staging"
require_relative "measurable/writing"
require_relative "measurable/audit"
require_relative "measurable/result"
require_relative "measurable/state"

module S1
  # A record that is measurable: it answers S1 questions about itself, and its
  # columns are where the measurements collapse.
  #
  #   class PhoneCall < ApplicationRecord
  #     include S1::Measurable
  #     measurable_as                   { { transcript: live_transcript } }
  #     measurable_as(:quality_review)  { { transcript: live_transcript, preferences: law_firm.preferences } }
  #     judges  :is_lead,   "Is this a potential new client?"
  #     chooses :case_type, "What kind of case?", mva: "a vehicle collision", slip: "a fall on someone's premises"
  #   end
  #
  #   phone_call.judge?("Is the caller asking for a human?")            # default form
  #   phone_call.judge?(:is_lead)                                        # a declared field: its own question, form and lens
  #   phone_call.as(:quality_review).measure { |q| ... }                 # named form
  #   phone_call.update_measure(:is_lead, :case_type)                    # distributions -> columns
  #   PhoneCall.where(scored: false).update_measure_all(concurrency: 5) { |q, call| ... }
  #   PhoneCall.today.where_judged("Does the caller mention a competitor?", concurrency: 8)
  #
  # The macros, the registry and the boot check are Measurable::Declarations; the
  # relation verbs Measurable::Relation. A form is a plain method (s1_state_<name>),
  # so subclasses can override it and forms can call each other. With no form
  # declared, the state is #attributes less what is never evidence: the key, the
  # timestamps, the audit, and every measured column with its siblings.
  module Measurable
    extend ActiveSupport::Concern

    # A relation carrying a `given(...)` lens for the judgements down the chain.
    module Given
      attr_accessor :s1_lens

      alias s1_context s1_lens
      alias s1_context= s1_lens=
    end

    # measure_on: → the Rails hook. before_validation measures synchronously; the rest enqueue.
    MEASURE_ON = { validation: :before_validation, create: :after_create_commit,
                   save: :after_save_commit, update: :after_update_commit }.freeze

    # What a measurement's own save also writes, beside the columns it collapsed into.
    OWN_WRITE = %w[s1_answers created_at updated_at].freeze

    class << self
      def models = (@models ||= [])

      # Every Measurable model's declarations against its schema — subclasses included — when
      # a constant names them (an anonymous class is a spec's, verified by the spec). The Railtie
      # runs it after initialize when the app eager-loads; a spec can call it directly.
      def verify!
        models.flat_map { |m| [m, *m.descendants] }.uniq.select { |m| named?(m) }.reject { |m| m.abstract_class? || !m.table_exists? }
              .each(&:s1_verify_fields!)
      end

      def named?(klass)
        klass.name && Object.const_defined?(klass.name) && Object.const_get(klass.name).equal?(klass)
      rescue NameError
        false
      end
    end

    included do
      Measurable.models << self
      before_save { s1_saving! }
      after_save { s1_saved_changes! }
      after_touch { s1_transaction! }
    end

    module ClassMethods
      include Declarations
      include Relation
    end

    # The facts: the record rendered through a form, alone — what sits at `this` under a lens.
    # With no default form declared, the attributes less what is never evidence (s1_omitted: the
    # key, the timestamps, the audit, the measured columns and their siblings — a measurement is
    # not its own evidence) — which take no arguments, so any are an error rather than dropped.
    # `s1_state` is the old name (the theory's state is facts plus lens: `as`).
    def s1_facts(name = :default, **args)
      form = :"s1_state_#{name}"
      return public_send(form, **args) if respond_to?(form)
      raise ArgumentError, "#{self.class} has no s1_state #{name.inspect}" unless name == :default
      raise ArgumentError, "#{self.class} default form takes no arguments (got #{args.keys.inspect})" if args.any?

      respond_to?(:attributes) ? attributes.except(*self.class.s1_omitted) : to_h
    end
    alias s1_state s1_facts

    # `given:`, `threshold:`, `provider:`, `model:` and `timeout:` are the State's; the rest
    # are the form's arguments. No form named: the default, unless a declared field says otherwise.
    def as(name = nil, given: nil, **args) = Measurable::State.new(self, name, lens: given, **args)

    # No measured_against declared: no lens.
    def s1_lens = {}
    alias as_measurable as

    # Judged against a lens — the direct spelling of what measured_against does persistently.
    def given(**) = as.given(**)
    alias against given
    # S1.to_state(record) / ψ(record); ψ(record, as: :thread, last: 10)
    def to_s1(as: nil, given: nil, **args) = self.as(as, given: given, **args)

    # The verbs, on the record's default form, under the naming rule — a verb
    # measures and returns the distribution; a noun returns the thing it names;
    # a `?` returns a boolean — exactly as on an S1::State: judge (noul), judge?
    # (noul?, ask?), is / is?, same_as / same_as?, choose / choice, score /
    # level, measure (ask, batch, ask_about). A declared column name stands for its question
    # everywhere: `item.choose(:category)`, `item.judge?(:plausible)`, `item.is?(:plausible)`,
    # `item.measure(:plausible, :match)` — measured, nothing written. `as:` on any verb is the
    # form (`item.judge?(:plausible, as: :thread)` is `item.as(:thread).judge?(:plausible)`). A
    # column takes `given:` and, on a collapse, `threshold:`; any other option belongs in its
    # declaration and raises. The wrong verb for a column raises too (`judge?(:category)` on a
    # choice column).
    def judge(question, as: nil, **) = self.as(as).judge(question, **)
    alias noul judge
    def judge?(question, as: nil, **) = self.as(as).judge?(question, **)
    alias noul? judge?
    alias ask? judge?
    def is(phrase, as: nil, **) = self.as(as).is(phrase, **)
    def is?(phrase, as: nil, **) = self.as(as).is?(phrase, **)
    def same_as(other, as: nil, **) = self.as(as).same_as(other, **)
    def same_as?(other, as: nil, **) = self.as(as).same_as?(other, **)
    def choose(question, as: nil, **) = self.as(as).choose(question, **)
    def choice(question, as: nil, **) = self.as(as).choice(question, **)
    def score(question, *levels, as: nil, **) = self.as(as).score(question, *levels, **)
    def level(question, *levels, as: nil, **) = self.as(as).level(question, *levels, **)
    def measure(*questions, as: nil, given: nil, **args, &) = self.as(as, given: given, **args).measure(one_or_many(questions), &)
    alias ask measure
    alias batch measure
    alias ask_about measure

    # The S1::Request(s) a measurement would send, without sending: the sharp knife under every
    # verb. Takes column names or a block, never a bare String (that is a question for judge /
    # choose / score); a gated field's Request is shown too — the gate decides whether to ask.
    #   call.s1_request(:is_lead)                    call.as(:review, given: { p: 1 }).request { |q| q.judge :is_lead }
    def s1_request(*questions, as: nil, given: nil, **args, &) = self.as(as, given: given, **args).request(one_or_many(questions), &)

    # The distribution a field was last written from, rebuilt from s1_answers — over the scale
    # (a static field's own S1::Scale, when the row was stored over it; else one of the stored labels),
    # at the threshold and with the confidence it was taken with; nil without one. A source,
    # not just an audit: `call.measurement(:is_lead).true?(0.9)` re-collapses without re-asking.
    # The audit keys a score by rank, as every score is, so a rehydrated score reads as the
    # live one did — legend, `key` and probabilities by rank — when the entry stored its scale;
    # a row stored without one keeps the wire keys as its labels. A noul stored before
    # thresholds were, with no field threshold, is stamped with the config's now. Nothing is
    # ever stored without the column, so its absence raises rather than reads as "not yet".
    def measurement(id)
      raise ArgumentError, "#{self.class}: measurement needs an s1_answers column" unless has_attribute?(:s1_answers)

      entry = s1_answers.to_h[id.to_s]
      return unless entry

      probabilities = entry["probabilities"].to_h
      case entry["kind"]
      when "noul"
        threshold = entry["threshold"] || self.class.s1_fields.dig(id.to_sym, :threshold)
        S1::Answer::Noul.new(id: id, probability: probabilities["true"].to_f, threshold: threshold)
      when "choice"
        S1::Answer::Choice.new(id: id, choice: entry["value"], probabilities: probabilities, confidence: entry["confidence"],
                               scale: s1_declared_scale(id, probabilities.keys))
      when "score"
        legend = stored_legend(id, entry)
        S1::Answer::Score.new(id: id, legend: legend, probabilities: probabilities, confidence: entry["confidence"],
                              scale: s1_declared_scale(id, legend.values))
      end
    end

    # The field's declared S1::Scale, kept by a rehydrated distribution when the row was stored over it — the stored
    # labels are its (a renamed declaration's is another scale; a dynamic one never is).
    def s1_declared_scale(id, stored)
      scale = self.class.s1_fields.dig(id.to_sym, :scale)
      scale if scale && !scale.dynamic? && (stored - scale.labels).empty?
    end
    private :s1_declared_scale

    # The category a measured column holds, as a value on the field's scale — an S1::Level, a Symbol — or nil
    # when the column is nil or blank; the generated `<name>_<key>?` predicates read it. A String value off the scale
    # raises KeyError; an integer off its indexes, or a float with no audit, ArgumentError.
    def s1_category(name)
      value = self.class.s1_collapsed(name, self)
      self.class.s1_scale_for(name, self).fetch(value) unless value.nil? || value == ""
    end

    # A stored score's legend: the stored scale by position (else the declaration's now), so a
    # provider that left out a zero-mass key still rehydrates to the level it named; only with
    # no scale at all do the wire keys name themselves.
    def stored_legend(id, entry)
      labels = entry["scale"] || self.class.s1_levels_for(id, self)&.first
      return labels.each_with_index.to_h { |label, i| [i, label] } if labels

      entry["probabilities"].to_h.keys.sort_by(&:to_i).to_h { |k| [k, k] }
    end
    private :stored_legend

    # Whether a field's stored measurement was taken under the question the declaration asks now.
    # One row's Model.stale(:col), and it needs the same column.
    def stale?(id)
      raise ArgumentError, "#{self.class}: stale? needs an s1_answers column" unless has_attribute?(:s1_answers)
      raise ArgumentError, "#{self.class}: #{id.to_sym.inspect} is not a measured field" unless self.class.s1_fields.key?(id.to_sym)

      s1_answers.to_h.dig(id.to_s, "question_digest") != self.class.s1_question_digest(id, self)
    end

    # The Result this instance last collapsed (update_measure, assign_measure), in memory only:
    # `call.update_measure(:is_lead); call.s1_result[:is_lead]`. Persisted answers are the
    # optional s1_answers column; measurement(:col) rebuilds one from it.
    attr_reader :s1_result

    def s1_measured(result) = @s1_result = result

    # Measure, collapse, save — as ActiveRecord's update: true, or false when the save is
    # invalid; update_measure! raises instead. The Result is s1_result either way.
    # `questions`: a block, a Questions, a Hash, or column names (`update_measure(:is_lead, :severity)`).
    def update_measure(*questions, as: nil, given: nil, **args, &block)
      self.as(as, given: given, **args).update_measure(one_or_many(questions)) { |q| block&.call(q, self) }
    end
    alias update_judge update_measure
    alias update_ask update_measure

    def update_measure!(*questions, as: nil, given: nil, **args, &block)
      self.as(as, given: given, **args).update_measure!(one_or_many(questions)) { |q| block&.call(q, self) }
    end
    alias update_judge! update_measure!
    alias update_ask! update_measure!

    # Same, without saving — for enrichment inside a save:
    #   before_save -> { assign_measure { |q| q.choose :department, "Which team?", **DEPARTMENTS } },
    #               if: :will_save_change_to_body?
    def assign_measure(*questions, as: nil, given: nil, **args, &block)
      self.as(as, given: given, **args).assign_measure(one_or_many(questions)) { |q| block&.call(q, self) }
    end
    alias assign_ask assign_measure
    alias assign_judge assign_measure

    # Same, enqueued. The block runs now (so it can read the record); column names
    # travel as names and build in the job, on the reloaded record; a block's declared
    # score travels with the labels its column stores. Extra keywords are the form's
    # arguments. The job reads the row, so unsaved changes are refused here rather than
    # silently left behind.
    def update_measure_later(*questions, as: nil, given: nil, **args, &)
      s1_saved!
      s1_perform_later(*questions, as: as, given: given, **args, &)
    end
    alias update_ask_later update_measure_later
    alias update_judge_later update_measure_later

    # A job measures the row; changes still in memory would be judged by update_measure and by nothing else.
    def s1_saved!
      return unless changed?

      raise ArgumentError, "#{self.class}: unsaved changes to #{changed.inspect} would not reach the job; save first, or update_measure"
    end

    # Marks a save as a measurement's own write of `written` (the columns it collapsed into,
    # their siblings, the audit): the after-commit triggers skip a save that changed nothing
    # else, and never re-enqueue a field the measurement already wrote from the state being
    # saved. The mark holds until the next save that is not a measurement's, within one transaction.
    def s1_applying(written = nil)
      s1_transaction!
      @s1_written = @s1_written.to_a | Array(written).map(&:to_s) | @s1_assigned.to_a | OWN_WRITE
      @s1_applying = true
      yield
    ensure
      @s1_applying = false
    end

    def s1_applying? = @s1_applying == true

    # What assign_measure put on the record and has not saved yet: the caller's own save of it
    # is the measurement's write too, so its trigger never asks the same question twice.
    def s1_assigned(columns)
      @s1_assigned = @s1_assigned.to_a | Array(columns).map(&:to_s)
    end

    # Whether the transaction's saves wrote only what a measurement writes (`changed`: the keys
    # to test; by default every save's since the transaction began).
    def s1_own_write?(changed = @s1_changed)
      !@s1_written.nil? && (changed.to_a - @s1_written - [self.class.primary_key.to_s]).empty?
    end

    # Whether an attribute changed in any save of the transaction just committed — what an
    # attribute trigger watches; saved_changes alone would be the last save's, and an
    # attribute a later before_save set is here too.
    def s1_changed?(attribute) = @s1_changed.to_a.include?(attribute.to_s)

    # A trigger's callback: the key's fields on this record's class, read now — a subclass's
    # own list, a redeclared field's new home — less the fields a measurement wrote from the
    # committed state. A commit whose saves changed nothing — a `touch`, a child's `touch: true`,
    # a save with no changes — is not a trigger. A record dirtied after its save is enqueued on
    # the committed row and the log says what stayed behind; the raise is update_measure_later's own.
    def s1_enqueue_trigger!(key)
      return if s1_own_write? || (@s1_changed.to_a - OWN_WRITE).empty?

      fields = self.class.s1_triggers[key].to_a - @s1_written.to_a.map(&:to_sym)
      return if fields.empty?

      if changed?
        (S1.config.logger || Kernel).warn("[s1] #{self.class}##{id}: unsaved changes to #{changed.inspect} do not reach the job measuring #{fields.inspect}")
      end
      s1_perform_later(*fields)
    end

    # A :validation field is assigned unless the save is a measurement's own write and nothing else's.
    def s1_assign_trigger!(key)
      fields = self.class.s1_triggers[key]
      assign_measure(*fields) if fields.present? && !(s1_applying? && s1_own_write?(changes.keys))
    end

    # A save that is not a measurement's clears the write mark — unless what it carries was
    # assigned by assign_measure, which makes it the measurement's own write of those columns.
    def s1_saving!
      s1_transaction!
      @s1_written = @s1_assigned && (@s1_assigned | OWN_WRITE) unless s1_applying?
      @s1_assigned = nil
    end

    # Every save's saved changes accumulate over one transaction — read after the save, so an
    # attribute a later before_save set counts — and start over with the next transaction.
    def s1_saved_changes!
      @s1_changed = @s1_changed.to_a | saved_changes.keys
    end

    def s1_transaction!
      transaction = self.class.connection.current_transaction
      return if transaction.equal?(@s1_transaction)

      @s1_transaction = transaction
      @s1_changed = []
      @s1_written = nil
    end
    private :s1_saving!, :s1_saved_changes!, :s1_transaction!

    # The lens is evidence, fixed at enqueue: a Proc at its top is evaluated on the record here,
    # as every other path evaluates it, and travels as its value.
    # metadata: rides in the form's arguments; the job's State takes it back out.
    def s1_perform_later(*questions, as: nil, given: nil, **args, &)
      questions = one_or_many(questions)
      columns = Array(questions).map(&:to_s) if questions.is_a?(Symbol) || questions.is_a?(Array)
      into = s1_job_questions(columns ? {} : questions.to_h, &)
      raise S1::ValidationError, "no questions given" if columns.nil? && into.empty?

      lens = given && Measurable::State.render(self.class.s1_evaluated_lens(given.to_h, self), [self]).transform_keys(&:to_s)
      args[:metadata] = S1::Metadata.check!(args[:metadata]) if args.key?(:metadata)
      S1::MeasureJob.perform_later(self, as&.to_s, s1_job_payload(into), args.transform_keys(&:to_s), lens, columns)
    end

    def s1_job_questions(pairs)
      into = Measurable::Questions.new(self)
      pairs.each { |id, q| into.add(id, q) }
      yield into, self if block_given?
      into
    end

    # id => the question's wire form, a declared score's stored labels riding beside it as stores:.
    def s1_job_payload(into)
      into.to_h.to_h { |id, q| [id.to_s, into.labels[id] ? q.to_h.merge(stores: into.labels[id]) : q.to_h] }
    end
    private :s1_perform_later, :s1_job_questions, :s1_job_payload

    def one_or_many(questions) = questions.size <= 1 ? questions.first : questions
    private :one_or_many
  end
end
