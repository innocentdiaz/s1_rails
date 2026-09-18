# frozen_string_literal: true

module S1
  module Measurable
    # A record viewed through one of its forms: an S1::State that also knows
    # the record, so distributions can be written back. Nested Measurable
    # records in the evidence render through their own default form. How a
    # measurement is planned and run — per-field forms, lenses, stages — is
    # Measurable::Staging; how a Result collapses into the row, Measurable::Writing.
    class State < S1::State
      include Staging
      include Writing
      include Audit

      attr_reader :record, :form, :args
      # A relation's hand-off for the provider call (Relation#s1_map): set on the States it runs at once.
      attr_writer :in_flight

      alias context lens

      # The lens is the model's declared one (measured_against), with the per-call
      # lens merged over it — `lens` reads the merged whole. With any lens the
      # state is { this: facts, **lens }; with none, the facts alone. The form and
      # the declared lens render here, once; a lens added later reuses both.
      # `context:` is the lens's old name. threshold:, provider:, model:, timeout:
      # and metadata: are the State's; the rest are the form's. No form named means
      # the default, and a declared field may still say `as:` otherwise.
      def initialize(record, form = nil, lens: nil, context: nil, **args)
        overrides = args.extract!(*OVERRIDES).merge(args.extract!(:metadata).compact)
        Declarations.threshold!("#{record.class}: as(threshold:)", overrides[:threshold])
        record.class.s1_verify_once!
        @record = record
        @form_given = !form.nil?
        @form = (form || :default).to_sym
        @args = args
        @facts = Rendering.render(Measurable::State.render(record.s1_facts(@form, **args), [record]))
        @declared = Rendering.render(Measurable::State.render(record.class.s1_evaluated_lens(record.s1_lens, record), [record]))
        super(@facts, owner: record, form: @form, **overrides)
        relens(lens || context)
      end

      # Judged against a lens, still bound to the record: the form under `this`,
      # the lens beside it, the facts as rendered at prepare, and the writes
      # below still work.
      def given(**lens) = dup.relens((@given_lens || {}).merge(lens))
      alias against given

      # The same record under another form (a predicate's `as:`); otherwise this
      # State, with any options. The lens and the State's overrides carry over;
      # the form's arguments do not — they belong to the form they were given to.
      def to_s1(as: nil, **)
        return super(**) if as.nil? || as.to_sym == form.to_sym

        record.as(as.to_sym, given: @given_lens, provider: @provider, model: @model, timeout: @timeout, threshold: @threshold,
                             metadata: options[:metadata]).to_s1(**)
      end

      # With S1.config.cache set, distributions are keyed by the record's version,
      # the form and its rendering, the lens (declared and per-call), the questions,
      # and who answers (provider, model), so an unchanged record never measures
      # twice; a write through update_measure bumps it. A record with no version
      # (no updated_at) is never cached — nothing would bump it. A cached Result's
      # nouls are re-stamped with this State's threshold.
      # ponytail: nested records don't bump the key — `touch: true` the association.
      # `questions` may also be a declared column name or a list of them; a block
      # beside them measures both; `given:` is the lens inline. A declared field
      # measures under its own form, lens, provider and model unless this State
      # names them; fields that differ split into separate calls (Model.s1_plan).
      def measure(questions = nil, given: nil, metadata: nil, **inline, &)
        return with(metadata: metadata).measure(questions, given: given, **inline, &) if metadata
        return self.given(**given).measure(questions, **inline, &) if given
        raise ArgumentError, THRESHOLD_ON_VERB if inline.key?(:threshold)

        sources = sources_for(questions, inline, &)
        declared = sources.keys.select { |id| record.class.s1_fields.key?(id) }
        staged(Measurable::Plan.new(record.class, declared, fixed, record: record), sources)
      end
      alias ask measure
      alias batch measure
      alias ask_about measure

      # The S1::Request the provider would receive for these questions — every
      # form, lens and definition resolved — without a call; several, in order, when
      # the plan splits them. A gated field's Request is shown too: the gate
      # decides whether to ask, not what.
      def request(questions = nil, given: nil, **inline, &)
        requests = []
        dry = dup
        dry.capture = ->(req) { requests << req and S1::Providers::Stub.new.call(req) }
        dry.ungated = true
        dry.measure(questions, given: given, **inline, &)
        requests.one? ? requests.first : requests
      end

      # A declared column name stands for its question in every verb: the
      # column's own kind, its own question, nothing else.
      #   state.judge(:plausible)   state.is?(:plausible)   state.choose(:category)   state.judge?(:plausible, given: { … })
      def judge(question, **) = question.is_a?(Symbol) ? measured(question, :noul, **) : super
      alias noul judge

      # A collapse's threshold is checked as a declaration's would be, before it reaches the comparison.
      def judge?(question, threshold: nil, **)
        Declarations.threshold!("#{record.class}: judge?(threshold:)", threshold)
        super
      end
      alias noul? judge?
      alias ask? judge?

      def same_as?(other, threshold: nil, **)
        Declarations.threshold!("#{record.class}: same_as?(threshold:)", threshold)
        super
      end

      def is(phrase, **) = phrase.is_a?(Symbol) ? judge(phrase, **) : super
      def is?(phrase, **) = phrase.is_a?(Symbol) ? judge?(phrase, **) : super
      def choose(question, **) = question.is_a?(Symbol) ? measured(question, :choice, **) : super
      def score(question, *levels, **) = question.is_a?(Symbol) ? measured(question, :score, *levels, **) : super

      # measure, then write — as ActiveRecord's update: true, or false when the save is invalid
      # (update_measure! raises instead). The Result stays on the record, record.s1_result, either
      # way. `given:` and inline id => Question pairs as on measure. The State that asked is the
      # one that writes, so the audit knows the question and the form.
      def update_measure(questions = nil, given: nil, **inline, &)
        return self.given(**given).update_measure(questions, **inline, &) if given

        persist(measure(questions, **inline, &), bang: false)
      end
      alias update_judge update_measure
      alias update_ask update_measure

      def update_measure!(questions = nil, given: nil, **inline, &)
        return self.given(**given).update_measure!(questions, **inline, &) if given

        persist(measure(questions, **inline, &), bang: true)
      end
      alias update_judge! update_measure!
      alias update_ask! update_measure!

      def assign_measure(questions = nil, given: nil, **inline, &)
        return self.given(**given).assign_measure(questions, **inline, &) if given

        assign(measure(questions, **inline, &))
      end
      alias assign_ask assign_measure
      alias assign_judge assign_measure

      # Distributions whose id is a column are assigned, coerced by column type,
      # with any declared siblings beside them; the rest are returned untouched
      # (measure speculatively, gate in code). A jsonb/json `s1_answers` column,
      # if present, keeps the raw distributions per id. A Result this State did
      # not measure has its declared judges re-stamped first (the field's threshold,
      # unless this State has one), so the column collapses as the declaration says.
      def assign(result)
        result = stamped(result)
        attributes = assignments(result)
        record.assign_attributes(attributes)
        record.s1_assigned(attributes.keys)
        record.s1_measured(result)
      end

      # What a Result writes: the collapses, the siblings, and the audit (over `stored`, the
      # row's audit as it is now; in memory by default).
      def assignments(result, stored = record.has_attribute?(:s1_answers) && record.s1_answers)
        attributes = result.distributions.select { |id, d| column?(id, d) }.to_h { |id, d| [id, coerce(id, d)] }
        result.distributions.each { |id, d| attributes.merge!(siblings(id, d)) }
        attributes[:s1_answers] = stored.to_h.merge(audit(result)) if record.has_attribute?(:s1_answers)
        attributes
      end

      # The write of a measurement, raising on an invalid save; returns the Result.
      def apply(result) = persist(result, bang: true) && record.s1_result

      OVERRIDES = %i[threshold provider model timeout].freeze
      VERB_FOR = Declarations::VERB
      DECLARED_ONLY = "a declared column carries its own question; pass options in its declaration"

      # Nested measurables render through their own default form; a record met
      # again on the way down (`item: self` in its own form) renders as its
      # attributes instead of recursing. A Proc is not evidence: it is refused
      # here rather than sent as its #inspect.
      def self.render(value, seen = [])
        case value
        when Measurable then seen.include?(value) ? value.attributes : render(value.s1_facts, seen + [value])
        when Hash      then value.to_h { |k, v| [k, render(v, seen)] }
        when Array     then value.map { |v| render(v, seen) }
        when Proc, Method then raise ArgumentError, "#{value.inspect} is not evidence; call it, or put it at the top of a lens"
        else value.respond_to?(:attributes) ? value.attributes : value
        end
      end

      protected

      # The same facts under `lens` merged over the declared lens: nothing re-renders from
      # the record; a Proc at the top of the lens is evaluated on it.
      def relens(lens)
        @given_lens = record.class.s1_evaluated_lens((lens || {}).to_h, record)
        merged = S1::State.lens!(@declared.merge(Rendering.render(Measurable::State.render(@given_lens, [record]))), :this)
        @rendered = merged.empty? ? @facts : { this: @facts, **merged }.freeze
        self.facts = @facts
        self.lens = merged.freeze
        self
      end

      private

      # The triggers see a save that wrote nothing else and do not enqueue another
      # measure for it. The audit merges over the row's, read under a lock, so two
      # measurements of one row keep both entries. Returns what the save returned.
      def persist(result, bang:)
        result = record.s1_measured(stamped(result))
        record.class.transaction do
          attributes = assignments(result, stored_answers)
          record.assign_attributes(attributes)
          record.s1_applying(attributes.keys) { bang ? record.save! : record.save }
        end
      end

      # A record's form is its fields, never the candidates; a form that is a
      # list of labels still is.
      def categories_shaped?(value) = !(value.is_a?(Hash) && value.equal?(@facts)) && super

      # This State's own Result as it is; another's with its declared judges re-stamped.
      def stamped(result)
        return result if result.equal?(@measured)

        @threshold ? result.with_threshold(@threshold) : restamp(result)
      end

      def measured(column, kind, *extra, given: nil, metadata: nil, **options)
        actual = record.class.s1_kind(column)
        raise ArgumentError, "#{column} is a #{actual}; use #{VERB_FOR.fetch(actual)}" unless actual == kind
        raise ArgumentError, THRESHOLD_ON_VERB if options.key?(:threshold)
        raise ArgumentError, DECLARED_ONLY if extra.any? || options.compact.any?

        asking = given ? self.given(**given) : dup
        asking = asking.with(metadata: metadata) if metadata
        asking.ungated = true
        asking.measure(column)[column]
      end

      # Decided before any provisional assignment: a record that was clean when the measurement began stays cacheable.
      def cacheable? = S1.config.cache && !@capture && record.persisted? && (@pristine.nil? ? !record.changed? : @pristine) && versioned?

      # A key that is only the id — no updated_at, whichever way Rails spells the
      # version — would never move after a write.
      def versioned?
        record.respond_to?(:cache_key_with_version) && record.cache_key_with_version != "#{record.model_name.cache_key}/#{record.id}"
      end

      # Who answers: the provider (its name, or its class for an instance) and the
      # model — this State's, else the instance's own, else the one configured for
      # a named provider. An instance with no model is keyed by identity: two of
      # them share nothing.
      def answerer
        provider = @provider || S1.config.provider
        return [provider.to_s, @model || S1.config.section(provider)[:model]] unless provider.respond_to?(:call)

        model = @model || (provider.model if provider.respond_to?(:model))
        model ? [provider.class.name, model] : [provider.class.name, nil, provider.hash]
      end
    end

    Subject = State
  end
end
