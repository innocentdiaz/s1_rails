# frozen_string_literal: true

module S1
  module Measurable
    # The batch builder a record's questions are built with. Adds one thing to
    # S1::Questions: a declared field fills in what its declaration says — the
    # question, the definition, the categories, the levels — and a dynamic scale
    # is evaluated on the record here. Inline arguments override any of it.
    # `labels` keeps, per score, the labels the column stores for the levels the
    # model sees, so the distribution can speak the column's scale. A declared
    # field under the wrong verb raises naming the right one, as the record's verbs do.
    #
    #   q.judge  :is_lead                                                 # the declared question and definition
    #   q.judge  :is_lead, "Other wording?"                               # the declared definition under other wording
    #   q.choose :status                                                  # question + categories from choice_enum :status
    #   q.choose :status, "What is the sender reporting?"                 # categories from choice_enum :status (or enum :status)
    #   q.choose :outcome, "What is the sender reporting?", enum: :status
    #   q.score  :severity                                                # the declared levels (their descriptions, when given)
    class Questions < S1::Questions
      attr_reader :labels

      def initialize(record)
        super()
        @record = record
        @labels = {}
      end

      def judge(id, instructions = nil, criteria: nil, **clarification)
        kind!(id, :noul)
        criteria ||= field(id)[:criteria] if clarification.empty?
        super(id, instructions || question_for(id), criteria: criteria, **clarification)
      end
      alias noul judge

      def choose(id, instructions = nil, criteria: nil, categories: nil, enum: nil, **inline)
        kind!(id, :choice)
        criteria ||= categories || inline.delete(:choices)
        if enum
          criteria ||= model.s1_categories(enum, required: true)
        elsif inline.empty? && criteria.nil?
          criteria = model.s1_categories_for(id, @record) || model.s1_categories(id)
        end
        super(id, instructions || question_for(enum || id), criteria: criteria, **inline)
      end

      # The declared levels show their descriptions and store their labels — a static field goes as its
      # S1::Scale itself (the texts on the wire), so the distribution carries that very object; a dynamic
      # one goes as the texts it resolved to; inline levels — positional, or `criteria:`, the wire word —
      # are both, and never the declaration's.
      def score(id, instructions = nil, *levels, criteria: nil, **)
        kind!(id, :score)
        if levels.empty? && criteria.nil?
          labels, shown = model.s1_levels_for(id, @record)
          levels = labels && !field(id)[:dynamic] ? [field(id)[:scale]] : shown.to_a
          @labels[id.to_sym] = labels if labels
        end
        super(id, instructions || question_for(id), *levels, criteria: criteria, **)
      end

      # The column's own kind of measurement (s1_kind) under its verb, with its declared question.
      def field_question(id) = public_send(Declarations::VERB.fetch(model.s1_kind(id)), id)

      # The labels a score's column stores for the levels the model sees (a question that
      # crossed a job boundary carries them separately).
      def stores(id, labels)
        @labels[id.to_sym] = labels
        self
      end

      private

      def model = @record.class
      def field(id) = model.s1_fields.fetch(id.to_sym, {})

      def kind!(id, kind)
        actual = field(id)[:kind]
        return if actual.nil? || actual == kind

        raise ArgumentError, "#{id} is a #{actual}; use #{Declarations::VERB.fetch(actual)}"
      end

      def question_for(id)
        model.s1_instructions.fetch(id.to_sym) do
          raise ArgumentError, "#{model} has no declared question for #{id.inspect} (judges / chooses / scores / choice_enum)"
        end
      end
    end
  end
end
