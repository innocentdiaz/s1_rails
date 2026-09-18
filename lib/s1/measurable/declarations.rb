# frozen_string_literal: true

require "active_record"
require "digest"
require "json"

module S1
  module Measurable
    # The class macros. A question is declared beside its column by scale kind
    # — judges (dichotomous), chooses (nominal), scores (ordinal) — and lands in
    # one registry, s1_fields. measured_field resolves the kind from the
    # declaration's shape and the column; choice_enum / score_enum declare the
    # Rails enum too. s1_verify_fields! checks the registry against the schema
    # at boot; s1_plan is the call plan the registry implies.
    #
    #   judges  :is_lead,  "Is this a potential new client?", true: "a new matter", threshold: 0.7
    #   chooses :team,     "Which team?", returns: "Refunds", billing: { is: "Charges", not: "an insurer asking about a claim" }
    #   scores  :severity, "How severe?", cosmetic: "no impact", degraded: "workaround exists", blocking: "no workaround"
    #   scores  :priority, "How urgent?", { "can wait" => 10, "today" => 20, "now" => 30 }   # integer column: explicit indexes
    #   scores  :severity, "How severe?", Severity        # an S1::Scale as a value: Severity = S1.scale("cosmetic", "degraded", "blocking")
    #   choice_enum :status, "What is the sender reporting?", delivered: "Handed over", attempted: "Tried, no one there"
    #   score_enum  :grade,  "How good?", poor: 0, fair: 1, good: 2
    #
    # Options on every macro: as: (the form), given: (a lens: a Proc instance_exec'd on the
    # record, a method name, or a Hash), threshold: (judges only), provider:, model:,
    # measure_on: (a lifecycle name, an attribute or list of them, or a Proc) with if: /
    # unless: / on:, after: (measured in a later stage, the named fields' collapses in its
    # lens), siblings: (false, or { probability: :column, … } over the <name>_<part> columns
    # found by convention, written beside the collapse), scale_methods: false (no generated
    # scale surface — s1_scale_methods!), metadata: (labels on the Request for the
    # program — request.metadata in an ask.s1 subscriber; a call's merges over it).
    # Precedence: call-site > field > declared default (measured_against / :default / config).
    module Declarations
      OPTIONS = %i[as given threshold provider model measure_on if unless on after siblings scale_methods metadata].freeze
      ENUM_OPTIONS = %i[values prefix suffix scopes default validate instance_methods].freeze
      SCALE_OPTIONS = %i[categories choices criteria levels indexes].freeze
      # Options whose value is never text: a String or an { is:, not: } under one of these is a label in the wrong place.
      NEVER_TEXT = %i[on if unless after siblings given values scopes validate instance_methods metadata].freeze
      # Options whose value may be text: beside keyword labels they are ambiguous, and refused.
      MAYBE_TEXT = %i[model provider default prefix suffix].freeze
      MACRO = { noul: "judges", choice: "chooses", score: "scores" }.freeze
      VERB = { noul: "judge", choice: "choose", score: "score" }.freeze
      SCALE_WORD = { choice: "categories", score: "levels" }.freeze
      UNREADABLE = { score: "the expectation, not the level; add an s1_answers column",
                     noul: "the mass, not the verdict; declare threshold: on it, or add an s1_answers column" }.freeze
      # The scale words each macro takes; another macro's word is refused, not read as a label.
      SCALE_WORDS = { noul: %i[criteria], choice: %i[categories choices criteria], score: %i[levels criteria indexes] }.freeze
      OWNER_OF = { categories: :choice, choices: :choice, levels: :score, indexes: :score }.freeze
      FIXED = %i[as provider model].freeze
      COLUMNS = { noul: %i[boolean float decimal], choice: %i[string text], score: %i[integer float decimal string text] }.freeze
      SIBLINGS = { probability: %i[float decimal], expectation: %i[float decimal], confidence: %i[float decimal],
                   index: %i[integer], probabilities: %i[json jsonb] }.freeze
      SIBLING_KINDS = { probability: %i[noul], expectation: %i[score], index: %i[score], confidence: %i[choice score],
                        probabilities: %i[noul choice score] }.freeze
      KEYS = %i[kind question scale levels indexes categories criteria as given threshold provider model measure_on conditions after
                siblings dynamic metadata].freeze
      RANK = { at_least: :>=, at_most: :<=, above: :>, below: :< }.freeze
      CONNECTION_ERRORS = [ActiveRecord::ConnectionNotEstablished, ActiveRecord::NoDatabaseError, ActiveRecord::StatementInvalid].freeze

      # How the record is measurable, under a name: the form.
      #   measurable_as(:review) { { transcript: transcript, preferences: firm.preferences } }
      def measurable_as(name = :default, &)
        s1_states << name unless s1_states.include?(name)
        define_method(:"s1_state_#{name}", &)
      end
      alias s1_state measurable_as

      # The model's default lens: what every measurement is judged against, unless
      # a field or a call says otherwise. Evaluated per record, like a form.
      #   measured_against { { policy: store.refund_policy } }
      def measured_against(&block)
        define_method(:s1_lens) { instance_exec(&block).to_h }
      end
      alias measured_given measured_against

      def s1_states = @s1_states ||= (superclass.respond_to?(:s1_states) ? superclass.s1_states.dup : [])

      # What the default form leaves out when none is declared — never evidence: the key, the
      # timestamps, the audit, every measured column and its siblings.
      def s1_omitted
        siblings = s1_registry.values.flat_map { |field| field[:siblings].is_a?(Hash) ? field[:siblings].values : [] }
        [primary_key, *OWN_WRITE, *s1_registry.keys, *siblings].compact.map(&:to_s).uniq
      end

      # The columns the default form renders when none is declared: s1_plan prints them.
      def s1_default_columns = column_names - s1_omitted

      # A dichotomous question on a boolean (stores the collapse) or float (stores the mass)
      # column. true: / false: clarify the scale — a String, or Strings joined with "; ".
      def judges(name, question, criteria: nil, **options)
        clarification = Declarations.noul_criteria(options.extract!(:true, :false))
        criteria = Declarations.once("#{self}: #{name.inspect}", criteria: criteria, "true:/false:": clarification)
        s1_unknown!(name, :noul, options)
        s1_collision!(name, :noul, options, false)
        s1_noul_criteria!(name, criteria)
        s1_declare(name, :noul, question, criteria: criteria, **options)
      end
      alias noul_field judges

      # A nominal question on a string / text / enum column. The categories, once: bare
      # labels, label => description, label => { is:, not: }, a nominal S1::Scale, or
      # categories: (a Hash, an Array, a Scale, or a Proc / method name evaluated on the
      # record; choices: and criteria: — the wire word — spell it too). With none, the enum's keys.
      def chooses(name, question, *labels, **options)
        s1_scale_word!(name, :choice, options)
        categories = Declarations.once("#{self}: #{name.inspect}", **options.extract!(:categories, :choices, :criteria))
        categories = labels.shift if categories.nil? && labels.first.is_a?(S1::Scale)
        inline = options.extract!(*(options.keys - OPTIONS))
        s1_collision!(name, :choice, options, inline.any?)
        scale = categories if categories.is_a?(S1::Scale)
        categories = scale.dynamic? ? scale.source : scale.definitions if scale
        categories = Declarations.categories("#{self}: #{name.inspect}", labels, categories, inline)
        s1_dichotomous!(name, :choice, categories.is_a?(Hash) ? categories.keys : nil)
        s1_declare(name, :choice, question, scale: scale, categories: categories, **options)
      end
      alias choice_field chooses

      # An ordinal question. The levels, worst → best, once: positional labels, one
      # { label => integer } Hash (the integer stored on an integer column), label =>
      # description keywords (the description is shown, the label stored), an ordinal
      # S1::Scale (its definitions shown, when it has them), or levels: (a list, a Hash, a
      # Scale, or a Proc / method name evaluated on the record; criteria: — the wire word —
      # spells it too). indexes: gives an integer column's stored value per label.
      def scores(name, question, *scale, indexes: nil, **options)
        s1_scale_word!(name, :score, options)
        levels = Declarations.once("#{self}: #{name.inspect}", **options.extract!(:levels, :criteria))
        inline = options.extract!(*(options.keys - OPTIONS))
        s1_collision!(name, :score, options, inline.any?)
        levels, indexes, shown, given = Declarations.score_scale("#{self}: #{name.inspect}", scale, levels, indexes, inline)
        s1_dichotomous!(name, :score, levels.is_a?(Array) ? levels : nil)
        s1_declare(name, :score, question, scale: given, levels: levels, indexes: indexes, criteria: shown, **options)
        s1_index_type!(name) if indexes && !defined_enums.key?(name.to_s)
        name.to_sym
      end
      alias score_field scores

      # The resolving form: the kind follows the declaration's shape, then the column —
      # an S1::Scale by its `ordered` (a dynamic one that never said, by the column); levels or indexes →
      # scores; categories, a description hash or an enum → chooses; true: / false:, or a boolean / float
      # column → judges; an integer column → scores.
      # criteria: resolves by its shape: { true:, false: } → judges, a list → scores, a Hash → chooses.
      def measured_field(name, question, *args, **options)
        shape = options.except(*OPTIONS)
        criteria = shape[:criteria]
        given = args.first.is_a?(S1::Scale) ? args.first : criteria
        kind = if given.is_a?(S1::Scale) then { true => :score, false => :choice }.fetch(given.ordered) { s1_column_kind(name) }
               elsif args.any? || shape.key?(:levels) || shape.key?(:indexes) || criteria.is_a?(Array) then :score
               elsif shape.key?(:true) || shape.key?(:false) || Declarations.noul_shaped?(criteria) then :noul
               elsif shape.any? then :choice
               else s1_column_kind(name)
               end
        public_send(MACRO.fetch(kind), name, question, *args, **options)
      end
      alias s1_field measured_field
      alias measured_attribute measured_field
      alias measurable_field measured_field

      # A Rails enum that is also a chooses: the question, and a description per category —
      # keywords, or categories: { label => description }. String-backed unless values: says
      # otherwise; the enum's own keywords pass through. With just a name, the descriptions.
      # With descriptions and no question, the enum and its descriptions alone — not a measured
      # field, so a block's `q.choose :status, "Which?"` borrows them and verify! has nothing to pass.
      def choice_enum(name, question = nil, categories: nil, **descriptions)
        if question.nil? && descriptions.empty? && categories.nil?
          return s1_enums.fetch(name.to_sym) { raise ArgumentError, "#{self} has no choice_enum #{name.inspect}" }
        end

        options = descriptions.extract!(*OPTIONS)
        enum_options = descriptions.extract!(*ENUM_OPTIONS)
        s1_scale_word!(name, :choice, descriptions)
        s1_collision!(name, :choice, options.merge(enum_options), descriptions.any?)
        descriptions = s1_declare_enum(name, s1_enum_categories(name, categories, descriptions), enum_options)
        return chooses(name, question, categories: descriptions, **options) if question
        return name.to_sym if options.empty?

        raise ArgumentError, "#{self}: choice_enum #{name.inspect} takes #{options.keys.map { |k| "#{k}:" }.join(", ")} beside a question; " \
                             "with no question it is an enum with descriptions, not a measured field"
      end
      alias measured_enum choice_enum
      alias s1_enum choice_enum

      # The Rails enum under a choice_enum, and its descriptions in s1_enums.
      def s1_declare_enum(name, descriptions, enum_options)
        enum(name, s1_enum_values(name, enum_options.delete(:values), descriptions.keys), **enum_options)
        s1_enums[name.to_sym] = descriptions.to_h { |label, text| [label.to_sym, Declarations.description(text)] }.freeze
        descriptions
      end

      # A Rails enum whose integers are a score's stored indexes: the enum, and scores with
      # explicit indexes. The labels order by their integers.
      def score_enum(name, question, **mapping)
        options = mapping.extract!(*OPTIONS)
        enum_options = mapping.extract!(*(ENUM_OPTIONS - [:values]))
        s1_scale_word!(name, :score, mapping)
        s1_collision!(name, :score, options.merge(enum_options), false) # label => Integer is never text
        unless mapping.size >= 2 && mapping.values.all?(Integer)
          raise ArgumentError, "#{self}: score_enum #{name.inspect} takes label => Integer pairs (got #{mapping.inspect})"
        end

        enum(name, mapping, **enum_options)
        scores(name, question, mapping, **options)
      end
      alias measured_score_enum score_enum

      # When a field is measured: a lifecycle name (:validation is synchronous — assign_measure;
      # :create / :save / :update enqueue after commit), an attribute or list of them (after
      # commit, when any changed), or a Proc (after commit, when it is true). Fields on the same
      # trigger measure together. A sequenced field joins its predecessor's trigger — the same
      # spelling of measure_on:, declared on the predecessor first — and its own if: / unless:
      # are read when its stage runs. The measurement's own write never re-enqueues.
      def s1_measure_on(name, measure_on: nil, after: nil, **conditions)
        s1_triggers.each_value { |list| list.delete(name) }
        s1_triggers.delete_if { |_, list| list.empty? }
        return s1_conditions_without_trigger!(name, after, conditions) unless measure_on

        hook, watch = s1_trigger(name, measure_on)
        return s1_join_trigger(name, after, measure_on, hook, watch, conditions) if after

        hook, callback = s1_hook_for(name, measure_on, hook, conditions)
        key = [hook, callback, watch]
        (s1_triggers[key] ||= []) << name
        s1_hook!(key, hook, callback, watch)
      end

      # The hook and what it watches: [hook, nil] for a lifecycle name, [:after_save_commit, [attributes]]
      # or [:after_save_commit, proc] otherwise. The four lifecycle names are reserved; anything else is
      # an attribute. A list is a set: `%i[body plan]` and `%i[plan body]` are one trigger.
      def s1_trigger(name, measure_on)
        case measure_on
        when Proc then [:after_save_commit, measure_on]
        when Symbol, String, Array
          return [MEASURE_ON[measure_on.to_sym], nil] if !measure_on.is_a?(Array) && MEASURE_ON.key?(measure_on.to_sym)

          attributes = Array(measure_on).map(&:to_s).sort
          attributes.each { |attribute| s1_attribute!(name, attribute) }
          [:after_save_commit, attributes]
        else raise ArgumentError, "#{self}: #{name.inspect} measure_on: is a lifecycle name #{MEASURE_ON.keys.inspect}, an attribute " \
                                  "name (or a list), or a Proc (got #{measure_on.inspect})"
        end
      end

      def s1_attribute!(name, attribute)
        return if !s1_schema_known? || attribute_names.include?(attribute)

        raise ArgumentError, "#{self}: #{name.inspect} measure_on: #{attribute.to_sym.inspect} is not an attribute of #{self}"
      end

      # Whether the schema can be read now; a declaration that needs it defers to verify! otherwise.
      def s1_schema_known?
        table_exists?
      rescue *CONNECTION_ERRORS
        false
      end

      # key => [fields], the key being [hook, callback options, watched attributes or Proc]. A subclass
      # gets its own lists (the callbacks read them at run time), so a subclass's field never leaks up.
      def s1_triggers = @s1_triggers ||= (superclass.respond_to?(:s1_triggers) ? superclass.s1_triggers.transform_values(&:dup) : {})
      def s1_hooked = @s1_hooked ||= (superclass.respond_to?(:s1_hooked) ? superclass.s1_hooked.dup : [])
      def s1_enums = @s1_enums ||= (superclass.respond_to?(:s1_enums) ? superclass.s1_enums.dup : {})
      # field => the names s1_scale_methods! defined for it, on this class or one above it.
      def s1_generated = @s1_generated ||= (superclass.respond_to?(:s1_generated) ? superclass.s1_generated.dup : {})

      # The declared question per field — the concept alone. s1_questions is the old name.
      def s1_instructions = @s1_instructions ||= (superclass.respond_to?(:s1_instructions) ? superclass.s1_instructions.dup : {})
      alias s1_questions s1_instructions

      # The registry, frozen: name => { kind:, question:, scale: (the S1::Scale — dynamic, holding its source, when the
      # field is), levels:, indexes:, categories:, criteria:, as:, given:, threshold:, provider:, model:, measure_on:,
      # conditions:, after:, siblings:, dynamic: } (absent keys omitted).
      def s1_fields = @s1_fields ||= s1_registry.dup.freeze
      def s1_registry = @s1_registry ||= (superclass.respond_to?(:s1_registry) ? superclass.s1_registry.dup : {})

      # A field's kind by its wire name (noul / choice / score): declared, else inferred from the column.
      def s1_kind(name) = s1_registry.dig(name.to_sym, :kind) || s1_column_kind(name)

      # The kind a column alone implies: an enum → choice; boolean, float, decimal → noul;
      # integer → score; string, text → choice; anything else needs a macro.
      def s1_column_kind(name)
        return :choice if s1_enums.key?(name.to_sym) || defined_enums.key?(name.to_s)

        type = s1_column_type(name)
        case type
        when :boolean, :float, :decimal then :noul
        when :integer then :score
        when :string, :text then :choice
        else
          raise ArgumentError, "#{self} cannot tell how to measure #{name.inspect} (column type #{type.inspect}): " \
                               "declare it with judges, chooses or scores"
        end
      end

      # The call plan for these fields (all, by default): stages by after:, batches by
      # form, lens, provider and model. `fixed` are call-site settings (as:, provider:, model:)
      # that override the fields'; a call-site lens needs the record, so it is not one here.
      def s1_plan(*names, **fixed)
        stray = fixed.keys - FIXED
        raise ArgumentError, "#{self}.s1_plan takes #{FIXED.map { |k| "#{k}:" }.join(", ")} (got #{stray.inspect})" if stray.any?

        unknown = names.map(&:to_sym) - s1_registry.keys
        raise ArgumentError, "#{self}.s1_plan: #{unknown.inspect} are not measured fields" if unknown.any?

        Measurable::Plan.new(self, names.presence || s1_registry.keys, fixed)
      end

      # Categories for a choose named after an enum: choice_enum descriptions, else the
      # plain enum's keys. Nil when there is no such enum, unless required.
      def s1_categories(name, required: false)
        s1_enums[name.to_sym] || defined_enums[name.to_s]&.keys&.to_h { |k| [k.to_sym, nil] } ||
          (raise ArgumentError, "#{self} has no s1_enum or enum #{name.inspect}" if required)
      end
      alias s1_choices s1_categories

      # A chooses field's categories for this record, { label => description }: static, or the dynamic scale evaluated.
      def s1_categories_for(name, record)
        value = s1_registry.dig(name.to_sym, :categories)
        return value unless value.is_a?(Proc) || value.is_a?(Symbol)

        Declarations.categories("#{self}: #{name.inspect}", [], s1_evaluate_scale(name, value, record), {})
      end

      # A scores field's scale for this record, [labels, shown]: the labels stored, the texts the model sees.
      def s1_levels_for(name, record)
        field = s1_registry[name.to_sym]
        return unless field && field[:kind] == :score

        levels = field[:levels]
        return [levels, field[:criteria] || levels] unless levels.is_a?(Proc) || levels.is_a?(Symbol)

        labels, shown, = Declarations.score_parts("#{self}: #{name.inspect}", s1_evaluate_scale(name, levels, record))
        [labels, shown || labels]
      end

      # A field's S1::Scale as declared — dynamic until resolved on a record (s1_scale_for). Model.<name>_scale reads it.
      def s1_scale(name)
        s1_registry.fetch(name.to_sym) { raise ArgumentError, "#{self}: #{name.to_sym.inspect} is not a measured field" }
                   .fetch(:scale) { raise ArgumentError, "#{self}: #{name.to_sym.inspect} has no scale (a judge, or an enum declared after it)" }
      end

      # A field's scale for this record: the declared one, or the dynamic one evaluated on the record — with the
      # descriptions it returned, under the declared scale's name.
      def s1_scale_for(name, record)
        field = s1_registry.fetch(name.to_sym, {})
        return s1_scale(name) unless field[:dynamic]

        labels, shown = s1_levels_for(name, record) if field[:kind] == :score
        source = labels&.zip(shown)&.to_h { |label, text| [label, (text unless text == label)] } || s1_categories_for(name, record)
        S1::Scale.new(source, ordered: field[:kind] == :score, name: field[:scale].name)
      end

      # The rows whose score column holds a level `compare` (:>=, :<=, :>, :<) the category: by the labels it
      # stores, or the indexes an integer column keeps; a float or decimal column keeps the expectation, not a level.
      def s1_where_rank(name, compare, category)
        scale = s1_scale(name)
        type = s1_column_type(name)
        raise ArgumentError, "#{self}: #{name.inspect} keeps the expectation on a #{type} column; its level is the audit's" if %i[float decimal].include?(type)

        at = scale.fetch(category)
        levels = scale.select { |level| level.public_send(compare, at) }
        integer = type == :integer && !defined_enums.key?(name.to_s)
        where(name => levels.map { |level| integer ? s1_registry.dig(name.to_sym, :indexes)&.[](level.position) || level.position : level.to_str })
      end

      # A field's declared lens for this record, as a Hash with Symbol keys; a Proc value is evaluated on the record.
      def s1_lens_for(name, record)
        value = s1_registry.dig(name.to_sym, :given)
        return {} if value.nil?

        lens = value.is_a?(Proc) || value.is_a?(Symbol) ? s1_evaluate(value, record) : value
        raise ArgumentError, "#{self}: #{name.inspect} given: #{value.inspect} returned #{lens.inspect}; a lens is a Hash" unless lens.is_a?(Hash)

        s1_evaluated_lens(lens, record)
      end

      # A lens as sent: Symbol keys, and a Proc value evaluated on the record (a lens is evidence, and a Proc is not).
      def s1_evaluated_lens(lens, record)
        lens.to_h { |k, v| [k.to_sym, v.is_a?(Proc) ? s1_evaluate(v, record) : v] }
      end

      # A method name, or a Proc instance_exec'd on the record — handed the record too when it takes one.
      def s1_evaluate(value, record)
        return record.send(value) if value.is_a?(Symbol)

        value.arity.zero? ? record.instance_exec(&value) : record.instance_exec(record, &value)
      end

      # A dynamic scale evaluated on the record: at least 2 labels, as a list, label => description, or an S1::Scale
      # of the field's kind.
      def s1_evaluate_scale(name, value, record)
        scale = s1_evaluate(value, record)
        scale = s1_scale_kind!(name, s1_registry.dig(name.to_sym, :kind), scale.resolve(record)) if scale.is_a?(S1::Scale)
        scale = scale.definitions.values.any? ? scale.definitions : scale.labels if scale.is_a?(S1::Scale)
        return scale if (scale.is_a?(Array) || scale.is_a?(Hash)) && scale.size >= 2

        raise S1::ValidationError, "#{self}: #{name.inspect} dynamic scale returned #{scale.inspect}; " \
                                   "a scale is at least 2 labels — a list, or { label => description }"
      end

      # The category a measured column holds, as the collapse named it: a boolean (a numeric noul
      # column at the threshold the measurement carries — the call's, else the audit's, else the
      # field's; with none the column names no category and the read raises), a label (an integer
      # score column through its indexes or its positions; a float one keeps the expectation and
      # has no category to read — that comes from the audit, or the read raises).
      def s1_collapsed(name, record, threshold: nil)
        value = record.public_send(name)
        field = s1_registry.fetch(name.to_sym, {})
        case field[:kind]
        when :noul then value.is_a?(Numeric) ? value >= s1_threshold_of(name, record, field, threshold, value) : value
        when :score then value.is_a?(Numeric) ? s1_level_of(name, record, field, value) : value
        else value
        end
      end

      # The threshold a numeric noul column collapses at: the call's, the one stamped in the audit,
      # the field's. The config's is never read here — a float keeps the distribution, and only a
      # measurement carries the threshold it was taken under.
      def s1_threshold_of(name, record, field, threshold, value)
        stored = record.s1_answers.to_h.dig(name.to_s, "threshold") if record.has_attribute?(:s1_answers)
        threshold || stored || field[:threshold] ||
          raise(ArgumentError, "#{self}: #{name.inspect} holds #{value.to_f.inspect}, not measured at a threshold; a float or decimal " \
                               "column keeps the distribution — declare threshold: on it, or add an s1_answers column and " \
                               "measure it: update_measure(#{name.inspect})")
      end

      # An integer is an index (declared, else a position); a float or decimal is the expectation,
      # a number that names no level — its category is the audit's, so without one it raises, an
      # ArgumentError like every stored value that names no level.
      def s1_level_of(name, record, field, value)
        labels, = s1_levels_for(name, record)
        unless value.is_a?(Integer)
          stored = record.s1_answers.to_h.dig(name.to_s, "value") if record.has_attribute?(:s1_answers)
          return stored if stored

          raise ArgumentError, "#{self}: #{name.inspect} holds #{value.to_f.inspect}, not measured; a float or decimal column keeps " \
                               "the expectation, not the category — measure it: update_measure(#{name.inspect})"
        end
        unless field[:indexes]
          return labels.fetch(value) do
            raise ArgumentError, "#{self}: #{name.inspect} holds #{value.inspect}, not a position on #{labels.inspect}"
          end
        end

        at = field[:indexes].index(value)
        raise ArgumentError, "#{self}: #{name.inspect} holds #{value.inspect}, not one of its indexes #{field[:indexes].inspect}" unless at

        labels[at]
      end

      # A field's if: / unless:, evaluated on the record as Rails would — a method name, a Proc, or a list.
      def s1_gate?(name, record)
        conditions = s1_registry.dig(name.to_sym, :conditions).to_h
        Array(conditions[:if]).all? { |c| s1_condition(c, record) } && Array(conditions[:unless]).none? { |c| s1_condition(c, record) }
      end

      def s1_condition(condition, record)
        case condition
        when Symbol, String then record.send(condition)
        when Proc then condition.arity.zero? ? record.instance_exec(&condition) : condition.call(record)
        else condition
        end
      end

      # The digest of a field's question as the declaration builds it now — instructions, criteria,
      # the scale as shown and, for a score, the labels stored — for `record` (a dynamic scale needs
      # one and raises without it; a static field needs none).
      def s1_question_digest(name, record = nil)
        if record.nil? && s1_registry.dig(name.to_sym, :dynamic)
          raise ArgumentError, "#{self}: #{name.inspect} has a dynamic scale; s1_question_digest(#{name.inspect}, record) needs the record"
        end

        builder = Measurable::Questions.new(record || new)
        Declarations.digest(builder.field_question(name).to_h.fetch(name.to_sym), builder.labels[name.to_sym])
      end

      # Checks this model's declarations against its schema. Run by S1::Measurable.verify! at boot;
      # call it in a spec to keep it green. Notes what the conventions decided — the columns
      # siblings claim by name, the attributes a model with no form sends.
      def s1_verify_fields!
        @s1_verified = true
        claimed = {}
        s1_registry.each do |name, field|
          raise ArgumentError, "#{self}: measured field #{name.inspect} is not a column" unless column_names.include?(name.to_s)

          s1_verify_question!(name)
          s1_verify_kind!(name, field)
          s1_resolve_siblings!(name, field)
          field = s1_registry[name]
          s1_verify_scale!(name, field)
          s1_verify_options!(name, field)
          s1_verify_claims!(name, claimed)
        end
        s1_verify_generated!
        s1_plan
        s1_note_conventions!
        self
      end

      # A generated scale method redefined below the macro (`def self.severities`) would answer for the scale; refused —
      # as is one that spells an attribute method the schema, read now, gives the record. An enum declared below the
      # macro overwrote the plural: the enum goes above the macro, whose surface is then Rails' plus _scale.
      def s1_verify_generated!
        s1_generated.each do |name, methods|
          methods.each do |m|
            at = s1_generated_owner(m).instance_method(m).source_location
            s1_generated!(name, m, at) unless at&.first == __FILE__
            s1_attribute_method!(name, m) if s1_generated_owner(m) == self
          end
        end
      end

      def s1_generated!(name, method, where)
        raise ArgumentError, "#{self}: #{name.inspect} is an enum declared below its macro; declare the enum above it" if defined_enums.key?(name.to_s)

        raise ArgumentError, "#{self}: #{method} is a scale's generated method, redefined at #{where&.join(":")}"
      end

      # The first measurement of a model verify! never reached (no eager load) verifies it once,
      # so a declaration mistake raises in development too, not only at a production boot.
      def s1_verify_once!
        return if @s1_verified || s1_registry.empty? || !s1_schema_known?

        s1_verify_fields!
      end

      class << self
        # true: / false: as the wire criteria: a String, or Strings joined with "; ".
        def noul_criteria(clarification)
          clarification.compact.transform_values { |v| Array(v).join("; ") }.presence
        end

        # Whether criteria: is a judge's { true:, false: } clarification.
        def noul_shaped?(criteria)
          criteria.is_a?(Hash) && criteria.any? && (criteria.keys.map(&:to_s) - %w[true false]).empty?
        end

        # A judge's threshold: a number in 0..1, or nil.
        def threshold!(owner, threshold)
          return threshold if threshold.nil? || (threshold.is_a?(Numeric) && (0..1).cover?(threshold))

          raise ArgumentError, "#{owner}: threshold: is a number in 0..1 (got #{threshold.inspect})"
        end

        # One value from several spellings of the same option; more than one raises naming them.
        def once(owner, **spellings)
          given = spellings.compact
          return given.values.first if given.size <= 1

          names = given.keys.map { |k| k.to_s.end_with?(":") ? k.to_s : "#{k}:" }
          raise ArgumentError, "#{owner}: #{names.join(" and ")} are one thing; give it once"
        end

        # The callback condition an attribute list or a Proc trigger adds to its hook: any of the
        # attributes changed in the transaction's saves.
        def guard(watch)
          return watch if watch.is_a?(Proc)

          ->(record) { watch.any? { |attribute| record.s1_changed?(attribute) } }
        end

        # A question's identity: SHA-256 of its wire form (type, instructions, criteria / levels as
        # shown) and, when a score stores labels other than the levels it shows, those labels.
        # The question as asked, and a score's stored labels when they differ from what was shown.
        # Never the threshold: that is the collapse's, not the question's — a declaration's threshold
        # changed after the measure reaches the row on remeasure, as it does for a boolean column.
        def digest(question, labels = nil)
          payload = question.to_h
          payload = payload.merge(stores: labels) if labels && labels != Array(payload[:criteria]).map(&:to_s)
          Digest::SHA256.hexdigest(JSON.generate(payload))
        end

        # ≥ 2 labels, none repeated: a scale of one is no judgement, and a repeated label two points at once.
        def distinct!(owner, labels)
          return if labels.nil? || (labels.size >= 2 && labels.uniq.size == labels.size)

          raise ArgumentError, "#{owner}: a scale is at least 2 distinct labels (got #{labels.inspect})"
        end

        # measure_on: as s1_plan prints it.
        def trigger_name(measure_on)
          measure_on.is_a?(Proc) ? "(proc)" : measure_on.inspect
        end

        # Whether an option's value reads as a label's description: a String, or { is:, not: }.
        def text?(value)
          value.is_a?(String) || (value.is_a?(Hash) && value.any? && (value.keys - %i[is not]).empty?)
        end

        # A description as shown: a String (or Strings joined "; "); { is:, not: } renders "…. Not: …".
        def description(value)
          case value
          when nil, String then value
          when Array then value.join("; ")
          when Hash
            stray = value.keys - %i[is not]
            raise ArgumentError, "a description is a String or { is:, not: } (got #{value.inspect})" if stray.any? || value.empty?

            is, no = value.values_at(:is, :not).map { |v| v && Array(v).join("; ") }
            [is, ("Not: #{no}" if no)].compact.join(". ")
          else raise ArgumentError, "a description is a String or { is:, not: } (got #{value.inspect})"
          end
        end

        # The declared categories as { label => description }; a Proc / Symbol is kept, to evaluate per record;
        # nil when none were given (an enum's keys serve at measure time).
        def categories(owner, labels, categories, inline)
          return categories if categories.is_a?(Proc) || categories.is_a?(Symbol)
          raise ArgumentError, "#{owner}: give the categories once — bare labels or keywords, or categories:" if categories && (labels.any? || inline.any?)
          unless categories.nil? || categories.is_a?(Hash) || categories.is_a?(Array)
            raise ArgumentError, "#{owner}: categories: is a Hash, an Array, or a Proc / method name (got #{categories.inspect})"
          end

          list = categories || labels.to_h { |l| [l, nil] }.merge(inline)
          list = list.to_h { |l| [l, nil] } if list.is_a?(Array)
          list = list.to_h.to_h { |label, text| [label.to_sym, description(text)] }.presence
          distinct!(owner, list&.keys)
          list
        end

        # A score's scale as [levels, indexes, shown, the S1::Scale given]: a Proc / Symbol stays dynamic.
        def score_scale(owner, scale, levels, indexes, inline)
          source = score_source(owner, scale, levels, inline)
          given = source if source.is_a?(S1::Scale)
          source = if given.nil? then source
                   elsif given.dynamic? then given.source
                   elsif given.definitions.values.any? then given.labels.zip(given.texts).to_h
                   else given.labels
                   end
          if source.is_a?(Proc) || source.is_a?(Symbol)
            raise ArgumentError, "#{owner}: a dynamic scale takes no indexes" if indexes

            return [source, nil, nil, given]
          end

          labels, shown, mapping = score_parts(owner, source) if source
          distinct!(owner, labels)
          raise ArgumentError, "#{owner}: { label => integer } already gives the indexes" if mapping && indexes

          [labels, mapping || (indexes && index_mapping(owner, labels, indexes)), shown, given]
        end

        # The one spelling the levels came in: positional labels, one Hash or Scale, levels:, or keywords.
        def score_source(owner, scale, levels, inline)
          if [scale.any?, !levels.nil?, inline.any?].count(true) > 1
            raise ArgumentError, "#{owner}: give the levels once — positional, levels:, or label => description"
          end
          if scale.size > 1 && scale.any? { |s| s.is_a?(Hash) || s.is_a?(S1::Scale) }
            raise ArgumentError, "#{owner}: levels are positional labels, or one { label => integer / description } Hash or Scale (got #{scale.inspect})"
          end

          scale.one? && (scale.first.is_a?(Hash) || scale.first.is_a?(S1::Scale)) ? scale.first : (scale.presence || levels || inline.presence)
        end

        # [labels, shown, indexes] from a list, a { label => integer } Hash, or a { label => description } Hash.
        def score_parts(owner, source)
          case source
          when Array then [source.map(&:to_s), nil, nil]
          when Hash
            return [source.keys.map(&:to_s), source.map { |l, d| description(d) || l.to_s }, nil] unless source.values.all?(Integer)

            ordered = source.sort_by { |_, i| i }
            raise ArgumentError, "#{owner} indexes must be distinct integers" unless ordered.map(&:last).uniq.size == ordered.size

            [ordered.map { |l, _| l.to_s }, nil, ordered.map(&:last)]
          else raise ArgumentError, "#{owner}: levels are a list, a { label => integer } Hash, or a { label => description } Hash"
          end
        end

        def index_mapping(owner, labels, indexes)
          map = indexes.to_h.transform_keys(&:to_s)
          unless labels && map.keys.sort == labels.sort && map.values.all?(Integer)
            raise ArgumentError, "#{owner}: indexes: must give one integer per level #{labels.inspect} (got #{map.keys.inspect})"
          end

          ints = labels.map { |l| map[l] }
          raise ArgumentError, "#{owner}: indexes must increase with the levels #{labels.inspect}" unless ints.each_cons(2).all? { |a, b| a < b }

          ints
        end

        # The macro a column asks for, for error messages.
        def macro_for(type, enum)
          return "chooses (or score_enum)" if enum

          case type
          when :boolean then "judges"
          when :float, :decimal then "judges or scores"
          when :integer then "scores with indexes"
          when :string, :text then "chooses or scores"
          else "a column of another type"
          end
        end
      end

      private

      def s1_declare(name, kind, question, **entry)
        name = name.to_sym
        s1_question!(name, kind, question)
        conditions = entry.extract!(:if, :unless, :on)
        generate = entry.delete(:scale_methods) != false
        s1_check!(name, kind, entry)
        dynamic = s1_dynamic?(name, entry)
        entry[:scale] = s1_scale_of(name, kind, entry)
        s1_measure_on(name, measure_on: entry[:measure_on], after: entry[:after], **conditions)
        s1_instructions[name] = question if question
        entry = { kind: kind, question: question, **entry, conditions: conditions.presence, dynamic: (true if dynamic),
                  siblings: s1_siblings(name, kind, entry[:siblings]) }
        s1_ungenerate!(name)
        s1_scale_methods!(name, kind, entry[:scale]) if generate && kind != :noul && !dynamic && entry[:scale]
        s1_register(name, entry)
      end

      # The field's S1::Scale: the one given, of the macro's kind, else built from the parts — the
      # levels with their descriptions, the categories, an enum's keys, a dynamic source.
      def s1_scale_of(name, kind, entry)
        return s1_scale_kind!(name, kind, entry[:scale]) if entry[:scale]

        source = kind == :score ? entry[:levels] : entry[:categories] || s1_categories(name)
        source = source.zip(entry[:criteria]).to_h if source.is_a?(Array) && entry[:criteria]
        S1::Scale.new(source, ordered: kind == :score, name: "#{self}##{name}") unless source.nil?
      end

      # A given Scale is the macro's kind: an ordinal one under scores, a nominal one under chooses. A dynamic Scale
      # takes the macro's kind when it never said, and the field's name when it has none, so what it resolves to is
      # checked against the kind and named in messages.
      def s1_scale_kind!(name, kind, scale)
        ordered = kind == :score
        unless [ordered, nil].include?(scale.ordered)
          raise ArgumentError, "#{self}: #{MACRO[kind]} #{name.inspect} takes #{ordered ? "an ordinal" : "a nominal"} scale (got #{scale.inspect})"
        end
        return scale unless scale.dynamic?

        S1::Scale.new(scale.source, ordered: ordered, name: scale.name || "#{self}##{name}")
      end

      # The enum-shaped surface of a static scale, each reading the registry when called: Model.<names> and
      # Model.<name>_scale (the Scale), record.<name>_<key>? per category, Model.<name>_at_least / _at_most /
      # _above / _below on an ordinal, Model.with_<name> on a nominal. An enum column keeps Rails' own —
      # the mapping, the predicates, the scopes — and gets _scale (and the rank scopes on a score_enum).
      # A name already in use raises; a redeclaration drops the names generated for the field first.
      def s1_scale_methods!(name, kind, scale)
        enum = s1_enums.key?(name) || defined_enums.key?(name.to_s)
        s1_generate!(name, singleton_class, :"#{name}_scale") { s1_scale(name) }
        RANK.each { |suffix, compare| s1_generate!(name, singleton_class, :"#{name}_#{suffix}") { |c| s1_where_rank(name, compare, c) } } if kind == :score
        return if enum

        s1_generate!(name, singleton_class, name.to_s.pluralize.to_sym) { s1_scale(name) }
        s1_generate!(name, singleton_class, :"with_#{name}") { |c| where(name => s1_scale(name).fetch(c).to_s) } if kind == :choice
        s1_predicates!(name, scale)
      end

      def s1_predicates!(name, scale)
        scale.keys.each_pair { |key, label| s1_generate!(name, self, :"#{name}_#{key}?") { s1_category(name)&.to_s == label } }
      end

      # Defines one generated method on `owner` (the singleton class, or the model): a method of that name
      # already there — the model's own, Rails', s1's, another field's — would be overwritten, and raises
      # instead; so would an attribute method Rails defines lazily (`<column>?`, `<column>_changed?`).
      def s1_generate!(name, owner, method, &)
        if owner.method_defined?(method) || owner.private_method_defined?(method)
          raise ArgumentError, "#{self}: #{name.inspect}'s scale would define #{method}, which would overwrite #{self}'s own #{method}; " \
                               "rename it, or scale_methods: false"
        end

        s1_attribute_method!(name, method) if owner == self
        (s1_generated[name] ||= []) << method
        owner.define_method(method, &)
      end

      # A generated predicate spelling an attribute method over a column of the model (when the schema can be read).
      def s1_attribute_method!(name, method)
        return unless s1_schema_known?

        column = attribute_method_patterns.filter_map { |p| p.match(method.to_s)&.attr_name }.find { |a| attribute_names.include?(a) }
        return unless column

        raise ArgumentError, "#{self}: #{name.inspect}'s scale would define #{method}, which is an attribute method of #{column.inspect}; " \
                             "rename the label, or scale_methods: false"
      end

      def s1_generated_owner(method) = singleton_class.method_defined?(method) ? singleton_class : self

      # A redeclaration drops the methods generated for the field on this class; a method of that name that is
      # not s1's stays, for s1_generate! to refuse.
      def s1_ungenerate!(name)
        s1_generated.delete(name).to_a.each do |m|
          owner = s1_generated_owner(m)
          owner.undef_method(m) if owner.instance_method(m).source_location&.first == __FILE__
        end
      end

      def s1_register(name, entry)
        s1_registry[name] = KEYS.to_h { |k| [k, entry[k]] }.compact.freeze
        @s1_fields = nil
        Measurable::Plan.stage(self, s1_registry.keys) if entry[:after] # a cycle raises here, not at boot
        name
      end

      # A label named like an option would be taken as the option, silently: under an option
      # that never takes text it is refused outright; under one that may (model:, provider:, an
      # enum's default: / prefix: / suffix:) it is refused beside keyword labels, where it is
      # ambiguous. given: / siblings: / after: are checked for shape first, so the raise names
      # theirs; the scale hint names only a macro that has one.
      def s1_collision!(name, kind, options, keyword_labels)
        s1_check_shapes!(name, options)
        options.each do |key, value|
          next unless Declarations.text?(value)

          if NEVER_TEXT.include?(key)
            raise ArgumentError, "#{self}: #{MACRO[kind]} #{name.inspect}: #{key}: #{value.inspect} reads as a label named #{key.inspect}, " \
                                 "which collides with the option #{key}:#{s1_scale_hint(kind, key)}"
          elsif MAYBE_TEXT.include?(key) && keyword_labels
            raise ArgumentError, "#{self}: #{MACRO[kind]} #{name.inspect}: #{key}: #{value.inspect} beside keyword labels is ambiguous — " \
                                 "a #{key} or a label?; give the scale with #{SCALE_WORD[kind]}: { … }, or #{key}: as a Symbol"
          end
        end
      end

      def s1_scale_hint(kind, key)
        return "" if kind == :noul || %i[given after siblings].include?(key)

        "; give the scale with #{SCALE_WORD[kind]}: { #{key}: … }"
      end

      # A scale of exactly { true, false } is the dichotomous one, and chooses / scores would store
      # it as text with no threshold: it is refused naming judges.
      def s1_dichotomous!(name, kind, labels)
        return unless labels && labels.map(&:to_s).sort == %w[false true]

        raise ArgumentError, "#{self}: #{MACRO[kind]} #{name.inspect} over { true, false } is a dichotomous scale; declare it with judges"
      end

      # Another macro's scale word (levels: on chooses, categories: on scores) is refused, naming both macros.
      def s1_scale_word!(name, kind, options)
        stray = options.keys & (SCALE_OPTIONS - SCALE_WORDS[kind])
        return if stray.empty?

        raise ArgumentError, "#{self}: #{stray.first}: is a #{MACRO[OWNER_OF[stray.first]]}' scale; #{name.inspect} is declared with #{MACRO[kind]}"
      end

      # The options whose value has one shape, checked before anything reads them as a label.
      def s1_check_shapes!(name, options)
        given, siblings, after = options.values_at(:given, :siblings, :after)
        unless [NilClass, Proc, Symbol, Hash].any? { |c| given.is_a?(c) }
          raise ArgumentError, "#{self}: #{name.inspect} given: is a Proc, a method name or a Hash (got #{given.inspect})"
        end
        unless [NilClass, FalseClass, Hash].any? { |c| siblings.is_a?(c) }
          raise ArgumentError, "#{self}: #{name.inspect} siblings: is false or { part => column } (got #{siblings.inspect})"
        end
        return if after.nil? || Array(after).all?(Symbol)

        raise ArgumentError, "#{self}: #{name.inspect} after: names measured fields — a Symbol, or a list of them (got #{after.inspect})"
      end

      # judges' criteria: is the wire form — { true:, false: }, nothing else — checked here, not on the first measure.
      def s1_noul_criteria!(name, criteria)
        unless criteria.nil? || criteria.is_a?(Hash)
          raise ArgumentError,
                "#{self}: judges #{name.inspect} criteria: is { true:, false: } (got #{criteria.inspect})"
        end

        S1::Question.normalize_noul_criteria(criteria)
      rescue S1::ValidationError => e
        raise ArgumentError, "#{self}: judges #{name.inspect} criteria: #{e.message}; it takes true: / false:"
      end

      # choice_enum's categories: keywords, or categories: { label => description } (a list: no
      # descriptions) — one or the other.
      def s1_enum_categories(name, categories, descriptions)
        raise ArgumentError, "#{self}: choice_enum #{name.inspect}: give the categories once — keywords, or categories:" if categories && descriptions.any?

        categories = s1_scale_kind!(name, :choice, categories).definitions.transform_keys(&:to_sym) if categories.is_a?(S1::Scale) && !categories.dynamic?
        return descriptions if categories.nil?
        return categories.to_h { |label| [label, nil] } if categories.is_a?(Array)
        return categories.to_h if categories.is_a?(Hash)

        raise ArgumentError, "#{self}: #{name.inspect} has a dynamic scale on an enum column: the enum is the scale"
      end

      # if: / unless: / on: with nothing to attach to would sit in the registry unread.
      def s1_conditions_without_trigger!(name, after, conditions)
        return if conditions.empty?
        return if after && !conditions.key?(:on)

        raise ArgumentError, "#{self}: #{name.inspect} #{conditions.keys.map { |k| "#{k}:" }.join(" / ")} needs measure_on: " \
                             "(a sequenced field's if: / unless: gate its stage; on: rides on a trigger)"
      end

      # on: with an after_*_commit hook: Rails' shorthands overwrite it, so the plain after_commit
      # takes it; :create / :update already say when.
      def s1_hook_for(name, measure_on, hook, conditions)
        return [hook, conditions] unless conditions.key?(:on) && hook != :before_validation
        if %i[after_create_commit after_update_commit].include?(hook)
          raise ArgumentError, "#{self}: #{name.inspect} measure_on: #{measure_on.inspect} already says when; drop on:"
        end

        [:after_commit, conditions]
      end

      # A sequenced field is enqueued with its predecessors, so it joins their trigger: the
      # predecessors are declared first, with the same measure_on:, on one trigger.
      def s1_join_trigger(name, after, measure_on, hook, watch, conditions)
        raise ArgumentError, "#{self}: #{name.inspect} shares its predecessors' trigger #{after.inspect}; on: goes on theirs" if conditions.key?(:on)

        keys = after.map { |dep| s1_dep_trigger!(name, dep, measure_on, hook, watch) }.uniq
        raise ArgumentError, "#{self}: #{name.inspect} after: #{after.inspect} are on different triggers; a sequenced field shares one" if keys.size > 1

        s1_triggers[keys.first] << name
      end

      def s1_dep_trigger!(name, dep, measure_on, hook, watch)
        key, = s1_triggers.find { |_, list| list.include?(dep) }
        unless key
          raise ArgumentError, "#{self}: #{name.inspect} after: #{dep.inspect} has no measure_on: trigger to share; declare #{dep.inspect} " \
                               "with measure_on: #{Declarations.trigger_name(measure_on)} first, or drop measure_on: from #{name.inspect} " \
                               "and measure both with update_measure(#{dep.inspect}, #{name.inspect})"
        end

        dep_hook, dep_watch = s1_trigger(dep, s1_registry.dig(dep, :measure_on))
        return key if [dep_hook, dep_watch] == [hook, watch]

        raise ArgumentError, "#{self}: #{name.inspect} measure_on: #{Declarations.trigger_name(measure_on)} differs from #{dep.inspect}'s " \
                             "measure_on: #{Declarations.trigger_name(s1_registry.dig(dep, :measure_on))}; a sequenced field shares its " \
                             "predecessor's spelling"
      end

      # Registers the callback for a trigger key once; it reads the key's field list on the
      # record's class at run time, so a subclass's fields ride its parent's callback.
      def s1_hook!(key, hook, callback, watch)
        return if s1_hooked.include?(key)

        s1_hooked << key
        callback = callback.merge(if: [Declarations.guard(watch), *Array(callback[:if])]) if watch
        if hook == :before_validation
          before_validation(**callback) { s1_assign_trigger!(key) }
        else
          public_send(hook, **callback) { s1_enqueue_trigger!(key) }
        end
      end

      # Whether the scale is a Proc or a method name; on an enum column that is a contradiction, refused here.
      def s1_dynamic?(name, entry)
        dynamic = entry.values_at(:categories, :levels).any? { |v| v.is_a?(Proc) || v.is_a?(Symbol) }
        return dynamic unless dynamic && (s1_enums.key?(name) || defined_enums.key?(name.to_s))

        raise ArgumentError, "#{self}: #{name.inspect} has a dynamic scale on an enum column: the enum is the scale"
      end

      # The registry's siblings: false opts out; otherwise the <name>_<part> columns the schema has
      # (when it can be read now — else at verify!), under an explicit map.
      def s1_siblings(name, kind, given)
        return false if given == false

        explicit = given.to_h.to_h { |part, column| [part.to_sym, column.to_sym] }
        explicit.each_key { |part| s1_sibling_part!(name, kind, part) }
        s1_explicit[name.to_sym] = explicit
        return explicit.presence unless s1_schema_known?

        s1_detected_siblings(name, kind).merge(explicit).presence
      end

      def s1_sibling_part!(name, kind, part)
        kinds = SIBLING_KINDS.fetch(part) do
          raise ArgumentError, "#{self}: #{name.inspect} sibling #{part.inspect} is not a part of a distribution (#{SIBLINGS.keys.inspect})"
        end
        raise ArgumentError, "#{self}: #{name.inspect} has no #{part}: it is a #{kind}" unless kinds.include?(kind)
      end

      def s1_detected_siblings(name, kind)
        SIBLING_KINDS.select { |part, kinds| kinds.include?(kind) && column_names.include?("#{name}_#{part}") }
                     .to_h { |part, _| [part, :"#{name}_#{part}"] }
      end

      # At verify!, with the schema in hand: the convention's columns join the map, and one named
      # for a part the field cannot write — or mapped elsewhere — raises rather than sit unwritten.
      def s1_resolve_siblings!(name, field)
        return if field[:siblings] == false

        field[:siblings].to_h.each { |part, column| s1_verify_sibling!(name, field, part, column) }
        siblings = s1_detected_siblings(name, field[:kind]).merge(field[:siblings].to_h)
        SIBLINGS.each_key { |part| s1_claimed!(name, field, siblings, part) }
        return if siblings == field[:siblings].to_h

        siblings.each { |part, column| s1_verify_sibling!(name, field, part, column) }
        s1_register(name, field.merge(siblings: siblings.presence))
      end

      def s1_claimed!(name, field, siblings, part)
        column = :"#{name}_#{part}"
        return if !column_names.include?(column.to_s) || siblings[part] == column

        why = siblings[part] ? "siblings: maps #{part} to #{siblings[part].inspect}" : "a #{field[:kind]} has no #{part}"
        raise ArgumentError, "#{self}: #{column.inspect} is named as #{name.inspect}'s #{part}, but #{why}; " \
                             "map it, rename it, or opt out with siblings: false"
      end

      def s1_unknown!(name, kind, options)
        extra = options.keys - OPTIONS
        return if extra.empty?

        raise ArgumentError, "#{self}: #{MACRO[kind]} #{name.inspect} has unknown option(s) #{extra.inspect}; " \
                             "it takes true:, false:, #{OPTIONS.map { |o| "#{o}:" }.join(", ")}"
      end

      # A question is a non-blank String or a structured Hash — refused here, not on the first measure.
      def s1_question!(name, kind, question)
        return if (question.is_a?(String) && !question.strip.empty?) || (question.is_a?(Hash) && question.any?)

        raise ArgumentError, "#{self}: #{MACRO[kind]} #{name.inspect} needs a question — a String, or a structured Hash (got #{question.inspect})"
      end

      # Normalizes and checks the options every macro shares (given: / siblings: / after: shapes: s1_check_shapes!).
      def s1_check!(name, kind, entry)
        s1_check_threshold!(name, kind, entry[:threshold])
        s1_check_shapes!(name, entry)
        entry[:as] = entry[:as]&.to_sym
        entry[:after] = Array(entry[:after]).map(&:to_sym).presence
        entry[:metadata] = S1::Metadata.check!(entry[:metadata], "#{self}: #{name.inspect} metadata").presence if entry.key?(:metadata)
      end

      def s1_check_threshold!(name, kind, threshold)
        raise ArgumentError, "#{self}: threshold: is a judge's collapse rule; #{name.inspect} is declared with #{MACRO[kind]}" if threshold && kind != :noul

        Declarations.threshold!("#{self}: #{name.inspect}", threshold)
      end

      def s1_column_type(name)
        type_for_attribute(name.to_s).type
      rescue ActiveRecord::ActiveRecordError
        nil
      end

      # An integer column under indexes: casts a Level, or a label on the scale, to the level's index, so
      # `where(col: Model.cols[:x])` and an assignment land on the stored integer, not the position (Level#to_i).
      def s1_index_type!(name)
        decorate_attributes([name.to_s]) { |_, type| type.type == :integer ? IndexType.new(type, self, name.to_sym) : type }
      end

      class IndexType < DelegateClass(ActiveModel::Type::Value)
        def initialize(subtype, model, name)
          super(subtype)
          @model = model
          @name = name
        end

        def cast(value) = super(index(value))
        def serialize(value) = super(index(value))

        private

        def index(value)
          scale = @model.s1_scale(@name)
          return value unless value.is_a?(S1::Level) || (value.is_a?(String) && scale.include?(value))

          @model.s1_fields.dig(@name, :indexes).fetch(scale.fetch(value).position)
        end
      end

      def s1_verify_kind!(name, field)
        type = type_for_attribute(name.to_s).type
        enum = defined_enums.key?(name.to_s)
        ok = case field[:kind]
             when :choice then enum || COLUMNS[:choice].include?(type)
             else COLUMNS[field[:kind]].include?(type)
             end
        return if ok

        raise ArgumentError, "#{self}: #{name.inspect} is measured as #{field[:kind]} but its column is #{enum ? "an enum" : type}: " \
                             "declare it with #{Declarations.macro_for(type, enum)}"
      end

      def s1_verify_scale!(name, field)
        type = type_for_attribute(name.to_s).type
        enum = defined_enums[name.to_s]
        raise ArgumentError, "#{self}: #{name.inspect} has a dynamic scale on an enum column: the enum is the scale" if enum && field[:dynamic]

        s1_scale_kind!(name, field[:kind], field[:scale]) if field[:scale]
        case field[:kind]
        when :choice then s1_verify_categories!(name, field, enum)
        when :score then s1_verify_levels!(name, field, enum, type)
        end
      end

      def s1_verify_categories!(name, field, enum)
        raise ArgumentError, "#{self}: #{name.inspect} is a chooses with no categories: give them, or declare the enum" unless field[:categories] || enum
        return if field[:dynamic]

        Declarations.distinct!("#{self}: #{name.inspect}", (field[:categories] || enum).keys)
        return unless enum && field[:categories]

        stray = field[:categories].keys.map(&:to_s) - enum.keys
        raise ArgumentError, "#{self}: #{name.inspect} categories #{stray.inspect} are not in the enum #{enum.keys.inspect}" if stray.any?
      end

      # The question every measure of the field will ask, present now — a registry built without one raises here, not then.
      def s1_verify_question!(name)
        question = s1_instructions[name]
        return if (question.is_a?(String) && !question.strip.empty?) || (question.is_a?(Hash) && question.any?)

        raise ArgumentError, "#{self}: #{name.inspect} has no question (#{MACRO[s1_registry.dig(name, :kind)]} #{name.inspect}, \"…\")"
      end

      # A named provider resolves now; an instance answers for itself.
      def s1_verify_provider!(name, provider)
        return if provider.nil? || provider.respond_to?(:call)

        S1.resolve_provider(provider)
      rescue S1::InvalidRequestError => e
        raise ArgumentError, "#{self}: #{name.inspect} provider: #{e.message}"
      end

      # One sibling column per field: two fields writing one column would take turns silently.
      def s1_verify_claims!(name, claimed)
        (s1_registry.dig(name, :siblings) || {}).each_value do |column|
          other = claimed[column]
          raise ArgumentError, "#{self}: sibling #{column.inspect} is claimed by both #{other.inspect} and #{name.inspect}" if other

          claimed[column] = name
        end
      end

      # A score needs its levels; an enum column is already a scale, so levels there are a contradiction unless they
      # are the enum's own keys (score_enum, or a Scale over them), with the enum's integers when indexes: are given.
      def s1_verify_levels!(name, field, enum, type)
        s1_verify_enum_levels!(name, field, enum) if enum
        raise ArgumentError, "#{self}: #{name.inspect} is a score with no levels — give them, { level => integer } on an integer column" unless field[:levels]
        if field[:dynamic] && type == :integer
          raise ArgumentError, "#{self}: #{name.inspect} is a dynamic score on an integer column: the stored integer would follow position"
        end
        return if field[:indexes] || field[:dynamic]

        positional = type == :integer && !enum ? "on an integer column" : (field[:siblings].is_a?(Hash) && field[:siblings][:index] && "with an _index sibling")
        return unless positional

        s1_warn("#{self}: #{name.inspect} is a score #{positional} with positional levels — " \
                "give explicit indexes { level => integer }; a level inserted later shifts every stored value")
      end

      def s1_verify_enum_levels!(name, field, enum)
        levels = Array(field[:levels])
        return unless field[:dynamic] || enum.keys.sort != levels.sort || (field[:indexes] && enum.values_at(*levels) != field[:indexes])

        raise ArgumentError, "#{self}: #{name.inspect} has levels on an enum column that are not its keys: use one or the other " \
                             "(score_enum makes an enum a score; a Scale over the enum's keys is its scale)"
      end

      def s1_verify_options!(name, field)
        raise ArgumentError, "#{self}: #{name.inspect} threshold: only applies to judges" if field[:threshold] && field[:kind] != :noul

        as, given = field.values_at(:as, :given)
        raise ArgumentError, "#{self}: #{name.inspect} as: #{as.inspect} is not a declared form (measurable_as)" if as && !s1_form?(as)
        raise ArgumentError, "#{self}: #{name.inspect} given: #{given.inspect} names no method" if given.is_a?(Symbol) && !s1_method?(given)

        s1_verify_provider!(name, field[:provider])
        s1_verify_after!(name, field)
        (field[:siblings] || {}).each { |part, column| s1_verify_sibling!(name, field, part, column) }
        s1_verify_dynamic!(name, field)
        s1_verify_trigger!(name, field)
      end

      # Every predecessor is a measured field, and not a key of the field's own lens or the
      # declared one (its collapse is that key); a predecessor on a float column keeps the
      # distribution, not the collapse — a score needs the audit to read its level from, a judge
      # the audit or a declared threshold: to read its verdict at; with a trigger, every
      # predecessor is on it.
      def s1_verify_after!(name, field)
        after = Array(field[:after])
        after.each do |dep|
          raise ArgumentError, "#{self}: #{name.inspect} after: #{dep.inspect} is not a measured field" unless s1_registry.key?(dep)

          s1_verify_predecessor_readable!(name, dep)
        end
        s1_lens_clash!(name, after, "given:", field[:given].is_a?(Hash) ? field[:given].keys : [])
        s1_lens_clash!(name, after, "measured_against", s1_declared_lens_keys)
        s1_verify_predecessors_triggered!(name, after) if after.any? && field[:measure_on]
      end

      def s1_lens_clash!(name, after, spelling, keys)
        clash = keys.map(&:to_sym) & after
        return if clash.empty?

        raise ArgumentError, "#{self}: #{name.inspect} #{spelling} #{clash.first.inspect} is a field it comes after: its collapse is that key"
      end

      def s1_verify_predecessor_readable!(name, dep)
        kind = s1_registry.dig(dep, :kind)
        return unless %i[score noul].include?(kind) && %i[float decimal].include?(s1_column_type(dep))
        return if column_names.include?("s1_answers")
        return if kind == :noul && s1_registry.dig(dep, :threshold)

        raise ArgumentError, "#{self}: #{name.inspect} after: #{dep.inspect} — a #{VERB.fetch(kind)} on a #{s1_column_type(dep)} column keeps " \
                             "#{UNREADABLE.fetch(kind)} so the lens reads the stored measurement's collapse"
      end

      # The keys of measured_against, read on a blank record when it can be; a lens that needs a
      # real record is checked at the call.
      def s1_declared_lens_keys
        new.s1_lens.keys.map(&:to_sym)
      rescue StandardError
        []
      end

      def s1_verify_predecessors_triggered!(name, after)
        _key, list = s1_triggers.find { |_, fields| fields.include?(name) }
        stray = after - list.to_a
        return if stray.empty?

        raise ArgumentError, "#{self}: #{name.inspect} is triggered without its predecessors #{stray.inspect}; a sequenced field shares their trigger"
      end

      def s1_form?(name) = name == :default || s1_states.include?(name)
      def s1_method?(name) = method_defined?(name) || private_method_defined?(name) || attribute_names.include?(name.to_s)

      # A dynamic scale is checked for what boot can see: a method that exists, a Proc that takes
      # the record at most. What it returns is checked when it runs.
      def s1_verify_dynamic!(name, field)
        return unless field[:dynamic]

        scale = field[:categories] || field[:levels]
        raise ArgumentError, "#{self}: #{name.inspect} dynamic scale #{scale.inspect} names no method" if scale.is_a?(Symbol) && !s1_method?(scale)
        return unless scale.is_a?(Proc) && !scale.arity.between?(-1, 1)

        raise ArgumentError, "#{self}: #{name.inspect} dynamic scale takes the record at most (arity #{scale.arity})"
      end

      def s1_verify_trigger!(name, field)
        _hook, watch = s1_trigger(name, field[:measure_on]) if field[:measure_on]
        Array(watch).each { |attribute| s1_attribute!(name, attribute) } if watch.is_a?(Array)
      end

      def s1_verify_sibling!(name, field, part, column)
        s1_sibling_part!(name, field[:kind], part)
        raise ArgumentError, "#{self}: #{name.inspect} sibling #{column.inspect} is not a column" unless column_names.include?(column.to_s)

        s1_verify_sibling_type!(name, field, part, column)
      end

      # An _index beside a dynamic scale would follow position — the integer-column foot-gun, refused.
      def s1_verify_sibling_type!(name, field, part, column)
        if part == :index && field[:dynamic]
          raise ArgumentError, "#{self}: #{name.inspect} sibling #{column.inspect} beside a dynamic scale would follow position: " \
                               "drop the column or siblings: false"
        end

        type = type_for_attribute(column.to_s).type
        return if SIBLINGS[part].include?(type)

        raise ArgumentError, "#{self}: #{name.inspect} sibling #{column.inspect} is #{type}; #{part} needs #{SIBLINGS[part].join(" / ")}"
      end

      # String-backed by default (stored by name: safe to reorder). A positional
      # Array is Rails' array-enum foot-gun, opted into — it warns.
      def s1_enum_values(name, values, keys)
        return keys.to_h { |k| [k, k.to_s] } unless values
        return values unless values.is_a?(Array)

        s1_warn("#{self}: #{name.inspect} is an enum with positional values #{values.inspect} — a category inserted later " \
                "shifts every stored value; prefer the string-backed default or an explicit { category => integer }")
        keys.zip(values).to_h
      end

      # What the conventions decided for this model, said once at verify!: the sibling columns
      # claimed by name (an explicit map was asked for; the convention was not), and a model with
      # measured fields but no default form, whose evidence is then its remaining attributes.
      def s1_note_conventions!
        claimed = s1_registry.filter_map do |name, field|
          columns = s1_convention_siblings(name, field)
          "#{name.inspect} writes #{columns.map { |part, column| "#{column} (#{part})" }.join(", ")}" if columns.any?
        end
        s1_note("#{self}: #{claimed.join("; ")}") if claimed.any?
        bare = s1_registry.reject { |_, field| field[:as] }.keys
        return if bare.empty? || s1_states.include?(:default)

        s1_warn("#{self} measures #{bare.inspect} through no declared form: the evidence is the attributes #{s1_default_columns.inspect} — " \
                "declare measurable_as (or as: on the field) to say what the record looks like to the model")
      end

      # A field's siblings found by the <name>_<part> convention alone — not the ones its siblings: map named.
      def s1_convention_siblings(name, field)
        return {} unless field[:siblings].is_a?(Hash)

        field[:siblings].select { |part, column| column == :"#{name}_#{part}" && s1_explicit_siblings(name)[part] != column }
      end

      def s1_explicit_siblings(name) = s1_explicit[name] || {}
      def s1_explicit = @s1_explicit ||= (superclass.respond_to?(:s1_explicit) ? superclass.s1_explicit.dup : {})

      def s1_warn(message)
        (S1.config.logger || Kernel).warn("[s1] #{message}")
      end

      # A note goes to the configured logger alone: what a convention decided is worth a log line, not stderr.
      def s1_note(message)
        S1.config.logger&.info("[s1] #{message}")
      end
    end
  end
end
