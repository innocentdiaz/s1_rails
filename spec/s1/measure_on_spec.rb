# frozen_string_literal: true

# measure_on: in three shapes — a lifecycle name, an attribute (or list) that changed, a Proc —
# each with if: / unless: / on: beside it, all landing on the same update_measure_later /
# assign_measure. `measure_on: :transcript` and `measure_on: :save, if:
# :saved_change_to_transcript?` are two spellings of one trigger.
RSpec.describe "measure_on: shapes" do
  let(:requests) { [] }

  before { stub_s1 { |req| requests << req and { kind: :new_case, case_type: :mva, urgent: 0.9, escalate: 0.9, severity: 1 } } }

  describe "an attribute" do
    it "measures after commit when that attribute changed — and `measure_on: :save, if: :saved_change_to_x?` is the same trigger spelled long" do
      row = Routing.create!(transcript: "I was rear-ended on the highway")
      expect(enqueued_jobs.size).to eq(2) # kind + case_type on :transcript; urgent on :save if: saved_change_to_transcript?
      perform_enqueued_jobs
      expect(requests.map { |r| r.questions.keys }).to contain_exactly([:kind], [:case_type], [:urgent])
      expect(row.reload).to have_attributes(kind: "new_case", case_type: "mva", urgent: true, urgent_probability: 0.9)
      requests.clear
      row.update!(kind: "existing")
      expect(enqueued_jobs).to be_empty
      row.update!(transcript: "I want to check on my case")
      expect(enqueued_jobs.size).to eq(2)
      expect(enqueued_jobs.map { |j| j["arguments"][5] }).to contain_exactly(%w[kind case_type], %w[urgent])
    end

    it "keeps the two spellings on one code path: the same job, the same Request" do
      short = stub_const("Short", Class.new(Ticket) { judges :escalate, "q", measure_on: :body })
      long = stub_const("Long", Class.new(Ticket) { judges :escalate, "q", measure_on: :save, if: :saved_change_to_body? })
      [short, long].each do |klass|
        requests.clear
        row = klass.create!(body: "x")
        expect(enqueued_jobs.size).to eq(1)
        perform_enqueued_jobs
        row.update!(plan: "gold")
        expect(enqueued_jobs).to be_empty
        row.update!(body: "y")
        perform_enqueued_jobs
        expect(requests.map(&:questions).map(&:keys)).to eq([[:escalate], [:escalate]])
        expect(requests.map(&:state).uniq.size).to eq(2)
        expect(row.reload.escalate).to be(true)
      end
      expect(short.s1_fields[:escalate]).to eq(kind: :noul, question: "q", measure_on: :body, siblings: { probability: :escalate_probability })
      expect(long.s1_fields[:escalate]).to include(measure_on: :save, conditions: { if: :saved_change_to_body? })
    end

    it "takes a list — any of them changing measures — and composes with if: / unless:" do
      klass = stub_const("Listed", Class.new(Ticket) do
        judges :escalate, "q", measure_on: %i[body plan], unless: :blank_body?
        scores :severity, "q", :a, :b, measure_on: %i[body plan], unless: :blank_body?, siblings: false
        def blank_body? = body.blank?
      end)
      expect(klass.s1_triggers.values).to eq([%i[escalate severity]]) # one trigger for both: a method name groups, a lambda is its own
      row = klass.create!(body: "", plan: "gold")
      expect(enqueued_jobs).to be_empty # unless: held
      row.update!(body: "x")
      expect(enqueued_jobs.size).to eq(1)
      expect(enqueued_jobs.last["arguments"][5]).to eq(%w[escalate severity])
      clear_enqueued_jobs
      row.update!(plan: "free")
      expect(enqueued_jobs.size).to eq(1)
      clear_enqueued_jobs
      row.update!(department: "billing")
      expect(enqueued_jobs).to be_empty
      perform_enqueued_jobs
      expect(enqueued_jobs).to be_empty # the measurement's own write does not re-trigger
    end
  end

  describe "a Proc" do
    it "is checked on every save, after commit" do
      klass = stub_const("Guarded", Class.new(Ticket) { judges :escalate, "q", measure_on: -> { body.to_s.length > 5 } })
      row = klass.create!(body: "hi")
      expect(enqueued_jobs).to be_empty
      row.update!(body: "hello there")
      expect(enqueued_jobs.size).to eq(1)
      expect(klass.s1_fields[:escalate][:measure_on]).to be_a(Proc)
      expect(klass.s1_plan.to_s).to include("escalate (measure_on: (proc); writes escalate_probability)")
    end
  end

  describe "the lifecycle names" do
    it "are reserved: :validation stays synchronous, and if: still composes" do
      klass = Class.new(Ticket) { judges :escalate, "q", measure_on: :validation, if: :will_save_change_to_body? }
      row = klass.create!(body: "x")
      expect(row.escalate).to be(true)
      expect(enqueued_jobs).to be_empty
      expect(klass.s1_plan.to_s).to include("escalate (measure_on: :validation; writes escalate_probability)")
    end
  end

  describe "the guards" do
    it "refuses an attribute the model does not have, at declaration, and a shape it cannot read" do
      expect { Class.new(Ticket) { judges :escalate, "q", measure_on: :transcript } }
        .to raise_error(ArgumentError, /:escalate measure_on: :transcript is not an attribute of/)
      expect { Class.new(Ticket) { judges :escalate, "q", measure_on: %i[body nope] } }.to raise_error(ArgumentError, /measure_on: :nope is not an attribute/)
      expect { Class.new(Ticket) { judges :escalate, "q", measure_on: 3 } }.to raise_error(
        ArgumentError, /measure_on: is a lifecycle name \[:validation, :create, :save, :update\], an attribute name \(or a list\), or a Proc \(got 3\)/
      )
    end

    it "defers the attribute check to verify! when the schema cannot be read at declaration" do
      klass = Class.new(Ticket)
      klass.singleton_class.define_method(:table_exists?) { raise ActiveRecord::ConnectionNotEstablished }
      expect { klass.judges :escalate, "q", measure_on: :transcript, siblings: false }.not_to raise_error
      klass.singleton_class.remove_method(:table_exists?)
      expect { klass.s1_verify_fields! }.to raise_error(ArgumentError, /measure_on: :transcript is not an attribute/)
    end
  end
end
