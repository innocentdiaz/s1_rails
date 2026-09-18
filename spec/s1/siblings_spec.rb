# frozen_string_literal: true

# Sibling columns: <name>_probability / _index / _expectation / _confidence / _probabilities
# beside a measured column are found by name and written with the collapse. Three spellings —
# the convention, an explicit map, siblings: false — one registry key; a column named for a
# part the field cannot write, or mapped elsewhere, raises at verify! rather than sit unwritten.
RSpec.describe "sibling columns" do
  let(:ticket) { Ticket.create!(body: "I have asked three times. Can I talk to a real person?", plan: "gold") }

  before { stub_s1(escalate: 0.75, department: :billing, severity: 1, is_lead: 0.6) }

  describe "the convention" do
    it "is found at declaration and cached in the registry, per part the kind has" do
      expect(Ticket.s1_fields[:escalate][:siblings]).to eq(probability: :escalate_probability)
      expect(Ticket.s1_fields[:department][:siblings]).to eq(confidence: :department_confidence)
      expect(Ticket.s1_fields[:severity][:siblings]).to eq(expectation: :severity_expectation, index: :severity_index)
      expect(Ticket.s1_fields[:priority]).not_to have_key(:siblings)
      expect(Routing.s1_fields[:urgent][:siblings]).to eq(probability: :urgent_probability)
    end

    it "writes every part beside the collapse on update / assign" do
      ticket.assign_measure(:escalate, :department, :severity)
      expect(ticket.escalate).to be(true)
      expect(ticket.escalate_probability).to eq(0.75)
      expect(ticket.department_confidence).to eq(1.0)
      expect(ticket.severity).to eq("degraded")
      expect(ticket.severity_index).to eq(1)
      expect(ticket.severity_expectation).to eq(1.0)
      expect(ticket).to have_changes_to_save
      ticket.reload
      expect(ticket.severity_index).to be_nil
      ticket.update_measure(:severity)
      expect(ticket.reload.severity_index).to eq(1)
      expect(ticket.severity_expectation).to eq(1.0)
    end

    it "stores an _index sibling and an integer column by rank; the live score and its rehydration read the same" do
      stub_s1 do |_req|
        { severity: { legend: { "5" => "cosmetic", "6" => "degraded", "7" => "blocking" },
                      probabilities: { "5" => 0.2, "6" => 0.7, "7" => 0.1 }, confidence: 0.9 },
          quality: { legend: { "5" => "low", "6" => "mid", "7" => "high" }, probabilities: { "5" => 0.1, "6" => 0.1, "7" => 0.8 }, confidence: 0.9 } }
      end
      ticket.update_measure(:severity)
      live = ticket.s1_result[:severity]
      expect([live.key, live.to_s, live.level.position]).to eq([1, '1 "degraded"', 1])
      expect(ticket.reload).to have_attributes(severity: "degraded", severity_index: 1, severity_expectation: be_within(1e-9).of(0.9))
      expect(ticket.s1_answers["severity"]).to include("position" => 1, "probabilities" => { "0" => 0.2, "1" => 0.7, "2" => 0.1 })
      stored = ticket.measurement(:severity)
      expect([stored.key, stored.to_s, stored.level.position]).to eq([1, '1 "degraded"', 1])
      expect(stored.level).to eq(live.level)
      expect(stored.expectation).to eq(live.expectation)
      expect(stored.probabilities).to eq(live.probabilities)
      klass = stub_const("Ranked", Class.new(PhoneCall) { scores :quality, "q", :low, :mid, :high, siblings: false })
      row = klass.create!(firm: Firm.create!(name: "f"), transcript: "x")
      row.update_measure(:quality)
      expect(row.reload.quality).to eq(2)
      expect(klass.s1_collapsed(:quality, row)).to eq("high")
    end

    it "stores an _index sibling beside a score_enum as the enum's integer, never the label cast to 0" do
      klass = Class.new(ActiveRecord::Base) { self.table_name = "tickets" }
      klass.include(S1::Measurable)
      klass.class_eval { score_enum :priority, "How urgent?", low: 0, mid: 1, high: 2, siblings: { index: :grade } }
      stub_s1 do |_req|
        { priority: { legend: { "5" => "low", "6" => "mid", "7" => "high" }, probabilities: { "5" => 0.1, "6" => 0.2, "7" => 0.7 },
                      confidence: 0.7 } }
      end
      row = klass.create!(body: "x")
      row.update_measure(:priority)
      expect(row.reload).to have_attributes(priority: "high", grade: 2)
      expect(row.read_attribute_before_type_cast(:priority)).to eq(2)
    end

    it "waits for verify! when the schema cannot be read at declaration" do
      klass = Class.new(Ticket)
      klass.singleton_class.define_method(:table_exists?) { raise ActiveRecord::ConnectionNotEstablished }
      klass.judges :escalate, "q"
      expect(klass.s1_fields[:escalate]).not_to have_key(:siblings)
      klass.singleton_class.remove_method(:table_exists?)
      klass.s1_verify_fields!
      expect(klass.s1_fields[:escalate][:siblings]).to eq(probability: :escalate_probability)
    end
  end

  describe "the other spellings" do
    it "siblings: false opts out — the columns stay untouched, verify! passes" do
      klass = Class.new(Ticket) { judges :escalate, "q", siblings: false }
      expect(klass.s1_fields[:escalate]).to include(siblings: false)
      expect { klass.s1_verify_fields! }.not_to raise_error
      row = klass.find(ticket.id)
      row.update_measure(:escalate)
      expect(row.reload.escalate).to be(true)
      expect(row.escalate_probability).to be_nil
    end

    it "an explicit map names the column; over the convention, the map wins per part" do
      call = Class.new(PhoneCall) { judges :is_lead, "Lead?", siblings: { probability: :lead_probability } }
      expect(call.s1_fields[:is_lead][:siblings]).to eq(probability: :lead_probability)
      row = call.create!(firm: Firm.create!(name: "f"), transcript: "hi")
      row.update_measure(:is_lead)
      expect(row.reload.is_lead).to be(true)
      expect(row.lead_probability).to eq(0.6)
      mixed = Class.new(Ticket) do
        judges :escalate, "q", siblings: false
        scores :severity, "q", :a, :b, siblings: { confidence: :escalate_probability }
      end
      expect(mixed.s1_fields[:severity][:siblings]).to eq(expectation: :severity_expectation, index: :severity_index, confidence: :escalate_probability)
      expect { mixed.s1_verify_fields! }.not_to raise_error
    end
  end

  describe "the guards" do
    it "refuses a map that is not false or a Hash" do
      expect { Class.new(Ticket) { judges :escalate, "q", siblings: :escalate_probability } }
        .to raise_error(ArgumentError, /:escalate siblings: is false or \{ part => column \} \(got :escalate_probability\)/)
    end

    it "verify! raises on a column named for a part the kind has not, or mapped to another column" do
      expect { Class.new(Ticket) { chooses :severity, "q", :a, :b }.s1_verify_fields! }
        .to raise_error(ArgumentError, /:severity_expectation is named as :severity's expectation, but a choice has no expectation; map it, rename it/)
      expect { Class.new(Ticket) { judges :escalate, "q", siblings: { probability: :severity_expectation } }.s1_verify_fields! }
        .to raise_error(ArgumentError, /:escalate_probability is named as :escalate's probability, but siblings: maps probability to :severity_expectation/)
      expect { Class.new(Ticket) { chooses :severity, "q", :a, :b, siblings: false }.s1_verify_fields! }.not_to raise_error
    end

    it "verify! checks the column types of the convention's columns too" do
      klass = Class.new(PhoneCall) { chooses :case_type, "q", :mva, :slip }
      expect(klass.s1_fields[:case_type][:siblings]).to eq(confidence: :case_type_confidence)
      expect { klass.s1_verify_fields! }.to raise_error(ArgumentError, %r{sibling :case_type_confidence is integer; confidence needs float / decimal})
    end
  end
end
