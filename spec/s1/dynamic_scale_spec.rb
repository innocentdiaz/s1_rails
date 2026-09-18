# frozen_string_literal: true

# A scale evaluated on the record at measure time: categories: / levels: as a method name or a
# Proc — two spellings, one Request — checked for shape at boot, for content when it runs,
# stored with the measurement so it rehydrates.
RSpec.describe "dynamic scales" do
  let(:requests) { [] }
  # kind: "new_case" — case_type is sequenced after :kind and gated if: :new_case?; the gate holds everywhere but the bare verbs.
  let(:routing) { Routing.create!(transcript: "I was rear-ended on the highway", kind: "new_case") }

  before { stub_s1 { |req| requests << req and { case_type: :slip, kind: :new_case, severity: 1 } } }

  describe "the spellings" do
    it "categories: as a method name or a Proc build the same question" do
      by_proc = Class.new(Routing) { chooses :case_type, "Which case type, given `kind`?", categories: -> { case_types }, after: :kind }
      expect(Routing.s1_fields[:case_type]).to include(categories: :case_types, dynamic: true)
      expect(by_proc.s1_fields[:case_type]).to include(dynamic: true)
      expect(by_proc.s1_fields[:case_type][:categories]).to be_a(Proc)
      expect(by_proc.find(routing.id).s1_request(:case_type).questions).to eq(routing.s1_request(:case_type).questions)
      expect(routing.s1_request(:case_type).questions[:case_type].criteria)
        .to eq("mva" => "a vehicle collision", "slip" => "a fall on premises", "other" => "none of these")
    end

    it "levels: as a method name or a Proc build the same question; a { label => description } shows the description, stores the label" do
      by_name = Class.new(Ticket) { scores :severity, "q", levels: :severity_levels, siblings: false }
      by_proc = Class.new(Ticket) { scores :severity, "q", levels: -> { severity_levels }, siblings: false }
      [by_name, by_proc].each { |k| k.define_method(:severity_levels) { plan == "gold" ? { low: "low for gold", high: "high for gold" } : %w[a b] } }
      ticket = Ticket.create!(body: "x", plan: "gold")
      expect(by_name.find(ticket.id).s1_request(:severity).questions).to eq(by_proc.find(ticket.id).s1_request(:severity).questions)
      expect(by_name.find(ticket.id).s1_request(:severity).questions[:severity].levels).to eq(["low for gold", "high for gold"])
      expect(by_name.find(ticket.id).level(:severity)).to eq("high")
      ticket.update!(plan: "free")
      expect(by_proc.find(ticket.id).s1_request(:severity).questions[:severity].levels).to eq(%w[a b])
    end
  end

  describe "the guards" do
    it "refuses a dynamic scale on an enum column at declaration: the enum is the scale" do
      expect { Class.new(Delivery) { chooses :status, "q", categories: -> { %w[a b] } } }
        .to raise_error(ArgumentError, /:status has a dynamic scale on an enum column: the enum is the scale/)
      expect { Class.new(Ticket) { scores :grade, "q", levels: :subtypes } }.to raise_error(ArgumentError, /dynamic scale on an enum column/)
    end

    it "raises a ValidationError naming the field when the scale evaluates to fewer than 2 labels, or not to a scale" do
      klass = stub_const("Thin", Class.new(Routing) { chooses :case_type, "q", categories: -> { { only: "one" } } })
      expect { klass.find(routing.id).choose(:case_type) }
        .to raise_error(S1::ValidationError, /Thin: :case_type dynamic scale returned \{(:only|only:) ?(=>)? ?"one"\}; a scale is at least 2 labels/)
      expect { Class.new(Routing) { chooses :case_type, "q", categories: -> { "mva, slip" } }.find(routing.id).choose(:case_type) }
        .to raise_error(S1::ValidationError, /returned "mva, slip"/)
      expect { Class.new(Routing) { chooses :case_type, "q", categories: -> {} }.find(routing.id).s1_request(:case_type) }
        .to raise_error(S1::ValidationError, /returned nil/)
    end

    it "verify! checks what boot can see — a method that exists, a Proc taking the record at most — and no more" do
      expect { Class.new(Routing) { chooses :case_type, "q", categories: :nope }.s1_verify_fields! }
        .to raise_error(ArgumentError, /:case_type dynamic scale :nope names no method/)
      expect { Class.new(Routing) { chooses :case_type, "q", categories: ->(_a, _b) { {} } }.s1_verify_fields! }
        .to raise_error(ArgumentError, /:case_type dynamic scale takes the record at most \(arity 2\)/)
      expect { Class.new(Routing) { chooses :case_type, "q", categories: ->(record) { record.case_types.except(:other) } }.s1_verify_fields! }
        .not_to raise_error
      expect { Class.new(Routing) { chooses :case_type, "q", categories: -> { {} } }.s1_verify_fields! }.not_to raise_error # content: at run time
      by_record = Class.new(Routing) { chooses :case_type, "q", categories: ->(record) { record.case_types.except(:other) } }
      expect(by_record.find(routing.id).s1_request(:case_type).questions[:case_type].categories).to eq(%w[mva slip])
    end

    it "refuses an _index sibling beside a dynamic score: the stored integer would follow position" do
      expect { Class.new(Ticket) { scores :severity, "q", levels: :subtypes }.s1_verify_fields! }
        .to raise_error(ArgumentError, /:severity sibling :severity_index beside a dynamic scale would follow position/)
      expect { Class.new(Ticket) { scores :severity, "q", levels: :subtypes, siblings: false }.s1_verify_fields! }.not_to raise_error
    end
  end

  describe "the sharp knives" do
    it "s1_plan notes the dynamic field; request shows the scale as evaluated for this record" do
      expect(Routing.s1_plan.to_s).to include("case_type (dynamic, no scale methods; measure_on: :transcript)")
      expect(routing.as.request(:case_type).questions[:case_type].categories).to eq(%w[mva slip other])
      expect(requests).to be_empty
    end
  end

  describe "the audit" do
    it "stores the evaluated scale, so measurement rehydrates over it even after the method changes" do
      routing.update_measure(:case_type)
      expect(routing.reload.s1_answers.dig("case_type", "scale")).to eq(%w[mva slip other])
      narrower = Class.new(Routing) { def case_types = { mva: "a vehicle collision", other: "none of these" } }
      stored = narrower.find(routing.id).measurement(:case_type)
      expect(stored).to be_a(S1::Answer::Choice)
      expect(stored.categories).to eq(%i[mva slip other])
      expect(stored.to_sym).to eq(:slip)
      ticket = Ticket.create!(body: "x", plan: "gold")
      dynamic = Class.new(Ticket) { scores :severity, "q", levels: -> { { low: "low for gold", high: "high for gold" } }, siblings: false }
      dynamic.find(ticket.id).update_measure(:severity)
      expect(ticket.reload.s1_answers.dig("severity", "scale")).to eq(%w[low high])
      expect(ticket.s1_answers.dig("severity", "value")).to eq("high")
      expect(ticket.measurement(:severity).levels.map(&:to_s)).to eq(%w[low high]) # Ticket's own levels are cosmetic/degraded/blocking
      expect(ticket.measurement(:severity).level).to eq("high")
    end
  end
end
