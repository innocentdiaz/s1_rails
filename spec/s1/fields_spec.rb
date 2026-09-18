# frozen_string_literal: true

# A declared field, measured: every spelling reaches one code path, the field's own
# form / lens / threshold / provider apply unless the call says otherwise, fields that
# differ split into calls and stages (s1_plan), and the sharp knives expose each layer.
RSpec.describe "declared fields, measured" do
  let(:ticket) { Ticket.create!(body: "I have asked three times. Can I talk to a real person?", plan: "gold") }
  let(:requests) { [] }

  before do
    stub_s1 do |req|
      requests << req
      { escalate: 0.75, department: :billing, severity: 1, priority: 2, subtype: :missing, grade: 2, extra: 0.4 }
    end
  end

  describe "one code path" do
    # department is declared as: :planned, given: :department_lens — the routing is the field's, not the call's.
    let(:paths) do
      {
        "record.choose(:col)" => -> { ticket.choose(:department) },
        "record.choice(:col)" => -> { ticket.choice(:department) },
        "record.measure(:col)" => -> { ticket.measure(:department) },
        "record.measure { q.choose :col }" => -> { ticket.measure { |q| q.choose :department } },
        "record.measure { q.choose :col, wording }" => -> { ticket.measure { |q| q.choose :department, "Which team?" } },
        "record.update_measure(:col)" => -> { ticket.update_measure(:department) },
        "record.assign_measure(:col)" => -> { ticket.assign_measure(:department) },
        "record.update_measure_later(:col)" => -> { ticket.update_measure_later(:department) and perform_enqueued_jobs },
        "Model.measure_all(:col)" => -> { Ticket.where(id: ticket.id).measure_all(:department) },
        "Model.update_measure_all(:col)" => -> { Ticket.where(id: ticket.id).update_measure_all(:department) },
        "ψ.choice(:col)" => -> { [ticket].group_by(&S1.predicates.choice(:department)) },
        "ψ.choose(:col)" => -> { [ticket].map(&S1.predicates.choose(:department)) },
        "record.as.request(:col)" => -> { requests << ticket.as.request(:department) },
        "record.s1_request { q.choose :col }" => -> { requests << ticket.s1_request { |q| q.choose :department } }
      }
    end

    it "sends the same Request — state and question — from every spelling" do
      expected_state = { this: { body: ticket.body, plan: "gold" }, policy: "30 days", desk: "front" }
      expected_question = S1::Question::Choice.new(instructions: "Which team?",
                                                   criteria: { "returns" => "Refunds, exchanges",
                                                               "billing" => "Charges, invoices. Not: an insurer asking about a claim" })
      paths.each do |name, path|
        requests.clear
        path.call
        expect(requests.size).to eq(1), "#{name}: #{requests.size} requests"
        request = requests.first
        expect(request).to be_a(S1::Request), name
        expect(request.state).to eq(expected_state), name
        expect(request.questions).to eq(department: expected_question), name
        expect(request.options).to eq(owner: ticket, form: :planned), name
      end
    end

    it "sends the same Request for a judge and a score, through the verbs, the ? and the noun" do
      judge = { "judge" => -> { ticket.judge(:escalate) }, "judge?" => -> { ticket.judge?(:escalate) },
                "where_judged" => -> { Ticket.where(id: ticket.id).where_judged(:escalate) },
                "ψ.judge?" => -> { [ticket].select(&S1.predicates.judge?(:escalate)) },
                "request" => -> { requests << ticket.s1_request(:escalate) } }
      judge.each_value(&:call)
      expect(requests.map(&:state).uniq).to eq([{ this: { body: ticket.body }, policy: "30 days" }])
      expect(requests.map(&:questions).uniq).to eq([{ escalate: S1::Question::Noul.new(instructions: "Is the customer asking for a human agent?",
                                                                                       criteria: { true: "asks for a person; threatens to leave",
                                                                                                   false: "a routine request" }) }])
      requests.clear
      score = { "score" => -> { ticket.score(:severity) }, "level" => -> { ticket.level(:severity) },
                "ψ.level" => -> { [ticket].map(&S1.predicates.level(:severity)) }, "request" => -> { requests << ticket.s1_request(:severity) } }
      score.each_value(&:call)
      expect(requests.map(&:questions).uniq)
        .to eq([{ severity: S1::Question::Score.new(instructions: "How severe is the issue?",
                                                    criteria: ["no impact", "a workaround exists",
                                                               "no workaround"]) }])
    end

    it "measures under the call's form and lens when the call names them: call-site > field > declared" do
      ticket.as(:default).choose(:department)
      expect(requests.last.state).to eq(this: { body: ticket.body }, policy: "30 days", desk: "front")
      expect(requests.last.options[:form]).to eq(:default)
      ticket.as(:planned, given: { desk: "back", extra: 1 }).choose(:department)
      expect(requests.last.state).to eq(this: { body: ticket.body, plan: "gold" }, policy: "30 days", desk: "back", extra: 1)
      ticket.choose(:department, given: { policy: "none" })
      expect(requests.last.state).to include(policy: "none", desk: "front")
      Ticket.where(id: ticket.id).given(desk: "side").measure_all(:department)
      expect(requests.last.state).to include(desk: "side")
      ticket.update_measure_later(:department, as: :default)
      perform_enqueued_jobs
      expect(requests.last.options[:form]).to eq(:default)
    end
  end

  describe "the field's threshold" do
    it "collapses the judge unless the call or the State says otherwise; a float sibling keeps the mass" do
      expect(ticket.judge(:escalate).threshold).to eq(0.7)
      expect(ticket.judge?(:escalate)).to be(true)
      expect(ticket.judge?(:escalate, threshold: 0.8)).to be(false)
      expect(ticket.as(threshold: 0.9).judge?(:escalate)).to be(false)
      expect(ticket.as(threshold: 0.9).judge(:escalate).threshold).to eq(0.9)
      expect(Ticket.where(id: ticket.id).where_judged(:escalate)).to eq([ticket])
      expect(Ticket.where(id: ticket.id).where_judged(:escalate, threshold: 0.8)).to eq([])
      ticket.update_measure(:escalate)
      expect(ticket.reload.escalate).to be(true)
      expect(ticket.escalate_probability).to eq(0.75)
      expect(ticket.s1_answers.dig("escalate", "value")).to eq("true")
      ticket.as(threshold: 0.8).update_measure(:escalate)
      expect(ticket.reload.escalate).to be(false)
      expect(ticket.measure(:escalate) { |q| q.judge :extra, "x?" }[:extra].threshold).to eq(0.5)
    end
  end

  describe "the field's provider and model" do
    it "route the field's call, and split it from the others; the State's own win" do
      other = S1::Providers::Stub.new(escalate: 0.1)
      klass = stub_const("Routed", Class.new(Ticket) do
        judges :escalate, "q", provider: other
        scores :severity, "q", :a, :b, model: "cheap"
      end)
      row = klass.find(ticket.id)
      expect(row.judge(:escalate).to_f).to eq(0.1)
      result = row.measure(:escalate, :severity, :priority)
      expect(result.distributions.keys).to eq(%i[escalate severity priority])
      expect(result[:escalate].to_f).to eq(0.1)
      expect(requests.map(&:questions).map(&:keys)).to eq([[:severity], [:priority]]) # the stub above saw escalate
      expect(requests.map(&:model)).to eq(["cheap", nil])
      expect(klass.s1_plan(:escalate, :severity, :priority).size).to eq(3)
      expect(klass.s1_plan(:escalate, :severity, :priority, provider: :x, model: "m").size).to eq(1)
      requests.clear
      expect(row.as(provider: S1.config.provider, model: "m").measure(%i[escalate severity]).distributions.keys).to eq(%i[escalate severity])
      expect(requests.size).to eq(1)
      expect(requests.last.model).to eq("m")
    end
  end

  describe "s1_plan" do
    it "prints the stages and calls the registry implies" do
      plan = Ticket.s1_plan
      expect(plan.stages.map { |s| s.map(&:fields) }).to eq([[%i[escalate severity priority grade], [:department]], [[:subtype]]])
      expect(plan.size).to eq(3)
      expect(plan.to_s).to eq(<<~PLAN.chomp)
        Ticket.s1_plan — 2 stage(s), 3 call(s)
        stage 1
          call 1: as: :default  →  escalate (writes escalate_probability), severity (writes severity_expectation, severity_index), priority, grade
          call 2: as: :planned, given: :department_lens  →  department (writes department_confidence)
        stage 2
          call 1: after: department  →  subtype (dynamic, no scale methods)
      PLAN
      expect(Ticket.s1_plan(:department, :escalate, as: :default).batches.map(&:fields)).to eq([[:department], [:escalate]]) # the lens still splits
      expect(Ticket.s1_plan(:department, :escalate, as: :default).batches.map(&:as)).to eq(%i[default default])
      expect(Ticket.s1_plan(:subtype).stages.size).to eq(1)
      expect(Ticket.s1_plan.inspect).to include("S1::Measurable::Plan Ticket")
    end
  end

  describe "stages (after:) and dynamic scales" do
    it "measures a field after the fields it names are written, so its dynamic scale reads them" do
      expect(ticket.update_measure(:department, :subtype)).to be(true)
      result = ticket.s1_result
      expect(requests.map { |r| r.questions.keys }).to eq([[:department], [:subtype]])
      expect(requests.last.questions[:subtype].categories).to eq(%w[overcharge missing])
      expect(requests.last.state).to eq(this: { body: ticket.body }, policy: "30 days", department: "billing") # the sequenced lens
      expect(result.distributions.keys).to eq(%i[department subtype])
      expect(result.model).to eq("stub")
      expect(result.usage).to eq(input_tokens: 0, output_tokens: 0)
      expect(ticket.reload.department).to eq("billing")
      expect(ticket.subtype).to eq("missing")
      expect(ticket.s1_answers.keys).to contain_exactly("department", "subtype")
    end

    it "assigns provisionally inside measure and puts the record back; update_measure keeps everything" do
      ticket.update!(department: "returns")
      requests.clear
      result = ticket.measure(:subtype, :department) { |q| q.judge :extra, "x?" }
      expect(requests.map { |r| r.questions.keys }).to eq([[:extra], [:department], [:subtype]]) # extra: the default form, its own call
      expect(requests.last.questions[:subtype].categories).to eq(%w[overcharge missing]) # stage 2 saw billing, the provisional collapse
      expect(result.distributions.keys).to eq(%i[subtype department extra])
      expect(ticket.department).to eq("returns")
      expect(ticket).not_to have_changes_to_save
      expect(ticket.s1_answers).to be_nil
      stub_s1 { |req| requests << req and {} }
      ticket.measure(:subtype)
      expect(requests.last.questions[:subtype].categories).to eq(%w[damaged unwanted]) # alone: the record as it stands
    end

    it "evaluates a dynamic scale on the record — categories from a Proc, levels by description" do
      klass = stub_const("Dynamic", Class.new(Ticket) do
        chooses :subtype, "q", categories: -> { plan == "gold" ? { vip: "gold" } : { std: "plain" } }
        scores :severity, "q", levels: -> { plan == "gold" ? { low: "low for gold", high: "high for gold" } : %w[a b] }, siblings: false
      end)
      row = klass.find(ticket.id)
      expect { row.choose(:subtype) }.to raise_error(S1::ValidationError, /at least 2/)
      expect(row.s1_request(:severity).questions[:severity].levels).to eq(["low for gold", "high for gold"])
      stub_s1(severity: 1)
      expect(row.level(:severity)).to eq("high")
      row.update_measure(:severity)
      expect(row.reload.severity).to eq("high")
      expect(row.severity_index).to be_nil # siblings: false
    end
  end

  describe "a score shown by description" do
    it "shows the descriptions, stores the label, and the distribution speaks the label: the verb's collapse is the noun" do
      expect(ticket.s1_request(:severity).questions[:severity].levels).to eq(["no impact", "a workaround exists", "no workaround"])
      expect(ticket.score(:severity).level).to eq("degraded")
      expect(ticket.score(:severity).levels.map(&:to_s)).to eq(%w[cosmetic degraded blocking])
      expect(ticket.score(:severity).collapse).to eq(ticket.level(:severity))
      expect(ticket.measure(:severity).collapse).to eq(severity: "degraded")
      expect(ticket.level(:severity)).to eq("degraded")
      expect(ticket.level(:severity)).to be_a(S1::Level)
      expect(ticket.level(:severity).position).to eq(1)
      expect(ticket.level(:severity) >= "cosmetic").to be(true)
      ticket.update_measure(:severity, :priority, :grade)
      ticket.reload
      expect(ticket.severity).to eq("degraded")
      expect(ticket.severity_index).to eq(1)
      expect(ticket.priority).to eq(30)
      expect(ticket.grade).to eq("good")
      expect(ticket.s1_answers.dig("severity", "value")).to eq("degraded")
      expect(ticket.s1_answers.dig("severity", "position")).to eq(1)
      expect(ticket.measurement(:severity).collapse).to eq(ticket.level(:severity))
      expect(ticket.s1_answers.dig("priority", "value")).to eq("now")
    end
  end

  describe "siblings" do
    it "writes the distribution's parts beside the collapse" do
      ticket.update_measure(:department)
      expect(ticket.reload.department_confidence).to eq(1.0)
      ticket.update_measure(:escalate)
      expect(ticket.reload.escalate_probability).to eq(0.75)
    end
  end

  describe "measurement" do
    it "rebuilds the distribution a field was written from, out of s1_answers" do
      expect(ticket.measurement(:escalate)).to be_nil
      ticket.update_measure(:escalate, :department, :severity)
      ticket.reload
      noul = ticket.measurement(:escalate)
      expect(noul).to be_a(S1::Answer::Noul)
      expect(noul.to_f).to eq(0.75)
      expect(noul.threshold).to eq(0.7)
      expect(noul.true?(0.9)).to be(false)
      expect(ticket.measurement(:department)).to be_a(S1::Answer::Choice)
      expect(ticket.measurement(:department).to_sym).to eq(:billing)
      expect(ticket.measurement(:department)[:billing]).to eq(1.0)
      score = ticket.measurement(:severity)
      expect(score).to be_a(S1::Answer::Score)
      expect(score.level).to eq("degraded")
      expect(score.levels.map(&:to_s)).to eq(%w[cosmetic degraded blocking])
      expect { Delivery.create!(status: :attempted).measurement(:status) }
        .to raise_error(ArgumentError, "Delivery: measurement needs an s1_answers column")
    end
  end

  describe "the inline override" do
    it "keeps the declared criteria under other wording, and takes inline criteria over them" do
      ticket.measure { |q| q.judge :escalate, "Other wording?" }
      expect(requests.last.questions[:escalate].instructions).to eq("Other wording?")
      expect(requests.last.questions[:escalate].criteria).to eq("true" => "asks for a person; threatens to leave", "false" => "a routine request")
      ticket.measure { |q| q.judge :escalate, "Other wording?", true: "x" }
      expect(requests.last.questions[:escalate].criteria).to eq("true" => "x")
      ticket.measure { |q| q.score :severity, "Other?", "a", "b" }
      expect(requests.last.questions[:severity].levels).to eq(%w[a b])
      stub_s1 { |req| requests << req and {} }
      ticket.measure { |q| q.choose :department, "Other?", x: "X", y: "Y" }
      expect(requests.last.questions[:department].categories).to eq(%w[x y])
      expect(requests.last.options[:form]).to eq(:planned) # still the field's form
    end
  end

  describe "the job" do
    it "carries column names, building them on the reloaded record, beside serialized questions" do
      ticket.update_measure_later(:department, :subtype) { |q| q.judge :extra, "x?" }
      job = enqueued_jobs.last
      expect(job["arguments"][1]).to be_nil
      expect(job["arguments"][2].keys - ["_aj_symbol_keys"]).to eq(["extra"])
      expect(job["arguments"][5]).to eq(%w[department subtype])
      perform_enqueued_jobs
      expect(requests.map { |r| r.questions.keys }).to eq([%i[extra], %i[department], %i[subtype]])
      expect(ticket.reload.subtype).to eq("missing")
      expect { ticket.update_measure_later }.to raise_error(S1::ValidationError, /no questions given/)
    end
  end

  describe "the sharp knives" do
    it "request returns the Request(s) without a call, and never a cache hit, hook or write" do
      S1.config.cache = ActiveSupport::Cache::MemoryStore.new
      hooks = []
      S1.on_result { |r, _| hooks << r }
      request = ticket.as.request(:escalate)
      expect(request).to be_a(S1::Request)
      expect(request.timeout).to eq(30)
      expect(request.model).to be_nil
      both = ticket.s1_request(:escalate, :department)
      expect(both.map { |r| r.questions.keys }).to eq([[:escalate], [:department]])
      expect(ticket.as(model: "m", timeout: 3).request { |q| q.judge :x, "q?" }).to have_attributes(model: "m", timeout: 3)
      expect(requests).to be_empty
      expect(hooks).to be_empty
      expect(ticket.reload.escalate).to be_nil
      ticket.judge?(:escalate)
      expect(requests.size).to eq(1)
      ticket.as.request(:escalate)
      ticket.judge?(:escalate)
      expect(requests.size).to eq(1) # cached; the dry run neither served nor stored
    end

    it "s1_fields is the frozen registry; a wrong verb names the right one; a column option belongs in its declaration" do
      expect { Ticket.s1_fields[:x] = {} }.to raise_error(FrozenError)
      expect { ticket.judge?(:department) }.to raise_error(ArgumentError, "department is a choice; use choose")
      expect { ticket.choose(:severity) }.to raise_error(ArgumentError, "severity is a score; use score")
      expect { ticket.level(:escalate) }.to raise_error(ArgumentError, "escalate is a noul; use judge")
      expect { ticket.judge(:escalate, true: "x") }.to raise_error(ArgumentError, /pass options in its declaration/)
    end
  end
end
