# frozen_string_literal: true

# after: — a field measured in a later stage, the named fields' collapses in its lens, its
# if: / unless: read on the record with those collapses in place. The same stages run inside a
# trigger, update_measure(:a, :b), measure_all and measure; a cycle raises at declaration.
RSpec.describe "sequenced fields" do
  let(:requests) { [] }
  let(:answers) { { kind: :new_case, case_type: :slip, urgent: 0.2 } }

  before { stub_s1 { |req| requests << req and answers } }

  describe "the stages" do
    it "measures case_type after kind, with `kind` in its lens, inside the trigger's job" do
      row = Routing.create!(transcript: "I fell in a shop")
      perform_enqueued_jobs
      staged = requests.reject { |r| r.questions.key?(:urgent) }
      expect(staged.map { |r| r.questions.keys }).to eq([[:kind], [:case_type]])
      expect(staged.first.state).to eq(transcript: "I fell in a shop")
      expect(staged.last.state).to eq(this: { transcript: "I fell in a shop" }, kind: "new_case")
      expect(row.reload).to have_attributes(kind: "new_case", case_type: "slip")
    end

    it "runs the same stages from update_measure(:a, :b), measure_all and measure — one code path" do
      row = Routing.create!(transcript: "I fell in a shop")
      clear_enqueued_jobs
      [-> { row.update_measure(:kind, :case_type) }, -> { Routing.where(id: row.id).update_measure_all(:case_type, :kind) },
       -> { row.measure(:kind, :case_type) }, -> { row.update_measure_later(:kind, :case_type) and perform_enqueued_jobs }].each do |path|
        requests.clear
        path.call
        expect(requests.map { |r| r.questions.keys }).to eq([[:kind], [:case_type]])
        expect(requests.last.state).to include(kind: "new_case")
      end
    end

    it "takes after: as one field or a list, every collapse in the lens as the column holds it" do
      klass = stub_const("Twice", Class.new(Ticket) do
        judges :escalate, "q", after: %i[severity priority]
        scores :priority, "How urgent?", { "can wait" => 10, "today" => 20, "now" => 30 }, after: :grade
      end)
      stub_s1 { |req| requests << req and { escalate: 0.9, severity: 1, priority: 2, grade: 2 } }
      expect(klass.s1_fields[:escalate][:after]).to eq(%i[severity priority])
      expect(klass.s1_fields[:priority][:after]).to eq([:grade])
      row = klass.create!(body: "x")
      row.update_measure(:escalate, :severity, :priority, :grade)
      expect(requests.map { |r| r.questions.keys }).to eq([%i[severity grade], [:priority], [:escalate]])
      expect(requests[1].state).to include(grade: "good")
      expect(requests[2].state).to include(severity: "degraded", priority: "now") # the label, not the integer 30
      expect(row.reload.priority).to eq(30)
      expect(row.escalate).to be(true)
    end

    it "assigns provisionally inside measure; a field already written reads from the column" do
      row = Routing.create!(transcript: "I fell in a shop")
      clear_enqueued_jobs
      row.update!(kind: "existing")
      requests.clear
      row.measure(:kind, :case_type)
      expect(requests.last.state).to include(kind: "new_case") # stage 1's collapse, provisionally
      expect(row.reload.kind).to eq("existing")
      requests.clear
      row.update!(kind: "new_case")
      row.measure(:case_type)
      expect(requests.map { |r| r.questions.keys }).to eq([[:case_type]])
      expect(requests.last.state).to include(kind: "new_case") # the column
    end
  end

  describe "the gate: if: / unless: on a sequenced field" do
    it "is read when its stage runs, on the earlier answer — through the trigger, update_measure, measure_all and measure" do
      answers[:kind] = :existing
      row = Routing.create!(transcript: "checking on my case")
      perform_enqueued_jobs
      expect(requests.map { |r| r.questions.keys }).to contain_exactly([:kind], [:urgent])
      expect(row.reload).to have_attributes(kind: "existing", case_type: nil)
      expect(row.s1_answers.keys).to contain_exactly("kind", "urgent")
      requests.clear
      result = row.measure(:kind, :case_type)
      expect(result.distributions.keys).to eq([:kind])
      expect { result[:case_type] }.to raise_error(KeyError, /no answer for :case_type/)
      expect(Routing.where(id: row.id).measure_all(:kind, :case_type).values.map { |r| r.distributions.keys }).to eq([[:kind]])
      row.update_measure(:case_type)
      expect(row.s1_result.distributions).to be_empty # alone, still gated: the column says existing
      expect(requests.map { |r| r.questions.keys }).to eq([[:kind], [:kind]])
    end

    it "is not read by the bare verbs — a question asked is a question asked" do
      row = Routing.create!(transcript: "checking on my case", kind: "existing")
      clear_enqueued_jobs
      requests.clear
      expect(row.choose(:case_type)).to be_a(S1::Answer::Choice)
      expect(row.choice(:case_type)).to eq(:slip)
      expect(requests.map { |r| r.questions.keys }).to eq([[:case_type], [:case_type]])
      expect(requests.last.state).to include(kind: "existing")
    end

    it "keeps the sequenced field on its predecessor's trigger, its if: out of the callback" do
      expect(Routing.s1_triggers.values).to contain_exactly(%i[kind case_type], [:urgent])
      expect(Routing.s1_fields[:case_type]).to include(after: [:kind], conditions: { if: :new_case? }, measure_on: :transcript)
    end
  end

  describe "the guards" do
    it "raises on a cycle at declaration, naming it" do
      expect do
        Class.new(Ticket) do
          judges :escalate, "q", after: :severity
          scores :severity, "q", :a, :b, after: :escalate
        end
      end.to raise_error(ArgumentError, /after: cycle :escalate → :severity → :escalate/)
      expect { Class.new(Ticket) { judges :escalate, "q", after: :escalate } }.to raise_error(ArgumentError, /after: cycle :escalate → :escalate/)
    end

    it "verify! refuses after: naming no field" do
      expect { Class.new(Ticket) { judges :escalate, "q", after: :nope }.s1_verify_fields! }
        .to raise_error(ArgumentError, /after: :nope is not a measured field/)
    end
  end

  describe "the sharp knives" do
    it "s1_plan prints the stages, each call's form, lens and sequence, and every field's trigger" do
      expect(Routing.s1_plan.to_s).to eq(<<~PLAN.chomp)
        Routing.s1_plan — 2 stage(s), 2 call(s)
        stage 1
          call 1: as: :default  →  kind (measure_on: :transcript), urgent (measure_on: :save; writes urgent_probability)
        stage 2
          call 1: after: kind  →  case_type (dynamic, no scale methods; measure_on: :transcript)
      PLAN
      expect(Routing.s1_plan.stages.map { |s| s.map(&:fields) }).to eq([[%i[kind urgent]], [[:case_type]]])
      expect(Routing.s1_plan.batches.last.after).to eq([:kind])
      expect(Ticket.s1_plan.to_s).to eq(<<~PLAN.chomp)
        Ticket.s1_plan — 2 stage(s), 3 call(s)
        stage 1
          call 1: as: :default  →  escalate (writes escalate_probability), severity (writes severity_expectation, severity_index), priority, grade
          call 2: as: :planned, given: :department_lens  →  department (writes department_confidence)
        stage 2
          call 1: after: department  →  subtype (dynamic, no scale methods)
      PLAN
    end

    it "request shows the sequenced lens as the stages would send it" do
      row = Routing.create!(transcript: "I fell in a shop", kind: "new_case")
      clear_enqueued_jobs
      both = row.s1_request(:kind, :case_type)
      expect(both.map { |r| r.questions.keys }).to eq([[:kind], [:case_type]])
      expect(both.last.state).to eq(this: { transcript: "I fell in a shop" }, kind: "new_case")
      expect(requests).to be_empty
      expect(row.s1_request(:case_type).state).to include(kind: "new_case")
    end
  end
end
