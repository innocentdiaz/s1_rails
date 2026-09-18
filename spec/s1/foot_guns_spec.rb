# frozen_string_literal: true

# The reviewed foot-guns, each closed by a raise that names the spelling, a check at boot, or
# one code path where two spellings used to diverge: the dry run is the Request sent; a block
# question on a declared column keeps the column's kind and scale; a lens merges from every
# spelling; a trigger fires for the caller's changes and never twice for a measurement's own.
RSpec.describe "foot-guns" do
  let(:requests) { [] }
  let(:ticket) { Ticket.create!(body: "I have asked three times. Can I talk to a real person?", plan: "gold") }

  def answers(**canned) = stub_s1 { |req| requests << req and canned }
  def fields(&) = Class.new(Ticket, &).s1_fields
  def fresh(table, &) = Class.new(ActiveRecord::Base) { self.table_name = table }.tap { |k| k.include(S1::Measurable) }.tap { |k| k.class_eval(&) }

  describe "the dry run is the Request sent" do
    it "computes a sequenced lens at the call-site threshold, as the measurement does" do
      klass = stub_const("Dry", Class.new(Ticket) { chooses :department, "Which, given `escalate`?", **Ticket::DEPARTMENTS, after: :escalate })
      row = klass.find(ticket.id)
      expect(row.as(threshold: 0.9).request(%i[escalate department]).last.state).to include(escalate: false)
      expect(row.as(threshold: 0.3).request(%i[escalate department]).last.state).to include(escalate: true)
      answers(escalate: 0.5, department: :billing)
      result = row.as(threshold: 0.9).measure(%i[escalate department])
      expect(requests.last.state).to include(escalate: false)
      expect(result[:escalate].collapse).to be(false)
    end

    it "shows a later stage's form re-rendered with the provisional collapse, whatever the form is called" do
      klass = stub_const("Reformed", Class.new(Routing) do
        measurable_as { { transcript: transcript, kind: kind } }
        measurable_as(:other) { { transcript: transcript, kind: kind } }
        judges :urgent, "Urgent, given `kind`?", after: :kind, as: :other
      end)
      row = klass.create!(transcript: "x")
      clear_enqueued_jobs
      requests = row.s1_request(:kind, :case_type, :urgent)
      expect(requests.map { |r| r.questions.keys }).to eq([[:kind], [:case_type], [:urgent]])
      expect(requests[1].state).to eq(this: { transcript: "x", kind: "new_case" }, kind: "new_case")
      expect(requests[2].state).to eq(this: { transcript: "x", kind: "new_case" }, kind: "new_case")
    end
  end

  describe "a block question on a declared column keeps the column's kind and scale" do
    before { answers(escalate: 0.9, priority: 1, severity: 1, department: :billing) }

    it "raises under the wrong verb, naming the right one, on every path" do
      expect { ticket.update_measure { |q| q.judge :priority, "q?" } }.to raise_error(ArgumentError, "priority is a score; use score")
      expect { ticket.measure { |q| q.score :escalate, "q", "a", "b" } }.to raise_error(ArgumentError, "escalate is a noul; use judge")
      expect { ticket.s1_request { |q| q.choose :escalate, "q", a: "A", b: "B" } }.to raise_error(ArgumentError, "escalate is a noul; use judge")
      expect { ticket.update_measure_later { |q| q.judge :department, "q" } }.to raise_error(ArgumentError, "department is a choice; use choose")
      expect(requests).to be_empty
      expect(ticket.reload.priority).to be_nil
    end

    it "refuses to write a distribution over another scale into the column, and keeps it on measure" do
      result = ticket.measure { |q| q.score :severity, "Reworded?", "trivial", "critical" }
      expect(result[:severity].levels.map(&:to_s)).to eq(%w[trivial critical])
      message = ":severity is declared over [\"cosmetic\", \"degraded\", \"blocking\"]; a measurement over [\"trivial\", \"critical\"] " \
                "does not collapse into its column — ask it under another id, or reword without a scale (q.score :severity, \"…\")"
      expect { ticket.update_measure { |q| q.score :severity, "Reworded?", "trivial", "critical" } }.to raise_error(ArgumentError, "Ticket: #{message}")
      answers(department: :x, severity: 1)
      expect { ticket.update_measure { |q| q.choose :department, "Other?", x: "X", y: "Y" } }
        .to raise_error(ArgumentError, /:department is declared over \["returns", "billing"\].*\(q\.choose :department, "…"\)/)
      expect(ticket.reload).to have_attributes(severity: nil, department: nil)
      ticket.update_measure { |q| q.score :severity, "Reworded?" }
      expect(ticket.reload.severity).to eq("degraded")
    end

    it "never writes the primary key, a timestamp, the audit, or an undeclared column of another kind" do
      expect { ticket.update_measure { |q| q.judge :id, "?" } }.to raise_error(ArgumentError, "Ticket: :id is not a column a measurement collapses into")
      expect { ticket.update_measure { |q| q.judge :updated_at, "?" } }.to raise_error(ArgumentError, /:updated_at is not a column/)
      expect { ticket.update_measure { |q| q.judge :s1_answers, "?" } }.to raise_error(ArgumentError, /:s1_answers is not a column/)
      expect { ticket.update_measure { |q| q.judge :plan, "?" } }
        .to raise_error(ArgumentError, "Ticket: a noul does not collapse into :plan (column type :string); declare it with chooses or scores")
      expect(ticket.reload).to have_attributes(plan: "gold", s1_answers: nil)
      expect(ticket.id).to be > 0
    end

    it "forgets an earlier call's labels on a reused State" do
      state = ticket.as
      state.measure { |q| q.score :severity }
      result = state.measure { |q| q.score :severity, "how?", "x", "y" }
      expect(result[:severity].levels.map(&:to_s)).to eq(%w[x y])
    end

    it "carries a declared score's stored labels into the job, so the column gets the label and not the description" do
      ticket.update_measure_later { |q| q.score :severity }
      expect(enqueued_jobs.last["arguments"][2]["severity"]).to include("stores" => %w[cosmetic degraded blocking], "type" => "score")
      perform_enqueued_jobs
      expect(ticket.reload.severity).to eq("degraded")
      expect(ticket.s1_answers["severity"]).to include("scale" => %w[cosmetic degraded blocking], "value" => "degraded")
      expect(ticket.measurement(:severity).level).to eq(ticket.level(:severity))
      expect(ticket).not_to be_stale(:severity)
    end
  end

  describe "a lens merges from every spelling" do
    before { answers(escalate: 0.9) }

    it "merges given: over a Relation.given(…) scope on measure_all, update_measure_all and where_judged" do
      scope = Ticket.where(id: ticket.id).given(scope_key: "s")
      scope.measure_all(:escalate, given: { kw_key: "k" })
      expect(requests.last.state).to include(policy: "30 days", scope_key: "s", kw_key: "k")
      scope.update_measure_all(:escalate, given: { kw_key: "k" })
      expect(requests.last.state).to include(scope_key: "s", kw_key: "k")
      scope.where_judged(:escalate, given: { kw_key: "k" })
      expect(requests.last.state).to include(scope_key: "s", kw_key: "k")
    end

    it "evaluates a Proc at the top of measured_against on the record, as given: does" do
      klass = stub_const("LensedProc", Class.new(Ticket) { measured_against { { policy: -> { "p-#{plan}" } } } })
      expect(klass.find(ticket.id).s1_request(:escalate).state).to include(policy: "p-gold")
      expect(klass.find(ticket.id).s1_request(:escalate, given: { policy: -> { "q-#{plan}" } }).state).to include(policy: "q-gold")
    end

    it "refuses a call-site given: whose key is a predecessor's name — the gate and the lens read one collapse" do
      row = Routing.create!(transcript: "x", kind: "new_case")
      clear_enqueued_jobs
      expect { row.s1_request(:case_type, given: { kind: "existing" }) }
        .to raise_error(ArgumentError, /given: :kind is a field :case_type comes after; its collapse is that key — write the column/)
      expect(row.s1_request(:case_type).state).to include(kind: "new_case")
    end

    it "batches two fields into one call when the call-site lens covers the field's whole lens" do
      answers(escalate: 0.9, department: :billing)
      ticket.as(:planned, given: { desk: "x" }).measure(%i[department escalate])
      expect(requests.size).to eq(1)
      expect(requests.last.state).to include(desk: "x")
      requests.clear
      ticket.as(:planned).measure(%i[department escalate])
      expect(requests.size).to eq(2)
    end
  end

  describe "the declaration names its own spelling" do
    it "refuses another kind's scale word, naming both macros" do
      expect { fields { chooses :department, "q", levels: %w[a b] } }
        .to raise_error(ArgumentError, /levels: is a scores' scale; :department is declared with chooses/)
      expect { fields { chooses :department, "q", indexes: { a: 1 } } }.to raise_error(ArgumentError, /indexes: is a scores' scale/)
      expect { fields { scores :severity, "q", categories: %w[a b] } }
        .to raise_error(ArgumentError, /categories: is a chooses' scale; :severity is declared with scores/)
      expect { fields { scores :severity, "q", choices: %w[a b] } }.to raise_error(ArgumentError, /choices: is a chooses' scale/)
      expect { fields { scores :severity, "q", { a: 1 }, { b: 2 } } }
        .to raise_error(ArgumentError, %r{levels are positional labels, or one \{ label => integer / description \} Hash})
    end

    it "checks a lens's shape before reading a String under given: as a label" do
      expect { fields { judges :escalate, "q", given: "policy" } }.to raise_error(ArgumentError, /given: is a Proc, a method name or a Hash \(got "policy"\)/)
      expect { fields { chooses :department, "q", a: "A", b: "B", given: "policy" } }.to raise_error(ArgumentError, /given: is a Proc, a method name or a Hash/)
      expect { fields { judges :escalate, "q", after: "department" } }.to raise_error(ArgumentError, /after: names measured fields — a Symbol/)
    end

    it "applies the once-rule to criteria: beside true: / false:" do
      expect { fields { judges :escalate, "q", true: "B", criteria: { true: "A" } } }
        .to raise_error(ArgumentError, %r{:escalate: criteria: and true:/false: are one thing; give it once})
      expect { fields { judges :escalate, "q", criteria: "x" } }.to raise_error(ArgumentError, /judges :escalate criteria: is \{ true:, false: \} \(got "x"\)/)
      expect { fields { judges :escalate, "q", criteria: %w[x y] } }.to raise_error(ArgumentError, /criteria: is \{ true:, false: \}/)
      expect { fields { chooses :department, "q", categories: "a,b" } }
        .to raise_error(ArgumentError, %r{categories: is a Hash, an Array, or a Proc / method name \(got "a,b"\)})
      expect { fields { chooses :department, "q", categories: 3 } }.to raise_error(ArgumentError, /categories: is a Hash, an Array/)
    end

    it "requires at least 2 distinct labels on a static scale" do
      expect { fields { scores :severity, "q", :only } }.to raise_error(ArgumentError, /a scale is at least 2 distinct labels \(got \["only"\]\)/)
      expect { fields { chooses :department, "q", :only } }.to raise_error(ArgumentError, /at least 2 distinct labels \(got \[:only\]\)/)
      expect { fields { chooses :department, "q", :a, :a } }.to raise_error(ArgumentError, /at least 2 distinct labels/)
      expect { fields { scores :severity, "q", :a, :a, :b } }.to raise_error(ArgumentError, /at least 2 distinct labels \(got \["a", "a", "b"\]\)/)
      expect { fields { scores :severity, "q", levels: %w[a a] } }.to raise_error(ArgumentError, /at least 2 distinct labels/)
    end

    it "requires a question at declaration, and a question-less choice_enum is not a measured field" do
      expect { fields { judges :escalate, nil } }
        .to raise_error(ArgumentError, /judges :escalate needs a question — a String, or a structured Hash \(got nil\)/)
      expect { fields { chooses :department, "  ", :a, :b } }.to raise_error(ArgumentError, /chooses :department needs a question/)
      klass = fresh("deliveries") { choice_enum :status, nil, delivered: "a", attempted: "b" }
      expect(klass.s1_fields).to be_empty
      expect { klass.s1_verify_fields! }.not_to raise_error
      expect { klass.new.choose(:status) }.to raise_error(ArgumentError, /has no declared question for :status/)
      expect(klass.new.s1_request { |q| q.choose :status, "Which?" }.questions[:status].categories).to eq(%w[delivered attempted])
    end

    it "takes choice_enum categories: as an Array, and score_enum's model: beside its integer labels" do
      klass = fresh("deliveries") { choice_enum :status, "q", categories: %i[delivered attempted] }
      expect(klass.s1_fields[:status][:categories]).to eq(delivered: nil, attempted: nil)
      expect(klass.new.s1_request(:status).questions[:status].categories).to eq(%w[delivered attempted])
      graded = fresh("tickets") { score_enum :grade, "q", poor: 0, fair: 1, model: "x", provider: "stub" }
      expect(graded.s1_fields[:grade]).to include(model: "x", provider: "stub", levels: %w[poor fair], indexes: [0, 1])
    end

    it "resolves a named provider at verify!, and refuses one sibling column claimed by two fields" do
      expect { Class.new(Ticket) { judges :escalate, "q", provider: :nope }.s1_verify_fields! }
        .to raise_error(ArgumentError, /:escalate provider: unknown S1 provider: :nope/)
      expect { Class.new(Ticket) { judges :escalate, "q", provider: :stub }.s1_verify_fields! }.not_to raise_error
      expect do
        fresh("sharers") do
          judges :a, "q", siblings: { probability: :shared }
          judges :b, "q", siblings: { probability: :shared }
        end.s1_verify_fields!
      end.to raise_error(ArgumentError, /sibling :shared is claimed by both :a and :b/)
    end

    it "refuses s1_plan settings it does not take" do
      expect { Ticket.s1_plan(:department, given: { desk: "x" }) }.to raise_error(ArgumentError, "Ticket.s1_plan takes as:, provider:, model: (got [:given])")
      expect { Ticket.s1_plan(:department, provder: :x) }.to raise_error(ArgumentError, /\(got \[:provder\]\)/)
    end
  end

  describe "the audit is the question as asked, over the scale the column stores" do
    before { answers(escalate: 0.6, department: :billing, severity: 1, priority: 1, team: :b, flag: 0.6) }

    it "digests a score's stored labels, so renaming a level makes the row stale" do
      ticket.update_measure(:severity)
      expect(ticket).not_to be_stale(:severity)
      renamed = stub_const("Renamed", Class.new(Ticket) do
        scores :severity, "How severe is the issue?", minor: "no impact", degraded: "a workaround exists", blocking: "no workaround"
      end)
      expect(renamed.s1_question_digest(:severity)).not_to eq(Ticket.s1_question_digest(:severity))
      expect(renamed.find(ticket.id)).to be_stale(:severity)
    end

    it "needs the record to digest a dynamic scale, and says so" do
      expect { Ticket.s1_question_digest(:subtype) }
        .to raise_error(ArgumentError, "Ticket: :subtype has a dynamic scale; s1_question_digest(:subtype, record) needs the record")
      expect(Ticket.s1_question_digest(:subtype, ticket)).to match(/\A\h{64}\z/)
    end

    it "collapses a plain S1::State's Result at the declared threshold and leaves the row stale, the question unknown" do
      foreign = S1::State.new("txt").measure { |q| q.judge :escalate, "Anything?" }
      expect(foreign[:escalate].collapse).to be(true)
      ticket.as.assign(foreign)
      ticket.save!
      expect(ticket.reload.escalate).to be(false)
      expect(ticket.s1_answers["escalate"]).to include("threshold" => 0.7)
      expect(ticket.s1_answers["escalate"]).not_to have_key("question_digest")
      expect(ticket).to be_stale(:escalate)
      expect(Ticket.stale(:escalate).pluck(:id)).to eq([ticket.id])
      other = Ticket.find(ticket.id).measure(:escalate)
      ticket.as.assign(other)
      ticket.save!
      expect(ticket.reload).not_to be_stale(:escalate)
    end

    it "keys a score's _probabilities sibling by label, and rehydrates a stored score by its scale's positions" do
      klass = fresh("gradings") do
        scores  :priority, "How urgent?", { "can wait" => 10, "today" => 20, "now" => 30 }
        chooses :team, "Which?", a: "A", b: "B"
        judges  :flag, "Flag?"
      end
      row = klass.create!(body: "x")
      row.update_measure(:priority, :team, :flag)
      expect(row.reload.priority_probabilities).to eq("can wait" => 0.0, "today" => 1.0, "now" => 0.0)
      expect(row.team_probabilities).to eq("a" => 0.0, "b" => 1.0)
      expect(row.flag_probabilities).to eq("true" => 0.6, "false" => 0.4)
      row.update_column(:s1_answers, { "priority" => { "kind" => "score", "value" => "now", "position" => 2,
                                                       "probabilities" => { "0" => 0.2, "2" => 0.8 }, "scale" => ["can wait", "today", "now"] } })
      expect(row.reload.measurement(:priority).level).to eq("now")
      expect(row.measurement(:priority).levels.map(&:to_s)).to eq(["can wait", "today", "now"])
    end

    it "keeps both entries when two instances of one row measure different fields" do
      a = Ticket.find(ticket.id)
      b = Ticket.find(ticket.id)
      a.update_measure(:escalate)
      b.update_measure(:department)
      expect(ticket.reload.s1_answers.keys).to contain_exactly("escalate", "department")
      expect(ticket).to have_attributes(escalate: false, department: "billing")
    end

    it "reads a float score column's category from the audit, never through the indexes or the nearest level" do
      klass = stub_const("Expected", Class.new(PhoneCall) do
        scores :quality_position, "q", { a: 1, b: 2, c: 3 }
        judges :is_lead, "Lead, given `quality_position`?", after: :quality_position
      end)
      stub_s1 do |_req|
        { quality_position: { legend: { 0 => "a", 1 => "b", 2 => "c" }, probabilities: { "0" => 0.45, "1" => 0.1, "2" => 0.45 }, confidence: 1.0 } }
      end
      row = klass.create!(firm: Firm.create!(name: "f"), transcript: "x")
      row.update_measure(:quality_position)
      expect(row.reload.quality_position).to eq(1.0)
      expect(row.s1_request(:is_lead).state).to include(quality_position: "a")
      row.update_column(:s1_answers, nil)
      expect { row.reload.s1_request(:is_lead) }.to raise_error(ArgumentError, /holds 1\.0, not measured; a float or decimal column keeps the expectation/)
      row.update!(quality_position: 2.0)
      expect { row.s1_request(:is_lead) }.to raise_error(ArgumentError, /holds 2\.0, not measured/)
    end
  end

  describe "the call names its spelling" do
    before { answers(escalate: 0.9, department: :billing) }

    it "takes a single String column name as the column, and a String question as a question" do
      expect(ticket.measure("escalate").distributions.keys).to eq([:escalate])
      ticket.update_measure("escalate")
      expect(ticket.s1_result[:escalate].collapse).to be(true)
      expect(ticket.reload.escalate).to be(true)
      expect { ticket.measure("Is it?") }.to raise_error(ArgumentError, /a String is a question for judge/)
    end

    it "raises from stale? on an undeclared column as Model.stale does" do
      expect { ticket.stale?(:body) }.to raise_error(ArgumentError, "Ticket: :body is not a measured field")
      expect { ticket.stale?(:s1_answers) }.to raise_error(ArgumentError, "Ticket: :s1_answers is not a measured field")
    end

    it "checks a String threshold on every ? verb before the comparison" do
      expect { ticket.judge?(:escalate, threshold: "0.7") }.to raise_error(ArgumentError, /judge\?\(threshold:\): threshold: is a number in 0..1 \(got "0.7"\)/)
      expect { ticket.is?(:escalate, threshold: "0.7") }.to raise_error(ArgumentError, /judge\?\(threshold:\)/)
      expect { ticket.same_as?("x", threshold: "0.7") }.to raise_error(ArgumentError, /same_as\?\(threshold:\)/)
      expect { ticket.judge(:escalate, threshold: 0.9) }.to raise_error(ArgumentError, S1::State::THRESHOLD_ON_VERB)
    end

    it "names s1_facts for the rendering alone, s1_state as its old name, and as for the state" do
      row = Ticket.new(body: "x")
      expect(row.s1_facts).to eq(body: "x")
      expect(row.s1_state).to eq(body: "x")
      expect(row.s1_facts(:planned)).to eq(body: "x", plan: nil)
      expect(row.as).to be_a(S1::Measurable::State)
      expect(row.as.facts).to eq(body: "x")
      expect(row.as.lens).to eq(policy: "30 days")
    end

    it "writes update_measure_all slice by slice: the slices before a failing call stay written" do
      rows = 3.times.map { |i| Ticket.create!(body: "b#{i}") }
      calls = 0
      stub_s1 { |_req| (calls += 1) == 3 ? raise(S1::TransientError, "down") : { escalate: 0.9 } }
      expect { Ticket.where(id: rows.map(&:id)).update_measure_all(:escalate, concurrency: 1) }.to raise_error(S1::TransientError)
      expect(rows.map { |r| r.reload.escalate }).to eq([true, true, nil])
    end
  end

  describe "a trigger fires for the caller's changes, never twice for a measurement's own" do
    before { answers(kind: :new_case, case_type: :slip, urgent: 0.9, escalate: 0.9, severity: 1, department: :billing) }

    it "re-measures a :validation field when the measuring save carries the caller's own changes" do
      klass = stub_const("Revalidated", Class.new(Ticket) { judges :escalate, "q", measure_on: :validation })
      row = klass.create!(body: "x")
      expect(requests.map { |r| r.questions.keys }).to eq([[:escalate]])
      row.update_measure(:severity)
      expect(requests.map { |r| r.questions.keys }).to eq([[:escalate], [:severity]])
      row.body = "changed"
      row.update_measure(:severity)
      expect(requests.map { |r| r.questions.keys }).to eq([[:escalate], [:severity], [:severity], [:escalate]])
      expect(requests.last.state[:this]).to include(body: "changed")
    end

    it "enqueues on the committed row when the record was dirtied after its save, and logs what stayed behind" do
      log = StringIO.new
      S1.config.logger = Logger.new(log)
      row = Routing.create!(transcript: "x")
      clear_enqueued_jobs
      expect { Routing.transaction { row.update!(transcript: "y") and row.transcript = "z" } }.not_to raise_error
      expect(enqueued_jobs.map { |j| j["arguments"][5] }).to contain_exactly(%w[kind case_type], %w[urgent])
      expect(log.string).to include('unsaved changes to ["transcript"] do not reach the job measuring [:kind, :case_type]')
      expect { row.update_measure_later(:kind) }.to raise_error(ArgumentError, /unsaved changes to \["transcript"\] would not reach the job/)
    end
  end
end
