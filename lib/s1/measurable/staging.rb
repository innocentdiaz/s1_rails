# frozen_string_literal: true

require "digest"
require "json"

module S1
  module Measurable
    # How a Measurable::State runs a measurement: the questions are sourced (column
    # names build from the registry, per stage; a block's questions are built once),
    # the declared fields planned (Measurable::Plan), each batch measured on the
    # State that batch calls for, and the Results merged in the caller's order.
    # Between stages the collapses are assigned provisionally — each at its column's
    # own threshold — so a later stage's form (rendered again for that stage), dynamic
    # scale, lens and if: / unless: read them; measure itself leaves the record as it was.
    module Staging
      protected

      attr_writer :capture, :ungated, :pristine

      # One provider call for these built questions, on this State: cached when the
      # record is versioned and unchanged; captured instead of sent when `capture` is set;
      # handed to `in_flight` — a relation's thread — when one is set.
      def measure_once(built)
        if @capture
          request = S1::Request.new(state: rendered, questions: built, model: @model, timeout: @timeout || S1.config.timeout, options: options)
          return @capture.call(request).with_threshold(@threshold)
        end
        return in_flight { S1.measure(self, built, **overrides) } unless cacheable?

        key = ["s1", record.cache_key_with_version, form, args, facts_digest, lens, built.transform_values(&:to_h), *answerer]
        S1.config.cache.fetch(key) { in_flight { S1.measure(self, built, **overrides) } }.with_threshold(@threshold)
      end

      private

      # The provider call alone, off this thread when a relation runs several records at once:
      # the call is handed over, its outcome comes back here, and an error raises here.
      def in_flight(&work)
        return work.call unless @in_flight

        outcome = @in_flight.call(work)
        outcome.is_a?(Exception) ? raise(outcome) : outcome.first
      end

      def overrides = { provider: @provider, model: @model, timeout: @timeout, threshold: @threshold, **options }

      # The form's rendering, in the cache key: a form that renders differently is a different measurement.
      def facts_digest = Digest::SHA256.hexdigest(JSON.generate(facts))

      # id => Question for a block's questions and inline pairs; id => :field for column names,
      # built per stage. A String naming a declared field is that column; any other is a question
      # for a verb. What an earlier call on this State asked is forgotten here.
      def sources_for(questions, inline, &)
        @labels = {}
        @asked = {}
        questions = questions.to_sym if questions.is_a?(String) && record.class.s1_fields.key?(questions.to_sym)
        if questions.is_a?(String)
          raise ArgumentError, "a String is a question for judge / choose / score; measure and s1_request take column names " \
                               "or a block (q.judge :id, #{questions.inspect})"
        end

        columns = questions.is_a?(Symbol) || questions.is_a?(Array) ? Array(questions).map(&:to_sym) : []
        built = built_questions(columns.any? ? nil : questions, inline, &)
        raise S1::ValidationError, "no questions given" if columns.empty? && built.empty?

        twice = columns & built.keys
        raise S1::ValidationError, "duplicate question id #{twice.first.inspect}" if twice.any?

        columns.to_h { |c| [c, :field] }.merge(built)
      end

      def built_questions(questions, inline, &block)
        questions = questions.nil? ? inline : questions.to_h.merge(inline) if inline.any?
        into = Measurable::Questions.new(record)
        (questions || {}).each { |id, q| into.add(id, q) }
        block&.call(into)
        remember_labels(into)
      end

      # The builder's questions, its stored labels kept beside them for the scores.
      def remember_labels(builder)
        @labels = (@labels || {}).merge(builder.labels)
        builder.to_h
      end

      def fixed = { as: (@form if @form_given), provider: @provider, model: @model, given: @given_lens.presence }.compact

      # The plan's batches with their ids, in the caller's order; questions that are not
      # declared fields join the first stage's home batch.
      def batched(plan, sources)
        undeclared = sources.keys - plan.fields
        stages = plan.stages.map { |batches| batches.map { |b| [b, b.fields] } }
        unless undeclared.empty?
          stages[0] ||= []
          home = stages[0].find { |b, _| home?(b) } || stages[0].unshift([Plan::HOME, []]).first
          home[1] = home[1] + undeclared
        end
        stages.map { |stage| stage.filter_map { |b, ids| [b, sources.keys & ids] if ids.any? } }
      end

      # The stages in order. `collapses` is what each earlier stage decided, as the column
      # would hold it — the lens of every field that comes after — and it is what the record
      # is provisionally assigned.
      def staged(plan, sources)
        results = []
        asked = []
        collapses = {}
        @pristine = !record.changed? if @pristine.nil?
        provisionally do |assign|
          stages = batched(plan, sources)
          stages.each_with_index do |batches, i|
            stage = run_stage(batches, sources, collapses, asked)
            results.concat(stage)
            decide(stage, collapses, assign) if i < stages.size - 1 && stage.any?
          end
        end
        @measured = Measurable::Result.wrap(restamp(merged(results, sources.keys & asked)), @asked)
      ensure
        @pristine = nil
      end

      def run_stage(batches, sources, collapses, asked)
        batches.filter_map do |batch, ids|
          ids = ids.select { |id| admitted?(id, sources, collapses) }
          asked.concat(ids)
          run(batch, build(ids, sources), collapses) if ids.any?
        end
      end

      # A stage's collapses, each at its column's threshold: into `collapses`, and onto the record.
      def decide(stage, collapses, assign)
        decided = restamp(merged(stage, stage.flat_map { |r| r.distributions.keys }))
        decided.each { |id, d| collapses[id] = as_column(d) }
        assign.call(Measurable::Result.wrap(decided, @asked))
      end

      # One batch, on its State; the questions asked, the form they went through and the
      # labels their scores store are kept for the audit, and the scores come back speaking
      # those labels.
      def run(batch, built, collapses)
        labels = built.to_h { |id, q| [id, q.is_a?(S1::Question::Score) ? (@labels&.[](id) || q.levels) : nil] }
        @asked = (@asked || {}).merge(built.to_h { |id, q| [id, [q, batch.as || form, labels[id]]] })
        result = state_for(batch, collapses).measure_once(built)
        relabelled = result.distributions.to_h { |id, d| [id, d.is_a?(S1::Answer::Score) ? relabel(d, labels[id]) : d] }
        result.with(distributions: relabelled)
      end

      # The same distribution over the labels the column stores: the model saw the descriptions,
      # the program sees the scale — by rank through the legend, whatever keys the wire used — and
      # a static field's own S1::Scale. A scale of another size is another question, and raises naming both.
      def relabel(distribution, labels)
        asked = distribution.levels.map(&:to_s)
        return distribution if labels.nil? || asked == labels

        if asked.size != labels.size
          raise S1::ValidationError, "#{record.class}: #{distribution.id.inspect} was asked over #{asked.inspect} but stores " \
                                     "#{labels.inspect}; a scale of another size is another question"
        end

        keys = legend_of(distribution).keys.sort
        S1::Answer::Score.new(id: distribution.id, legend: keys.zip(labels).to_h, probabilities: distribution.probabilities,
                              confidence: distribution.confidence, raw: distribution.raw, scale: record.class.s1_fields.dig(distribution.id, :scale))
      end

      # A sequenced field's if: / unless: decide whether it joins its stage — read on the record
      # with the earlier collapses in place; a predecessor gated out of this call takes it along.
      # A bare verb (choose(:col)) asks regardless.
      def admitted?(id, sources, collapses)
        return true if @ungated || sources[id] != :field

        field = record.class.s1_fields.fetch(id, {})
        deps = Array(field[:after])
        return false if deps.any? { |dep| sources.key?(dep) && !collapses.key?(dep) }
        return true unless field[:after] && field[:conditions]

        record.class.s1_gate?(id, record)
      end

      def build(ids, sources)
        builder = Measurable::Questions.new(record)
        ids.each { |id| sources[id] == :field ? builder.field_question(id) : builder.add(id, sources[id]) }
        remember_labels(builder).freeze
      end

      # Assigns between stages, and puts the record back afterwards whatever happens.
      def provisionally
        snapshot = nil
        yield lambda { |result|
          attributes = assignments(result)
          snapshot = record.attributes.slice(*attributes.keys.map(&:to_s)).merge(snapshot || {})
          record.assign_attributes(attributes)
        }
      ensure
        record.assign_attributes(snapshot) if snapshot
      end

      def home?(batch)
        (batch.as || form) == form && batch.given.nil? && batch.after.nil? && batch.metadata.nil? &&
          (batch.provider.nil? || batch.provider == @provider) && (batch.model.nil? || batch.model == @model)
      end

      # The State a batch runs on: this one, or the same record under the batch's form
      # and lens — the call's over the field's, the collapses it comes after last (a
      # predecessor's name is its collapse, never a lens key — a call or field lens naming
      # one raises). A later stage renders its form again, so the form reads the collapses
      # as the gate and the dynamic scale do; a first-stage batch keeps the facts as prepared.
      def state_for(batch, collapses)
        return self if home?(batch)

        lens = record.class.s1_lens_for(batch.fields.first, record).merge(@given_lens || {})
        lens_clash!(batch, lens.keys, "given:")
        lens_clash!(batch, @declared.keys.map(&:to_sym), "measured_against")
        sub = sub_state(batch, lens.merge(sequenced(batch, collapses)))
        sub.capture = @capture
        sub.pristine = @pristine
        sub.in_flight = @in_flight
        sub
      end

      def lens_clash!(batch, keys, spelling)
        clash = keys & Array(batch.after)
        return if clash.empty?

        raise ArgumentError, "#{record.class}: #{spelling} #{clash.first.inspect} is a field #{batch.fields.first.inspect} comes after; " \
                             "its collapse is that key — write the column to judge against another"
      end

      # The same facts re-lensed for a first-stage batch under this form; the record rendered again otherwise.
      # The call's metadata merges over the field's.
      def sub_state(batch, lens)
        settings = { provider: @provider || batch.provider, model: @model || batch.model, timeout: @timeout, threshold: @threshold }
        metadata = batch.metadata ? batch.metadata.merge(options[:metadata].to_h) : options[:metadata]
        same_form = (batch.as || form) == form
        return dup.configure(**settings, options: options.merge(metadata: metadata).compact).relens(lens) if same_form && batch.after.nil?

        record.as(batch.as || form, given: lens, metadata: metadata, **settings, **(same_form ? args : {}))
      end

      # { field => its collapse } for the fields a batch comes after: decided in this call, else
      # read from the row — a float or decimal column is not a collapse (a judge's whole
      # distribution, a score's expectation), so its collapse is the stored measurement's: a
      # score's argmax, a judge at the threshold it was taken under unless this call has its own;
      # without an audit row a noul column collapses at the call's, the field's or the config's
      # threshold and a score column's read raises — and it must hold one on the scale; nil, a
      # blank, or a label the scale no longer has is not a category to judge against.
      def sequenced(batch, collapses)
        Array(batch.after).to_h do |dep|
          next [dep, collapses[dep]] if collapses.key?(dep)

          value = stored_collapse(dep)
          value = record.class.s1_collapsed(dep, record, threshold: @threshold) if value.nil?
          if value.nil? || (value.respond_to?(:empty?) && value.empty?)
            raise ArgumentError, "#{record.class}: #{dep.inspect} has not been measured, and #{batch.fields.first.inspect} is judged given it; " \
                                 "measure both — measure(#{dep.inspect}, #{batch.fields.first.inspect})"
          end
          held_on_scale!(dep, value)
          [dep, value]
        end
      end

      # A float or decimal column's collapse, from the audit — what the column does not keep: a
      # score's argmax; a judge's verdict at the threshold stamped on it, the call's winning. A
      # declaration's threshold changed since reaches the row on remeasure, as on a boolean column;
      # Model.s1_collapsed reads the same way.
      def stored_collapse(dep)
        kind = record.class.s1_fields.dig(dep, :kind)
        return unless %i[noul score].include?(kind) && record.has_attribute?(:s1_answers)
        return unless %i[float decimal].include?(record.class.type_for_attribute(dep.to_s).type)

        stored = record.measurement(dep) or return
        kind == :score ? stored.collapse.to_str : stored.collapse(*[@threshold].compact)
      end

      # A choice or score column holds a label on its scale now; a legacy one raises naming the remeasure.
      def held_on_scale!(dep, value)
        scale = scale_of_field(dep)&.map(&:to_s)
        return if scale.nil? || scale.include?(value.to_s)

        raise ArgumentError, "#{record.class}: #{dep.inspect} holds #{value.inspect}, which is not on its scale #{scale.inspect}; " \
                             "measure it again — update_measure(#{dep.inspect})"
      end

      def scale_of_field(dep)
        model = record.class
        case model.s1_fields.dig(dep, :kind)
        when :choice then (model.s1_categories_for(dep, record) || model.s1_categories(dep))&.keys
        when :score then model.s1_levels_for(dep, record)&.first
        end
      end

      # A collapse as the column would hold it: a boolean, the category's text, the level's label.
      def as_column(distribution)
        case distribution
        when S1::Answer::Noul then distribution.collapse
        when S1::Answer::Score then distribution.level.to_str
        else distribution.to_s
        end
      end

      # Nouls of fields declared with a threshold collapse there, unless this State has its own.
      def restamp(result)
        return result if @threshold

        stamped = result.distributions.filter_map do |id, d|
          threshold = record.class.s1_fields.dig(id, :threshold)
          [id, d.with(threshold: threshold)] if threshold && d.is_a?(S1::Answer::Noul)
        end.to_h
        stamped.empty? ? result : result.with(distributions: result.distributions.merge(stamped))
      end

      # Several calls' Results as one, distributions in `order`, usage summed; one Result is
      # itself; none (every field gated out) an empty one.
      def merged(results, order)
        return S1::Result.new(distributions: {}) if results.empty?
        return results.first if results.one?

        distributions = order.to_h { |id| [id, results.find { |r| r.key?(id) }[id]] }
        one = ->(values) { values.uniq.one? ? values.first : nil }
        S1::Result.new(distributions: distributions, usage: summed_usage(results), model: one[results.map(&:model)],
                       provider: one[results.map(&:provider)], duration_ms: results.sum { |r| r.duration_ms.to_i }, raw: results.map(&:raw))
      end

      def summed_usage(results)
        results.map(&:usage).reduce({}) { |sum, u| sum.merge(u) { |_, a, b| a.is_a?(Numeric) && b.is_a?(Numeric) ? a + b : b } }
      end
    end
  end
end
