# frozen_string_literal: true

module S1
  module Measurable
    # The call plan a set of declared fields implies: stages (a field with after: waits
    # for those fields to be written, and carries their collapses in its lens), each a
    # list of batches — one provider call each, fields that share a form, a lens, a
    # sequence, a provider and a model. `fixed` are call-site settings (as:, provider:,
    # model:) that override every field's; with `record`, a call-site lens (given:) that
    # covers every key of a field's lens overrides it too, so those fields batch together.
    #
    #   PhoneCall.s1_plan               # every field
    #   PhoneCall.s1_plan(:is_lead, :case_type, :subtype)
    #   puts PhoneCall.s1_plan          # the stages and calls, readable: a dynamic scale and a trigger are noted per field
    class Plan
      Batch = Data.define(:as, :given, :after, :provider, :model, :metadata, :fields) do
        def settings
          named = { as: as, given: Plan.lens_name(given), after: after&.join(", "), provider: provider, model: model, metadata: metadata }.compact
          named.map { |k, v| "#{k}: #{v.is_a?(String) ? v : v.inspect}" }.join(", ").presence || "as: :default"
        end

        def to_s = "#{settings}  →  #{fields.join(", ")}"
      end

      HOME = Batch.new(as: nil, given: nil, after: nil, provider: nil, model: nil, metadata: nil, fields: []).freeze

      attr_reader :owner, :stages

      def initialize(owner, names, fixed = {}, record: nil)
        @owner = owner
        fields = names.map(&:to_sym)
        @stages = Plan.stage(owner, fields).map { |stage| Plan.batch(owner, stage, fixed, record) }
      end

      def batches = stages.flatten
      def fields = batches.flat_map(&:fields)
      def size = batches.size

      # The stages and calls, and what the conventions decided: the attributes a model with no
      # default form sends, the sibling columns each field writes.
      def to_s
        lines = ["#{owner}.s1_plan — #{stages.size} stage(s), #{size} call(s)", *default_form_line]
        stages.each_with_index do |batches, i|
          lines << "stage #{i + 1}"
          batches.each_with_index { |batch, j| lines << "  call #{j + 1}: #{batch.settings}  →  #{batch.fields.map { |f| annotate(f) }.join(", ")}" }
        end
        lines.join("\n")
      end

      # The attributes a call through no declared form sends, when there is such a call.
      def default_form_line
        return [] if owner.s1_states.include?(:default) || batches.none? { |b| b.as.nil? }

        ["default form (attributes): #{owner.s1_default_columns.join(", ")}"]
      end

      def inspect = "#<S1::Measurable::Plan #{owner} #{stages.map { |s| s.map(&:fields) }.inspect}>"

      class << self
        # Fields grouped by depth in the after: graph, in order; a cycle raises.
        def stage(owner, fields)
          depth = {}
          resolve = lambda do |field, trail|
            raise ArgumentError, "#{owner}: after: cycle #{(trail + [field]).map(&:inspect).join(" → ")}" if trail.include?(field)

            depth[field] ||= begin
              deps = Array(owner.s1_fields.dig(field, :after)) & fields
              deps.empty? ? 0 : deps.map { |d| resolve.call(d, trail + [field]) }.max + 1
            end
          end
          fields.each { |f| resolve.call(f, []) }
          fields.group_by { |f| depth[f] }.sort.map(&:last)
        end

        # One batch per distinct (form, lens, sequence, provider, model, metadata), in first-appearance
        # order: one request carries one set of labels.
        def batch(owner, fields, fixed, record = nil)
          fields.group_by { |f| key(owner, f, fixed, record) }.map do |(as, given, after, provider, model, metadata), names|
            Batch.new(as: as, given: given, after: after, provider: provider, model: model, metadata: metadata, fields: names)
          end
        end

        def key(owner, name, fixed, record)
          field = owner.s1_fields.fetch(name, {})
          [fixed.fetch(:as) { field[:as] }, lens_key(owner, name, field[:given], fixed[:given], record), field[:after],
           fixed.fetch(:provider) { field[:provider] }, fixed.fetch(:model) { field[:model] }, field[:metadata]]
        end

        # A field's lens, unless the call-site lens covers every key of it: a Hash says its keys
        # itself, a method or Proc only on the record.
        def lens_key(owner, name, given, over, record)
          return given if given.nil? || over.blank?

          keys = given.is_a?(Hash) ? given.keys : (record && owner.s1_lens_for(name, record).keys)
          keys && (keys.map(&:to_sym) - over.keys.map(&:to_sym)).empty? ? nil : given
        end

        def lens_name(given)
          case given
          when nil then nil
          when Hash then given.keys
          when Symbol then given
          else "(proc)"
          end
        end
      end

      private

      # A field as the plan prints it: with its dynamic scale (no scale methods generated), its
      # trigger and the sibling columns it writes noted.
      def annotate(field)
        entry = owner.s1_fields.fetch(field, {})
        siblings = entry[:siblings].is_a?(Hash) ? entry[:siblings].values : []
        notes = [("dynamic, no scale methods" if entry[:dynamic]), ("measure_on: #{Declarations.trigger_name(entry[:measure_on])}" if entry[:measure_on]),
                 ("writes #{siblings.join(", ")}" if siblings.any?)].compact
        notes.empty? ? field.to_s : "#{field} (#{notes.join("; ")})"
      end
    end
  end
end
