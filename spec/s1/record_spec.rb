# frozen_string_literal: true

RSpec.describe S1::Measurable do
  let(:firm) { Firm.create!(name: "Dudley", preferences: { "sol_years" => 2 }) }
  let(:call) { PhoneCall.create!(firm: firm, transcript: "I need a lawyer, I was rear-ended yesterday") }

  describe "forms" do
    it "registers named forms and a default" do
      expect(PhoneCall.s1_states).to eq(%i[default review window])
    end

    it "builds the default form" do
      expect(call.s1_state).to eq(transcript: call.transcript)
    end

    it "takes arguments" do
      expect(call.s1_state(:window, last: 9)).to eq(transcript: "yesterday")
    end

    it "falls back to the attributes when nothing is declared — less the key, the timestamps, the audit and the measured columns" do
      expect(firm.s1_state).to eq(firm.attributes.except("id"))
      expect(Firm.s1_omitted).to eq(%w[id s1_answers created_at updated_at])
      legacy = LegacyCall.new(transcript: "hi", is_lead: true, lead_probability: 0.9)
      expect(legacy.s1_facts.keys).to include("transcript", "is_lead", "lead_probability")
      expect(legacy.s1_facts.keys).not_to include("id", "s1_answers", "created_at", "updated_at")
      klass = stub_const("Bare", Class.new(LegacyCall) { judges :is_lead, "Lead?", siblings: { probability: :lead_probability } })
      expect(klass.s1_omitted).to eq(%w[id s1_answers created_at updated_at is_lead lead_probability])
      row = klass.new(transcript: "hi", is_lead: true, lead_probability: 0.9, case_type: "mva")
      expect(row.s1_facts.keys).to include("transcript", "case_type")
      expect(row.s1_facts.keys).not_to include("is_lead", "lead_probability", "s1_answers")
      expect(klass.s1_plan.to_s).to include("default form (attributes): firm_id, transcript, case_type")
    end

    it "refuses arguments on the attributes fallback rather than dropping them" do
      expect { firm.s1_state(last: 9) }.to raise_error(ArgumentError, "Firm default form takes no arguments (got [:last])")
      expect { firm.as(last: 9) }.to raise_error(ArgumentError, /takes no arguments/)
      expect { firm.measure(lead: S1::Question::Noul.new(instructions: "q?")) }.to raise_error(ArgumentError, /got \[:lead\]/)
      expect(firm.s1_state(**{})).to eq(firm.attributes.except("id"))
    end

    it "raises on an unknown form" do
      expect { call.as(:nope) }.to raise_error(ArgumentError, /no s1_state :nope/)
    end

    it "inherits forms" do
      klass = Class.new(PhoneCall) { s1_state(:short) { { transcript: transcript[0, 6] } } }
      expect(klass.s1_states).to eq(%i[default review window short])
      expect(PhoneCall.s1_states).not_to include(:short)
    end
  end

  describe "#as" do
    it "is a State over the rendered form, tagged with owner and form" do
      subject = call.as(:review)
      expect(subject).to be_a(S1::State)
      expect(subject.rendered).to eq(transcript: call.transcript, firm: S1::Rendering.render(firm.attributes.except("id")))
      expect(subject.options).to eq(owner: call, form: :review)
    end

    it "renders once, at prepare: a later change to the record never reaches the state, lensed or not" do
      seen = []
      stub_s1 { |req| seen << req.state and { noul: 0.9 } }
      klass = stub_const("Lensed", Class.new(PhoneCall) do
        measurable_as { { transcript: transcript } }
        measured_against { { policy: firm.name } }
      end)
      row = klass.find(call.id)
      state = row.as
      row.transcript = "MUTATED"
      row.firm.name = "MUTATED"
      state.judge("q?")
      expect(seen.last).to eq(this: { transcript: "I need a lawyer, I was rear-ended yesterday" }, policy: "Dudley")
      state.given(rush: true).judge("q?")
      expect(seen.last).to eq(this: { transcript: "I need a lawyer, I was rear-ended yesterday" }, policy: "Dudley", rush: true)
      state.judge("q?", given: { rush: true })
      expect(seen.last).to eq(this: { transcript: "I need a lawyer, I was rear-ended yesterday" }, policy: "Dudley", rush: true)
      lensed = state.given(rush: true)
      row.transcript = "AGAIN"
      lensed.given(more: 1).judge("q?")
      expect(seen.last).to eq(this: { transcript: "I need a lawyer, I was rear-ended yesterday" }, policy: "Dudley", rush: true, more: 1)
      expect(lensed.record).to be(row)
      expect(lensed.lens).to eq(policy: "Dudley", rush: true)
      expect(state.lens).to eq(policy: "Dudley")
      expect(lensed.facts).to eq(transcript: "I need a lawyer, I was rear-ended yesterday")
      expect(lensed.evidence).to be(lensed.facts)
      expect(state.facts).to eq(transcript: "I need a lawyer, I was rear-ended yesterday")
      plain = call.as
      expect(plain.facts).to eq(plain.rendered)
      expect(plain.lens).to eq({})
      call.transcript = "MUTATED"
      plain.given(rush: true).judge("q?")
      expect(seen.last).to eq(this: { transcript: "I need a lawyer, I was rear-ended yesterday" }, rush: true)
    end

    it "takes provider:, model: and timeout: for the State, apart from the form's arguments" do
      seen = nil
      other = S1::Providers::Stub.new(noul: 0.1)
      S1.on_result { |_r, req| seen = req }
      stub_s1(noul: 0.9)
      expect(call.as(provider: other).judge("q?").to_f).to eq(0.1)
      expect(call.as(provider: other).given(p: 1).judge("q?").to_f).to eq(0.1)
      expect(call.judge("q?").to_f).to eq(0.9)
      call.as(model: "m2", timeout: 3).judge("q?")
      expect(seen.model).to eq("m2")
      expect(seen.timeout).to eq(3)
      call.as(:window, model: "m2", last: 5).judge("q?")
      expect(seen.model).to eq("m2")
      expect(seen.state).to eq(transcript: "erday")
      expect(call.to_s1(model: "m3").given(p: 1).send(:answerer)).to eq(["S1::Providers::Stub", "m3"])
      expect(LegacyCall.find(call.id).as(model: "m2").send(:answerer).last).to eq("m2")
    end

    it "does not recurse when two forms reference each other (item ↔ claims)" do
      firm_class = Class.new(Firm) do
        has_many :cycle_calls, foreign_key: :firm_id, class_name: "CycleCall"
        measurable_as do
          { name: name, calls: cycle_calls.to_a }
        end
      end
      call_class = Class.new(PhoneCall) do
        belongs_to :cycle_firm, foreign_key: :firm_id, class_name: "CycleFirm"
        measurable_as do
          { transcript: transcript, firm: cycle_firm }
        end
      end
      stub_const("CycleFirm", firm_class)
      stub_const("CycleCall", call_class)
      f = firm_class.find(firm.id)
      f.cycle_calls.create!(transcript: "a")
      state = nil
      expect { state = f.as_measurable.rendered }.not_to raise_error # a SystemStackError otherwise
      expect(state[:calls].first[:transcript]).to eq("a")
      expect(state[:calls].first[:firm]).to eq(f.attributes) # the cycle closes on attributes
    end

    it "renders a record met inside its own form as attributes, not recursion" do
      klass = Class.new(PhoneCall) { measurable_as(:selfie) { { me: self, transcript: transcript } } }
      state = klass.find(call.id).as_measurable(:selfie).rendered
      expect(state[:me]).to eq(S1::Rendering.render(call.attributes))
      expect(state[:me]["transcript"]).to eq(call.transcript)
      expect(state[:transcript]).to eq(call.transcript)
    end

    it "renders nested Measurable records through their default form" do
      Firm.s1_state { { name: name } }
      expect(call.as(:review).rendered[:firm]).to eq(name: "Dudley")
    ensure
      Firm.s1_states.delete(:default)
      Firm.remove_method(:s1_state_default)
    end
  end

  describe "the verbs on the record" do
    before { stub_s1(noul: 0.9, choice: :mva, score: 2) }

    it "delegates to the default form" do
      expect(call.judge?("Is this a lead?")).to be(true)
      expect(call.judge("Is this a lead?")).to be >= 0.9
      expect(call.measure { |q| q.judge :lead, "Lead?" }.true?(:lead)).to be(true)
      expect(call.is?("a lead")).to be(true)
      expect(S1.to_state(call)).to be_a(S1::Measurable::State)
      expect(S1.to_state(call, as: :window, last: 9).rendered).to eq(transcript: "yesterday")
      expect(call.choose("Type?", mva: "car", slip: "fall")).to be_a(S1::Answer::Choice)
      expect(call.score("Quality?", "D", "C", "B", "A")).to be_a(S1::Answer::Score)
    end

    it "has same_as / same_as?, the record's twin of where_same_as" do
      seen = nil
      stub_s1 { |req| seen = req.state and { noul: 0.9 } }
      expect(call.same_as("rear-ended")).to be_a(S1::Answer::Noul)
      expect(seen).to eq(this: { transcript: call.transcript }, other: "rear-ended")
      expect(call.same_as?("rear-ended")).to be(true)
      expect(call.same_as?("rear-ended", threshold: 0.95)).to be(false)
      expect(call.same_as?("rear-ended", given: { p: 1 })).to be(true)
      expect(seen).to eq(this: { transcript: call.transcript }, other: "rear-ended", p: 1)
      expect(call.method(:same_as).parameters.map(&:first)).to eq(call.method(:is).parameters.map(&:first))
    end

    it "the verb measures, the noun names, the ? collapses" do
      expect(call.judge("Is this a lead?")).to be_a(S1::Answer::Noul)
      expect(call.noul("Is this a lead?")).to be_a(S1::Answer::Noul)
      expect(call.noul("Is this a lead?").to_f).to eq(call.judge("Is this a lead?").to_f)
      expect(call.judge?("Is this a lead?")).to be(true)
      expect(call.judge?("Is this a lead?")).to eq(call.judge("Is this a lead?").collapse)
      expect(call.choice("Type?", mva: "car", slip: "fall")).to eq(:mva)
      expect(call.choice("Type?", mva: "car", slip: "fall")).to eq(call.choose("Type?", mva: "car", slip: "fall").collapse)
      expect(call.level("Quality?", "D", "C", "B", "A")).to eq("B")
      expect(call.level("Quality?", "D", "C", "B", "A")).to be_a(S1::Level)
      expect(call.level("Quality?", "D", "C", "B", "A")).to eq(call.score("Quality?", "D", "C", "B", "A").collapse)
    end

    it "works through predicates, with as: picking the form" do
      seen = nil
      stub_s1 { |req| seen = req.state and { noul: 0.9, choice: :mva } }
      expect([call].select(&S1.predicates.is?("x", as: :window))).to eq([call])
      expect(seen[:transcript].length).to eq(20)
      expect([call].group_by(&S1.predicates.choose("Type?", mva: "car", slip: "fall")).keys).to eq([:mva])
    end

    it "applies a predicate's given: over a Measurable record's declared lens" do
      klass = stub_const("Lensed2", Class.new(PhoneCall) do
        measurable_as { { t: transcript } }
        measured_against { { policy: "p", carrier: "c" } }
      end)
      seen = nil
      stub_s1 { |req| seen = req.state and { noul: 0.9 } }
      expect([klass.find(call.id)].select(&S1.predicates.is?("x", given: { policy: "strict" }))).not_to be_empty
      expect(seen).to eq(this: { t: call.transcript }, policy: "strict", carrier: "c")
    end

    it "switches the form for a predicate's as: on a record already prepared, keeping its lens and overrides" do
      seen = nil
      stub_s1 { |req| seen = req and { noul: 0.9 } }
      prepared = call.as(threshold: 0.95).given(rush: true)
      expect(S1.predicates.judge?("q", as: :window)[prepared]).to be(false)
      expect(seen.state).to eq(this: { transcript: call.transcript[-20..] }, rush: true)
      expect(seen.options).to eq(owner: call, form: :window)
      expect(S1.predicates.judge?("q", as: :default)[prepared]).to be(false)
      expect(seen.state).to eq(this: { transcript: call.transcript }, rush: true)
      expect(prepared.to_s1(as: :default)).to be(prepared)
      expect(prepared.to_s1(as: "window").form).to eq(:window)
      expect(prepared.to_s1(as: :window, trace: 1).options).to eq(owner: call, form: :window, trace: 1)
      expect(prepared.to_s1(trace: 1).options).to eq(owner: call, form: :default, trace: 1)
      expect(prepared.to_s1(as: :window).threshold).to eq(0.95)
    end

    it "never takes a record's form for the candidates: a choose with no categories raises, a label-list form still chooses" do
      stub_s1 { |req| { choice: req.questions[:choice].categories.last } }
      fields = stub_const("Fields", Class.new(PhoneCall) { measurable_as { { subject: "Refund please", body: transcript } } })
      row = fields.find(call.id)
      expect { row.choose("Which team?") }.to raise_error(S1::ValidationError, /choose needs a scale/)
      expect { row.choice("Which team?") }.to raise_error(S1::ValidationError, /choose needs a scale/)
      expect { [row].map(&S1.predicates.choice("Which team?")) }.to raise_error(S1::ValidationError, /choose needs a scale/)
      expect { row.given(p: 1).choose("Which team?") }.to raise_error(S1::ValidationError, /choose needs a scale/)
      expect(row.choice("Which team?", refunds: nil, billing: nil)).to be(:billing)
      labels = stub_const("Labels", Class.new(PhoneCall) { measurable_as { %w[Michael Bob] } })
      expect(labels.find(call.id).choice("Who?")).to be(:Bob)
      expect(labels.find(call.id).given(role: "chef").choose("Who?").categories).to eq(%i[Michael Bob])
    end

    it "passes the state through to the provider" do
      seen = nil
      stub_s1 { |req| seen = req.state and {} }
      call.as(:window, last: 9).judge?("q?")
      expect(seen).to eq(transcript: "yesterday")
    end
  end

  describe "#update_measure" do
    before { stub_s1(is_lead: 0.9, lead_probability: 0.9, case_type: :mva, quality: 2, quality_position: 2, quality_level: 2, extra: 0.7) }

    def questions(q)
      q.judge  :is_lead,          "Is this a lead?"
      q.judge  :lead_probability, "Is this a lead?"
      q.choose :case_type,        "Type?", mva: "car", slip: "fall"
      q.score  :quality,          "Quality?", "D", "C", "B", "A"
      q.score  :quality_position, "Quality?", "D", "C", "B", "A"
      q.score  :quality_level,    "Quality?", "D", "C", "B", "A"
      q.judge  :extra,            "Speculative, not a column"
    end

    it "writes distributions to columns, coerced by column type" do
      expect(call.update_measure { |q| questions(q) }).to be(true)
      result = call.s1_result
      call.reload
      expect(call.is_lead).to be(true)
      expect(call.lead_probability).to eq(0.9)
      expect(call.case_type).to eq("mva")
      expect(call.quality).to eq(2)
      expect(call.quality_position).to eq(2.0)
      expect(call.quality_level).to eq("B")
      expect(result[:extra].to_f).to eq(0.7)
      expect(call).not_to respond_to(:extra)
    end

    it "thresholds booleans with the state's threshold" do
      S1.config.threshold = 0.95
      call.update_measure { |q| q.judge :is_lead, "Lead?" }
      expect(call.reload.is_lead).to be(false)
    end

    it "keeps raw distributions in s1_answers when the column exists: the kind, the collapse as text, and a score's position" do
      call.update_measure(as: :review) { |q| q.judge :is_lead, "Lead?" }
      audit = call.reload.s1_answers.fetch("is_lead")
      expect(audit).to include("kind" => "noul", "value" => "true", "form" => "review", "model" => "stub")
      expect(audit["probabilities"]["true"]).to eq(0.9)
      expect(audit).not_to have_key("position")

      call.update_measure do |q|
        q.choose :case_type, "Type?", mva: "car", slip: "fall"
        q.score :quality, "Quality?", "D", "C", "B", "A"
      end
      expect(call.reload.s1_answers.keys).to contain_exactly("is_lead", "case_type", "quality")
      expect(call.s1_answers.fetch("case_type")).to include("kind" => "choice", "value" => "mva")
      expect(call.s1_answers.fetch("quality")).to include("kind" => "score", "value" => "B", "position" => 2)

      call.as(threshold: 0.95).update_measure { |q| q.judge :is_lead, "Lead?" }
      expect(call.reload.s1_answers.dig("is_lead", "value")).to eq("false")
    end

    it "yields the record to the block" do
      seen = nil
      call.update_measure { |q, record| seen = record and q.judge :is_lead, "Lead?" }
      expect(seen).to eq(call)
    end

    it "works on a model with no declared form" do
      legacy = LegacyCall.create!(transcript: "hi")
      legacy.update_measure { |q| q.judge :is_lead, "Lead?" }
      expect(legacy.reload.is_lead).to be(true)
    end

    it "runs validations as update does: false, nothing written, the Result still on the record" do
      allow(call).to receive(:valid?).and_return(false)
      expect(call.update_measure { |q| q.judge :is_lead, "Lead?" }).to be(false)
      expect(call.s1_result[:is_lead].to_f).to eq(0.9)
      expect(call.reload.is_lead).to be_nil
    end

    it "raises as update! does, with the bang" do
      allow(call).to receive(:valid?).and_return(false)
      expect { call.update_measure! { |q| q.judge :is_lead, "Lead?" } }.to raise_error(ActiveRecord::RecordInvalid)
      expect(call.s1_result[:is_lead].to_f).to eq(0.9)
    end

    it "returns true, and leaves the Result on the record in memory" do
      expect(call.update_measure! { |q| q.judge :is_lead, "Lead?" }).to be(true)
      expect(call.s1_result).to be_a(S1::Measurable::Result)
      expect(call.s1_result[:is_lead].to_f).to eq(0.9)
      expect(call.s1_result.model).to eq("stub")
    end
  end

  describe "#assign_measure" do
    before { stub_s1(case_type: :mva, extra: 0.7) }

    it "assigns without saving" do
      result = call.assign_measure { |q| q.choose(:case_type, "Type?", mva: "car", slip: "fall") and q.judge(:extra, "x?") }
      expect(call.case_type).to eq("mva")
      expect(call).to have_changes_to_save
      expect(call.reload.case_type).to be_nil
      expect(result[:extra].to_f).to eq(0.7)
    end

    it "enriches from a before_save, on create and on relevant change only" do
      asked = []
      stub_s1 { |req| asked << req.state[:transcript] and { case_type: req.state[:transcript].include?("fell") ? :slip : :mva } }

      triaged = TriagedCall.create!(transcript: "I fell in the store")
      expect(triaged.reload.case_type).to eq("slip")
      triaged.update!(legacy_score: 3)
      triaged.update!(transcript: "I was rear-ended")
      expect(triaged.reload.case_type).to eq("mva")
      expect(asked).to eq(["I fell in the store", "I was rear-ended"])
    end
  end

  describe ".update_measure_all" do
    before { firm }

    let!(:calls) { 5.times.map { |i| PhoneCall.create!(firm: firm, transcript: "call #{i}") } }

    it "updates every record in the relation, one ask per record" do
      asked = Queue.new
      stub_s1 { |req| asked << req.state[:transcript] and { is_lead: req.state[:transcript].end_with?("3") ? 0.9 : 0.1 } }

      results = PhoneCall.where("transcript LIKE ?", "call %").update_measure_all(concurrency: 3) do |q, record|
        q.judge :is_lead, "Lead? #{record.id}"
      end

      expect(results.keys).to match_array(calls)
      expect(results.values).to all(be_a(S1::Result))
      expect(asked.size).to eq(5)
      expect(PhoneCall.where(is_lead: true).pluck(:transcript)).to eq(["call 3"])
    end

    it "runs asks concurrently" do
      stub_s1 do |_|
        sleep 0.1
        { is_lead: 0.9 }
      end
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      PhoneCall.all.update_measure_all(concurrency: 5) { |q| q.judge :is_lead, "Lead?" }
      expect(Process.clock_gettime(Process::CLOCK_MONOTONIC) - started).to be < 0.3
    end

    it "honours the form and scoping" do
      stub_s1(is_lead: 0.9)
      PhoneCall.where(id: calls.first).update_measure_all(as: :review) { |q| q.judge :is_lead, "Lead?" }
      expect(PhoneCall.where(is_lead: true).count).to eq(1)
      expect(calls.first.reload.s1_answers.dig("is_lead", "form")).to eq("review")
    end
  end

  describe ".measure_all" do
    before { firm }

    let!(:calls) { 3.times.map { |i| PhoneCall.create!(firm: firm, transcript: "call #{i}") } }

    it "measures every record and writes nothing" do
      stub_s1(is_lead: 0.9)
      results = PhoneCall.all.measure_all(concurrency: 3) { |q, record| q.judge :is_lead, "Lead? #{record.id}" }
      expect(results.keys).to match_array(calls)
      expect(results.values.map { |r| r[:is_lead].to_f }).to all(eq(0.9))
      expect(PhoneCall.where(is_lead: true).count).to eq(0)
      expect(PhoneCall.all.measure_all { |q| q.judge :is_lead, "Lead?" }.size).to eq(3)
    end
  end

  describe ".where_judged / .where_judged_not" do
    it "keeps the Enumerable and s1_ spellings" do
      expect(PhoneCall.method(:measure_select)).to eq(PhoneCall.method(:where_judged))
      expect(PhoneCall.method(:s1_reject)).to eq(PhoneCall.method(:where_judged_not))
    end

    before { firm }

    let!(:calls) { 3.times.map { |i| PhoneCall.create!(firm: firm, transcript: "call #{i}") } }

    it "partitions the relation by a noul, one call per record" do
      stub_s1 { |req| { noul: req.state[:transcript].end_with?("1") ? 0.9 : 0.1 } }
      expect(PhoneCall.all.where_judged("Odd one?", concurrency: 3)).to eq([calls[1]])
      expect(PhoneCall.all.where_judged_not("Odd one?")).to eq([calls[0], calls[2]])
    end

    it "judges each record against given: context, and finds the records that are the same as a text" do
      stub_s1 { |req| { noul: req.state.is_a?(Hash) && req.state[:this].to_s.include?("1") && req.state[:other].to_s.include?("1") ? 0.9 : 0.1 } }
      expect(PhoneCall.all.where_same_as("call 1", concurrency: 3)).to eq([calls[1]])
      expect(PhoneCall.all.measure_grep("call 1")).to eq([calls[1]])
      stub_s1 { |req| { noul: req.state[:text].to_s.include?(req.state[:this][:transcript].to_s[-1]) ? 0.9 : 0.1 } }
      expect(PhoneCall.all.where_judged("Is `this` the call in `text`?", given: { text: "about call 2" })).to eq([calls[2]])
    end

    it "has where_is / where_is_not, the relation's is?" do
      asked = nil
      stub_s1 { |req| asked = req.questions[:noul].instructions and { noul: 0.9 } }
      expect(PhoneCall.where(id: calls.first).where_is("a lead")).to eq([calls.first])
      expect(asked).to eq("Is this a lead?")
      expect(PhoneCall.where(id: calls.first).where_is_not("a lead")).to eq([])
      expect(PhoneCall.method(:where_is).parameters).to include(%i[req phrase])
      expect(PhoneCall.method(:where_is_not).parameters).to include(%i[req phrase])
    end

    it "raises a per-record error once, through the thread's value, with nothing on stderr" do
      klass = stub_const("LeadCall", Class.new(PhoneCall) { measured_field :is_lead, "Is this a lead?" })
      stub_s1(is_lead: 0.9)
      expect { klass.all.where_judged(:case_type, concurrency: 3) }
        .to raise_error(ArgumentError, "case_type is a choice; use choose").and output("").to_stderr
    end

    it "takes a threshold and honours scoping" do
      stub_s1(noul: 0.8)
      expect(PhoneCall.where(id: calls.first).where_judged("q?", threshold: 0.9)).to eq([])
      expect(PhoneCall.where(id: calls.first).where_judged("q?", threshold: 0.7)).to eq([calls.first])
    end

    it "takes a declared column: each record's own question, collapsed at the threshold" do
      klass = stub_const("LeadCall", Class.new(PhoneCall) { measured_field :is_lead, "Is this a lead?" })
      asked = []
      stub_s1 { |req| asked << req.questions and { is_lead: (req.state[:transcript] || req.state.dig(:this, :transcript)).end_with?("1") ? 0.8 : 0.1 } }
      expect(klass.all.where_judged(:is_lead, concurrency: 3).ids).to eq([calls[1].id])
      expect(asked.last.keys).to eq([:is_lead])
      expect(asked.last[:is_lead].instructions).to eq("Is this a lead?")
      expect(klass.all.where_judged_not(:is_lead).ids).to eq([calls[0].id, calls[2].id])
      expect(klass.all.where_judged(:is_lead, threshold: 0.9)).to eq([])
      expect(klass.all.where_judged_not(:is_lead, threshold: 0.9).count).to eq(3)
      states = []
      stub_s1 { |req| states << req.state and { is_lead: req.state.dig(:this, :transcript).to_s.end_with?("1") ? 0.8 : 0.1 } }
      expect(klass.all.given(policy: "p").where_judged(:is_lead).ids).to eq([calls[1].id])
      expect(states).to all(include(policy: "p"))
      expect { klass.all.where_judged(:case_type) }.to raise_error(ArgumentError, "case_type is a choice; use choose")
      expect(klass.where(is_lead: true).count).to eq(0)
    end
  end

  describe "caching" do
    let(:asks) { [] }

    before do
      S1.config.cache = ActiveSupport::Cache::MemoryStore.new
      stub_s1 { |req| asks << req.state and { noul: 0.9, is_lead: 0.9 } }
    end

    it "asks once per record version, form, args and questions" do
      3.times { call.judge?("Lead?") }
      call.as(:window, last: 9).judge?("Lead?")
      call.as(:window, last: 3).judge?("Lead?")
      call.judge?("Other?")
      expect(asks.size).to eq(4)
    end

    it "is bypassed by a write, since update_measure bumps the version" do
      call.update_measure { |q| q.judge :is_lead, "Lead?" }
      call.update_measure { |q| q.judge :is_lead, "Lead?" }
      expect(asks.size).to eq(2)
    end

    it "keys on the lens too" do
      call.given(policy: "a").judge?("q?")
      call.given(policy: "b").judge?("q?")
      call.given(policy: "a").judge?("q?")
      expect(asks.size).to eq(2)
    end

    it "keys on the declared lens: a changed measured_against never serves the old policy's Result" do
      policy = +"A"
      klass = stub_const("Policed", Class.new(PhoneCall) do
        measurable_as { { transcript: transcript } }
        measured_against { { policy: policy.dup } }
      end)
      row = klass.find(call.id)
      2.times { row.judge?("q?") }
      policy.replace("B")
      row.judge?("q?")
      expect(asks.size).to eq(2)
      expect(asks.map { |a| a[:policy] }).to eq(%w[A B])
    end

    it "is bypassed for new and dirty records" do
      fresh = PhoneCall.new(firm: firm, transcript: "a")
      fresh.judge?("Lead?")
      PhoneCall.new(firm: firm, transcript: "b").judge?("Lead?")
      call.judge?("Lead?")
      call.transcript = "edited"
      call.judge?("Lead?")
      expect(asks.size).to eq(4)
    end

    it "is off without a configured cache" do
      S1.config.cache = nil
      2.times { call.judge?("Lead?") }
      expect(asks.size).to eq(2)
    end

    it "keys on who answers: the provider and the model" do
      call.judge?("Lead?")
      S1.config.provider = ->(req) { asks << req.state and S1::Result.new(answers: { noul: S1::Answer::Noul.new(id: :noul, probability: 0.1) }) }
      expect(call.judge?("Lead?")).to be(false)
      expect(asks.size).to eq(2)

      fakey = Class.new(S1::Providers::Stub) { settings :fakey, model: "m1" }
      S1::Providers.const_set(:Fakey, fakey)
      S1.reset_config!
      S1.config.cache = ActiveSupport::Cache::MemoryStore.new
      S1.config.provider = :fakey
      2.times { call.judge?("Lead?") }
      S1.config.fakey.model = "m2"
      2.times { call.judge?("Lead?") }
      expect(asks.size).to eq(2) # the class stub answers, not the block one: only the key changed
      expect(S1.config.cache.instance_variable_get(:@data).keys.grep(/fakey/).size).to eq(2)
    ensure
      S1::Providers.send(:remove_const, :Fakey)
      S1::Config.sections.delete(:fakey)
      S1::Config.send(:remove_method, :fakey)
    end

    it "keys on a State's own provider and model" do
      2.times { call.as(model: "m1").judge?("Lead?") }
      2.times { call.as(model: "m2").judge?("Lead?") }
      expect(asks.size).to eq(2)
      stub = S1::Providers::Stub.new(noul: 0.9)
      2.times { call.as(provider: stub).judge?("Lead?") }
      expect(asks.size).to eq(2)
      expect(S1.config.cache.instance_variable_get(:@data).keys.size).to eq(3)
    end

    it "keys an instance provider by its own model, and one with none by identity: two instances never share an entry" do
      expect(call.as(provider: S1::Providers::Stub.new(noul: 0.9)).judge?("Lead?")).to be(true)
      expect(call.as(provider: S1::Providers::Stub.new(noul: 0.1)).judge?("Lead?")).to be(false)
      expect(S1.config.cache.instance_variable_get(:@data).keys.size).to eq(2)
      jev1 = S1::Providers::TypeSafe.new(model: "jev-1", api_key: "k")
      jev2 = S1::Providers::TypeSafe.new(model: "jev-2", api_key: "k")
      key = ->(provider) { call.as(provider: provider).send(:answerer) }
      expect(key.call(jev1)).to eq(["S1::Providers::TypeSafe", "jev-1"])
      expect(key.call(jev2)).to eq(["S1::Providers::TypeSafe", "jev-2"])
      expect(key.call(S1::Providers::TypeSafe.new(model: "jev-1", api_key: "other"))).to eq(key.call(jev1))
      expect(call.as(provider: jev2, model: "m").send(:answerer)).to eq(["S1::Providers::TypeSafe", "m"])
      expect(key.call(S1::Providers::Stub.new)).not_to eq(key.call(S1::Providers::Stub.new))
    end

    it "never caches a record whose key carries no version: a write would never bump it" do
      firm = Firm.create!(name: "Dudley")
      expect(firm.cache_key_with_version).to eq("firms/#{firm.id}")
      stub_s1 { |req| asks << req.state and { noul: req.state["name"] == "Dudley" ? 0.9 : 0.1 } }
      expect(firm.judge?("q?")).to be(true)
      firm.update!(name: "Other")
      expect(firm.judge?("q?")).to be(false)
      expect(asks.size).to eq(2)
      expect(S1.config.cache.instance_variable_get(:@data)).to be_empty
    end

    it "hands a cached Result to a stricter State at that State's threshold" do
      expect(call.measure { |q| q.judge :is_lead, "Lead?" }.to_h).to eq(is_lead: true)
      expect(call.as(threshold: 0.95).measure { |q| q.judge :is_lead, "Lead?" }.to_h).to eq(is_lead: false)
      expect(call.as(threshold: 0.95).batch { |q| q.judge :is_lead, "Lead?" }[:is_lead].threshold).to eq(0.95)
      expect(call.as(threshold: 0.95).judge?("Lead?")).to be(false)
      expect(call.measure { |q| q.judge :is_lead, "Lead?" }[:is_lead].threshold).to eq(0.5)
      expect(asks.size).to eq(2)
    end

    it "stamps the config's threshold at serve time on a cached Result handed to a threshold-less State" do
      first = call.measure { |q| q.judge :is_lead, "Lead?" }[:is_lead]
      expect(first.threshold).to eq(0.5)
      S1.config.threshold = 0.95
      served = call.measure { |q| q.judge :is_lead, "Lead?" }[:is_lead]
      expect(asks.size).to eq(1)
      expect(served.threshold).to eq(0.95)
      expect(served.collapse).to be(false)
      S1.config.threshold = 0.5
      expect(served.collapse).to be(false)
      expect(first.collapse).to be(true)
      expect(call.measure { |q| q.judge :is_lead, "Lead?" }[:is_lead].threshold).to eq(0.5)
    end

    it "is used by measure / batch / ask_about on the record's State too" do
      subject = call.as
      subject.measure { |q| q.judge :is_lead, "Lead?" }
      subject.batch { |q| q.judge :is_lead, "Lead?" }
      subject.ask_about { |q| q.judge :is_lead, "Lead?" }
      expect(asks.size).to eq(1)
    end
  end
end
