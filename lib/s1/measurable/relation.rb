# frozen_string_literal: true

require "English"

module S1
  module Measurable
    # A relation is a stream. measure_all keeps the distributions and writes
    # nothing; update_measure_all collapses into the columns, one find_each slice
    # measured then written before the next; where_judged / where_same_as filter.
    # `concurrency` is provider calls in flight at a time; everything else — the
    # block, the forms, the lenses, the gates, the dynamic scales, the writes — runs
    # on the calling thread, on its connection. The block also receives the record.
    # `as:` left out lets each declared field pick its own form.
    module Relation
      def measure_all(*questions, as: nil, concurrency: 1, given: nil, metadata: nil, &block)
        s1_map(as: as, concurrency: concurrency, given: given) { |s| s.measure(one_or_many(questions), metadata: metadata) { |q| block&.call(q, s.record) } }
          .to_h { |s, result| [s.record, result] }
      end
      alias ask_all measure_all

      # measure_all, then collapse each Result into its record's columns, slice by slice: the first
      # failing call raises, and the slices before it stay written. Returns { record => Result }.
      def update_measure_all(*questions, as: nil, concurrency: 1, given: nil, metadata: nil, &block)
        s1_map(as: as, concurrency: concurrency, given: given) { |s| s.measure(one_or_many(questions), metadata: metadata) { |q| block&.call(q, s.record) } }
          .to_h { |s, result| [s.record, s.apply(result)] }
      end
      alias update_ask_all update_measure_all
      alias update_judge_all update_measure_all

      # A lens for every judgement down the chain, as a scope:
      #   Item.unclaimed.given(note: policy).where_judged_not("Is `this` worth keeping, per `note`?")
      def given(**lens) = all.extending(Measurable::Given).tap { |r| r.s1_lens = lens }
      alias against given

      # The records for which the question is judged true / false. One call per
      # record, `concurrency` at a time; returns a relation, so ActiveRecord
      # continues after it. A declared column measures each record's own question.
      #   Item.unclaimed.where_judged("Is this worth keeping?", concurrency: 8)
      #   Claim.where_judged(:plausible, threshold: 0.8)
      def where_judged(question, as: nil, concurrency: 1, given: nil, **)
        yes = s1_map(as: as, concurrency: concurrency, given: given) { |s| s.judge?(question, **) }
        where(id: yes.filter_map { |s, judged| s.record.id if judged }.to_a)
      end
      alias measure_select where_judged
      alias s1_select where_judged

      def where_judged_not(question, as: nil, concurrency: 1, given: nil, **)
        yes = s1_map(as: as, concurrency: concurrency, given: given) { |s| s.judge?(question, **) }
        where(id: yes.filter_map { |s, judged| s.record.id unless judged }.to_a)
      end
      alias measure_reject where_judged_not
      alias s1_reject where_judged_not

      # The relation's is? / is-not: the phrase completes "Is this …?"; a declared column name is its own question.
      def where_is(phrase, **) = where_judged(phrase.is_a?(Symbol) ? phrase : "Is this #{phrase}?", **)
      def where_is_not(phrase, **) = where_judged_not(phrase.is_a?(Symbol) ? phrase : "Is this #{phrase}?", **)

      # The records that describe the same thing as `other` — the relation's
      # same_as? / ===, with concurrency. `grep(ψ other)` is the sequential spelling.
      def where_same_as(other, as: nil, concurrency: 1, **)
        same = s1_map(as: as, concurrency: concurrency) { |s| s.same_as?(other, **) }
        where(id: same.filter_map { |s, judged| s.record.id if judged }.to_a)
      end
      alias measure_grep where_same_as

      # The rows whose stored measurement of `column` was taken under another question than the
      # declaration asks now — or never taken. `Model.stale(:col).update_measure_all(:col)` is the
      # remeasure; `rake s1:remeasure[Model,col]` does it in batches. In SQL on PostgreSQL,
      # SQLite and MySQL; in Ruby otherwise, and for a dynamic scale (its question is per record).
      def stale(column)
        column = column.to_sym
        raise ArgumentError, "#{self}: stale needs an s1_answers column" unless column_names.include?("s1_answers")

        field = s1_fields.fetch(column) { raise ArgumentError, "#{self}: #{column.inspect} is not a measured field" }
        return s1_stale_in_ruby(column) if field[:dynamic]

        digest = s1_question_digest(column)
        table = connection.quote_table_name(table_name)
        case connection.adapter_name
        when /postg/i then where("#{table}.s1_answers -> #{connection.quote(column.to_s)} ->> 'question_digest' IS DISTINCT FROM ?", digest)
        when /sqlite/i then where("json_extract(#{table}.s1_answers, ?) IS NOT ?", "$.#{column}.question_digest", digest)
        when /mysql|trilogy/i then where("NOT (JSON_UNQUOTE(JSON_EXTRACT(#{table}.s1_answers, ?)) <=> ?)", "$.#{column}.question_digest", digest)
        else s1_stale_in_ruby(column)
        end
      end

      private

      # Loud: no JSON path for this adapter, or a dynamic scale — every row in the relation is
      # loaded and read in Ruby, and the log says so. Fine for a backfill, wrong for a hot path.
      def s1_stale_in_ruby(column)
        (S1.config.logger || Kernel).warn("[s1] #{self}.stale(#{column.inspect}) runs in Ruby: every row in the relation is loaded and read")
        ids = all.find_each.filter_map { |record| record.id if record.stale?(column) }
        where(primary_key => ids)
      end

      def one_or_many(questions) = questions.size <= 1 ? questions.first : questions

      # [state, value] per record, lazily — a slice at a time, so a consumer that writes has
      # written every slice before the next is measured. Each record's measurement runs on the
      # calling thread, so the block, the forms, the lenses, the gates and the dynamic scales
      # read the database on its connection; only the provider call is handed to a thread. The
      # lens is `given:` merged over a `given(...)` scope up the chain, as a lens merges
      # everywhere. A call's error surfaces once, in the caller, not also on stderr.
      def s1_map(as:, concurrency:, given: nil, &)
        lens = (all.respond_to?(:s1_lens) ? all.s1_lens.to_h : {}).merge(given.to_h).presence
        all.find_each.each_slice([concurrency, 1].max).lazy.flat_map do |slice|
          states = slice.map { |record| record.as(as, given: lens) }
          states.zip(s1_in_flight(states, &))
        end
      end

      # The block, once per State, each in a Fiber on this thread: a State reaching its provider
      # call yields the call, which runs in a thread while the other Fibers go on, and the Fiber
      # resumes with the outcome when it lands. The values in the States' order.
      def s1_in_flight(states, &block)
        landed = Queue.new
        values = {}
        fibers = states.map { |s| s1_fiber(s, &block) }
        step = lambda do |i, *outcome|
          out = fibers[i].resume(*outcome)
          next values[i] = out unless fibers[i].alive?

          Thread.new { s1_land(landed, i, out) }.tap { |t| t.report_on_exception = false }
        end
        fibers.each_index { |i| step.call(i) }
        step.call(*landed.pop) while values.size < fibers.size
        fibers.each_index.map { |i| values[i] }
      end

      def s1_fiber(state)
        Fiber.new do
          state.in_flight = ->(work) { Fiber.yield(work) }
          yield state
        end
      end

      # A call's value, wrapped, or whatever it raised — carried back to the Fiber that asked,
      # always, so the caller never waits on a thread that died.
      def s1_land(landed, index, work)
        outcome = [work.call]
      ensure
        landed << [index, outcome || $ERROR_INFO]
      end
    end
  end
end
