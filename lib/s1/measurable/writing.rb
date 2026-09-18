# frozen_string_literal: true

module S1
  module Measurable
    # How a Result collapses into the row: which distributions have a column (a declared
    # field of its own kind over its own scale, or an undeclared column of a type the kind
    # collapses into — never the key, the timestamps or the audit), how each is coerced by
    # column type, which siblings go beside it, and the audit read fresh under a row lock.
    module Writing
      VERB_FOR = Declarations::VERB
      NOT_A_COLUMN = %w[created_at updated_at s1_answers].freeze

      private

      # The row's audit as stored now, under a row lock (a no-op where the adapter has none), with
      # what this record changed in memory over it.
      def stored_answers
        return unless record.has_attribute?(:s1_answers)

        current = record.s1_answers.to_h
        return current unless record.persisted?

        fresh = record.class.unscoped.lock.where(record.class.primary_key => record.id).pick(:s1_answers).to_h
        was = record.attribute_in_database(:s1_answers).to_h
        fresh.merge(current.reject { |id, entry| was[id] == entry })
      end

      # Whether a distribution's id names a column it may collapse into: a declared field of
      # its own kind over its own scale, or an undeclared column of a type that kind collapses
      # into — never the key, the timestamps or the audit, never coerced across kinds, and
      # never a category the column's scale does not have. A declared field the record was
      # loaded without (a `select`) raises rather than audit a value the row never gets.
      def column?(id, distribution)
        declared = record.class.s1_fields.dig(id.to_sym, :kind)
        unless record.has_attribute?(id)
          return false unless declared

          raise ArgumentError, "#{record.class}: #{id.inspect} is a measured field this record was loaded without (a select?); " \
                               "load the column to write it"
        end
        raise ArgumentError, "#{record.class}: #{id.inspect} is not a column a measurement collapses into" if reserved_column?(id)
        return collapses_into?(id, distribution) unless declared

        declared_kind!(id, distribution, declared)
        true
      end

      def declared_kind!(id, distribution, declared)
        raise ArgumentError, "#{id} is a #{declared}; use #{VERB_FOR.fetch(declared)}" if declared != distribution.kind.to_sym

        on_scale!(id, distribution)
      end

      # An undeclared column takes the kind its type collapses into — an enum a choice, or a
      # score when its values are integers — or the raise names the macro.
      def collapses_into?(id, distribution)
        kind = distribution.kind.to_sym
        enum = record.class.defined_enums[id.to_s]
        type = record.class.type_for_attribute(id.to_s).type
        fits = enum ? kind == :choice || (kind == :score && enum.values.all?(Integer)) : Declarations::COLUMNS[kind].include?(type)
        return true if fits

        raise ArgumentError, "#{record.class}: a #{kind} does not collapse into #{id.inspect} (#{enum ? "an enum" : "column type #{type.inspect}"}); " \
                             "declare it with #{Declarations.macro_for(type, !enum.nil?)}"
      end

      def reserved_column?(id) = id.to_s == record.class.primary_key.to_s || NOT_A_COLUMN.include?(id.to_s)

      # A block may ask a declared field over another scale (q.score :severity, "q", "x", "y") and keep
      # the distribution; the column holds the declared scale, so a label off it refuses the write,
      # naming both (a provider that leaves out a zero-mass category is still on the scale). A
      # dynamic scale is the record's word when asked, kept in the audit, not re-read here.
      def on_scale!(id, distribution)
        return if record.class.s1_fields.dig(id.to_sym, :dynamic)

        declared = declared_scale(id, distribution)
        asked = distribution.is_a?(S1::Answer::Score) ? distribution.levels.map(&:to_s) : distribution.probabilities.keys
        return if declared.nil? || (asked - declared).empty?

        raise ArgumentError, "#{record.class}: #{id.inspect} is declared over #{declared.inspect}; a measurement over #{asked.inspect} " \
                             "does not collapse into its column — ask it under another id, or reword without a scale " \
                             "(q.#{VERB_FOR.fetch(distribution.kind.to_sym)} #{id.inspect}, \"…\")"
      end

      def declared_scale(id, distribution)
        case distribution
        when S1::Answer::Score then record.class.s1_levels_for(id, record)&.first
        when S1::Answer::Choice then (record.class.s1_categories_for(id, record) || record.class.s1_categories(id))&.keys&.map(&:to_s)
        end
      end

      def coerce(id, distribution)
        type = record.class.type_for_attribute(id.to_s).type
        case distribution
        when S1::Answer::Noul   then type == :boolean ? distribution.true? : distribution.to_f
        when S1::Answer::Choice then distribution.to_s
        when S1::Answer::Score  then score_value(id, distribution, type)
        end
      end

      # enum: the label (Rails maps it); integer: the declared index for the level, or its
      # position; numeric: the expectation; else the label.
      def score_value(id, distribution, type)
        level = distribution.level
        return level.to_str if record.class.defined_enums.key?(id.to_s)

        case type
        when :integer then index_of(id, level)
        when :float, :decimal then distribution.to_f
        else level.to_str
        end
      end

      # The integer an integer column keeps for a level: the declared index (a score_enum's
      # integer, an indexes: entry), else its position.
      def index_of(id, level) = record.class.s1_fields.dig(id.to_sym, :indexes)&.[](level.position) || level.position

      def siblings(id, distribution)
        (record.class.s1_fields.dig(id.to_sym, :siblings) || {}).to_h { |part, column| [column, part_of(id, distribution, part)] }
      end

      # A score's _probabilities are keyed by its labels — the scale in its own type, as the
      # column and the audit name it — not by wire position.
      def part_of(id, distribution, part)
        case part
        when :probability, :expectation then distribution.to_f
        when :confidence then distribution.confidence
        when :index then index_of(id, distribution.level)
        when :probabilities then distribution.is_a?(S1::Answer::Score) ? by_label(distribution) : distribution.probabilities
        end
      end

      def by_label(distribution)
        ranked(distribution).to_h { |label, key| [label, distribution.probabilities.fetch(key, 0.0)] }
      end

      # A score's mass by rank — "0", "1", … in the scale's order — whatever keys the wire used.
      def by_rank(distribution)
        ranked(distribution).each_with_index.to_h { |(_, key), i| [i.to_s, distribution.probabilities.fetch(key, 0.0)] }
      end

      # [label, wire key] in the scale's order, through the legend the provider sent.
      def ranked(distribution)
        legend_of(distribution).sort.map { |key, label| [label.to_s, key.to_s] }
      end

      # The legend — wire key => label — is the distribution's own; the writes read it by rank.
      def legend_of(distribution) = distribution.send(:legend)
    end
  end
end
