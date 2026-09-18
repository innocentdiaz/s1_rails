# frozen_string_literal: true

# The conventions that keep a silent misread from reaching the wire or the row: every stage
# collapses as its column will; a sequenced lens is a category, never nil; a trigger fires for
# what the caller changed and not for a measurement's own write; a label named like an option
# raises naming the spelling; a score's distribution speaks the column's scale.
RSpec.describe "conventions" do
  let(:requests) { [] }
  let(:ticket) { Ticket.create!(body: "I have asked three times. Can I talk to a real person?", plan: "gold") }

  def answers(**canned) = stub_s1 { |req| requests << req and canned }

  describe "every stage collapses as the column will" do
    it "restamps a judge's declared threshold before the provisional assign, so the lens, the dynamic scale and the column agree" do
      klass = stub_const("Staged", Class.new(Ticket) do
        chooses :subtype, "Which?", categories: -> { escalate ? { a: "A", b: "B" } : { c: "C", d: "D" } }, after: :escalate
      end)
      answers(escalate: 0.6, subtype: :c)
      row = klass.find(ticket.id)
      row.update_measure(:escalate, :subtype)
      result = row.s1_result
      expect(requests.last.state).to include(escalate: false)
      expect(requests.last.questions[:subtype].categories).to eq(%w[c d])
      expect(result[:escalate].collapse).to be(false)
      expect(row.reload).to have_attributes(escalate: false, subtype: "c")
    end

    it "carries a call-site threshold into the sequenced lens of a float noul column" do
      klass = stub_const("Floated", Class.new(PhoneCall) do
        judges  :lead_probability, "Lead?", threshold: 0.5
        chooses :case_type, "Type, given `lead_probability`?", categories: { mva: "car", slip: "fall" }, after: :lead_probability, siblings: false
      end)
      answers(lead_probability: 0.8, case_type: :slip)
      row = klass.create!(firm: Firm.create!(name: "f"), transcript: "x")
      result = row.as(threshold: 0.9).measure(%i[lead_probability case_type])
      expect(result[:lead_probability].collapse).to be(false)
      expect(requests.last.state).to include(lead_probability: false)
      row.update!(lead_probability: 0.8)
      expect(row.as(threshold: 0.9).request(:case_type).state).to include(lead_probability: false)
      expect(row.s1_request(:case_type).state).to include(lead_probability: true)
    end
  end

  describe "the sequenced lens is a category, as the column holds it" do
    let(:firm) { Firm.create!(name: "f") }

    it "raises, naming the spelling, when the predecessor was neither measured in the call nor written" do
      answers(kind: :new_case, case_type: :slip)
      row = Routing.create!(transcript: "x")
      clear_enqueued_jobs
      expect { row.choose(:case_type) }.to raise_error(ArgumentError, /:kind has not been measured.*measure\(:kind, :case_type\)/)
      expect { row.s1_request(:case_type) }.to raise_error(ArgumentError, /measure\(:kind, :case_type\)/)
      expect(requests).to be_empty
      row.update!(kind: "existing")
      expect(row.s1_request(:case_type).state).to include(kind: "existing") # the dry run shows a gated field's Request too
    end

    it "relabels a positional integer score through its position" do
      klass = stub_const("Positional", Class.new(PhoneCall) do
        scores :quality, "Quality?", :low, :mid, :high, siblings: false
        judges :is_lead, "Lead, given `quality`?", after: :quality
      end)
      answers(quality: 1, is_lead: 0.9)
      row = klass.create!(firm: firm, transcript: "x")
      row.measure(:quality, :is_lead)
      expect(requests.last.state).to include(quality: "mid")
      row.update!(quality: 2)
      expect(row.s1_request(:is_lead).state).to include(quality: "high")
      expect { klass.s1_collapsed(:quality, klass.new(quality: 7)) }.to raise_error(ArgumentError, /holds 7, not a position on \["low", "mid", "high"\]/)
    end

    it "reads a float score column's category from the audit — never the level nearest its expectation — and a decimal noul at the threshold" do
      klass = stub_const("Numbered", Class.new(PhoneCall) do
        scores :quality_position, "Quality?", :low, :mid, :high
        judges :lead_mass, "Lead?"
        chooses :case_type, "Type?", categories: { mva: "car", slip: "fall" }, after: %i[quality_position lead_mass], siblings: false
      end)
      stub_s1 do |_req|
        { quality_position: { legend: { 0 => "low", 1 => "mid", 2 => "high" }, probabilities: { "0" => 0.45, "1" => 0.1, "2" => 0.45 },
                              confidence: 1.0 },
          lead_mass: 0.9, case_type: :mva }
      end
      row = klass.create!(firm: firm, transcript: "x")
      row.update_measure(:quality_position, :lead_mass)
      expect(row.reload.quality_position).to eq(1.0)
      expect(row.s1_request(:case_type).state).to include(quality_position: "low", lead_mass: true)
      row.update_column(:s1_answers, nil)
      expect { row.reload.s1_request(:case_type) }
        .to raise_error(ArgumentError, /:quality_position holds 1\.0, not measured; a float or decimal column keeps the expectation, not the category/)
    end

    it "raises on an integer score column holding none of its indexes" do
      klass = stub_const("Renumbered", Class.new(Ticket) { judges :escalate, "q", after: :priority })
      row = klass.create!(body: "x", priority: 15)
      expect { row.s1_request(:escalate) }.to raise_error(ArgumentError, /:priority holds 15, not one of its indexes \[10, 20, 30\]/)
    end

    it "leaves out a field whose predecessor was gated out of the call" do
      klass = stub_const("Chained", Class.new(Routing) { judges :urgent, "Urgent, given `case_type`?", after: :case_type })
      answers(kind: :existing, case_type: :slip, urgent: 0.9)
      row = klass.create!(transcript: "checking in")
      clear_enqueued_jobs
      result = row.measure(:kind, :case_type, :urgent)
      expect(result.distributions.keys).to eq([:kind])
      expect(requests.map { |r| r.questions.keys }).to eq([[:kind]])
    end
  end

  describe "a sequenced field shares its predecessor's trigger" do
    it "joins the predecessor's trigger even when the predecessor has if: / unless: — one job, in order" do
      klass = stub_const("Gated", Class.new(Routing) do
        chooses :kind, "Kind?", **Routing::KINDS, measure_on: :transcript, if: :long?
        chooses :case_type, "Type, given `kind`?", categories: :case_types, after: :kind, measure_on: :transcript
        def long? = transcript.to_s.size > 5
      end)
      answers(kind: :new_case, case_type: :slip, urgent: 0.1)
      expect(klass.s1_triggers.values).to contain_exactly(%i[kind case_type], [:urgent])
      klass.create!(transcript: "hello there")
      expect(enqueued_jobs.map { |j| j["arguments"][5] }).to contain_exactly(%w[kind case_type], %w[urgent])
      perform_enqueued_jobs
      expect(requests.find { |r| r.questions.key?(:case_type) }.state).to include(kind: "new_case")
      clear_enqueued_jobs
      klass.create!(transcript: "ab")
      expect(enqueued_jobs.map { |j| j["arguments"][5] }).to eq([%w[urgent]]) # kind gated out, and case_type with it
    end

    it "raises at declaration when the predecessor has no trigger, spells it differently, or the field names on:" do
      expect { Class.new(Ticket) { chooses :subtype, "q", categories: :subtypes, after: :department, measure_on: :body } }
        .to raise_error(ArgumentError, /after: :department has no measure_on: trigger to share; declare :department with measure_on: :body first/)
      expect do
        Class.new(Routing) { chooses :case_type, "q", categories: :case_types, after: :kind, measure_on: :save }
      end.to raise_error(ArgumentError, /measure_on: :save differs from :kind's measure_on: :transcript/)
      expect do
        Class.new(Routing) { chooses :case_type, "q", categories: :case_types, after: :kind, measure_on: :transcript, on: :create }
      end.to raise_error(ArgumentError, /shares its predecessors' trigger \[:kind\]; on: goes on theirs/)
    end

    it "verify! refuses a triggered sequenced field whose predecessor left its trigger" do
      klass = Class.new(Routing) { chooses :kind, "Kind?", **Routing::KINDS, measure_on: :save }
      expect(klass.s1_triggers.values).to contain_exactly([:case_type], [:kind], [:urgent])
      expect { klass.s1_verify_fields! }.to raise_error(ArgumentError, /:case_type is triggered without its predecessors \[:kind\]/)
    end
  end

  describe "triggers belong to the class that declared them" do
    before { answers(kind: :new_case, case_type: :slip, urgent: 0.9, escalate: 0.9, severity: 1) }

    it "gives a subclass its own trigger lists: a parent never measures a subclass's field" do
      sub = stub_const("Sub", Class.new(Routing) { judges :urgent, "q", measure_on: :transcript })
      expect(Routing.s1_triggers.values).to contain_exactly(%i[kind case_type], [:urgent])
      expect(sub.s1_triggers.values).to eq([%i[kind case_type urgent]])
      Routing.create!(transcript: "x")
      expect(enqueued_jobs.map { |j| j["arguments"][5] }).to contain_exactly(%w[kind case_type], %w[urgent])
      clear_enqueued_jobs
      sub.create!(transcript: "x")
      expect(enqueued_jobs.map { |j| j["arguments"][5] }).to eq([%w[kind case_type urgent]])
      perform_enqueued_jobs
      expect(requests.map { |r| r.questions.keys }).to eq([%i[kind urgent], [:case_type]])
    end

    it "moves a redeclared field to its new trigger instead of keeping both" do
      klass = stub_const("Moved", Class.new(Ticket) do
        judges :escalate, "q", measure_on: :body
        judges :escalate, "q", measure_on: :plan
      end)
      expect(klass.s1_triggers.values).to eq([[:escalate]])
      row = klass.create!(body: "x")
      expect(enqueued_jobs).to be_empty
      row.update!(plan: "gold")
      expect(enqueued_jobs.map { |j| j["arguments"][5] }).to eq([%w[escalate]])
    end
  end

  describe "a measurement's own write, and nothing else, is what a trigger skips" do
    before { answers(kind: :new_case, case_type: :slip, urgent: 0.9, escalate: 0.9, severity: 1) }

    it "fires for the caller's other changes in the same transaction, whichever came first" do
      row = Routing.create!(transcript: "x")
      perform_enqueued_jobs
      Routing.transaction do
        row.update_measure(:kind)
        row.update!(transcript: "changed")
      end
      expect(enqueued_jobs.map { |j| j["arguments"][5] }).to contain_exactly(%w[kind case_type], %w[urgent])
      clear_enqueued_jobs
      Routing.transaction do
        row.update!(transcript: "changed again")
        row.update_measure(:urgent)
      end
      expect(enqueued_jobs.map { |j| j["arguments"][5] }).to contain_exactly(%w[kind case_type])
      clear_enqueued_jobs
      row.update_measure(:kind)
      expect(enqueued_jobs).to be_empty
    end

    it "never re-enqueues a field the measuring save wrote from the state it saved" do
      row = Routing.create!(transcript: "x")
      perform_enqueued_jobs
      clear_enqueued_jobs
      row.transcript = "again"
      row.update_measure(:urgent)
      expect(enqueued_jobs.map { |j| j["arguments"][5] }).to eq([%w[kind case_type]])
      born = stub_const("BornLead", Class.new(Routing) { judges :urgent, "q", measure_on: :create })
      clear_enqueued_jobs
      born.new(transcript: "x").update_measure(:urgent)
      expect(enqueued_jobs.map { |j| j["arguments"][5] }).to eq([%w[kind case_type]])
      expect(requests.map { |r| r.questions.keys }.last).to eq([:urgent])
    end

    it "fires a :create trigger when update_measure performs the creating save" do
      klass = stub_const("Born", Class.new(Ticket) { judges :escalate, "q", measure_on: :create })
      row = klass.new(body: "x")
      row.update_measure(:severity)
      expect(row).to be_persisted
      expect(enqueued_jobs.map { |j| j["arguments"][5] }).to eq([%w[escalate]])
    end

    it "does not re-measure a :validation field inside its own write, nor inside another field's job" do
      klass = stub_const("Validated", Class.new(Ticket) do
        judges  :escalate, "q", measure_on: :validation
        chooses :department, "q", **Ticket::DEPARTMENTS, measure_on: :body
      end)
      row = klass.create!(body: "x")
      expect(requests.map { |r| r.questions.keys }).to eq([[:escalate]])
      row.update_measure(:escalate)
      expect(requests.map { |r| r.questions.keys }).to eq([[:escalate], [:escalate]])
      perform_enqueued_jobs
      expect(requests.map { |r| r.questions.keys }).to eq([[:escalate], [:escalate], [:department]])
    end
  end

  describe "on: with a trigger" do
    it "is honoured on :save, attribute and Proc triggers" do
      klass = stub_const("Created", Class.new(Ticket) { judges :escalate, "q", measure_on: :body, on: :create })
      row = klass.create!(body: "x")
      expect(enqueued_jobs.size).to eq(1)
      clear_enqueued_jobs
      row.update!(body: "y")
      expect(enqueued_jobs).to be_empty
      updated = stub_const("Updated", Class.new(Ticket) { judges :escalate, "q", measure_on: :save, on: :update })
      row = updated.create!(body: "x")
      expect(enqueued_jobs).to be_empty
      row.update!(body: "y")
      expect(enqueued_jobs.size).to eq(1)
    end

    it "is refused where the lifecycle name already says when, and without any trigger" do
      expect { Class.new(Ticket) { judges :escalate, "q", measure_on: :create, on: :update } }
        .to raise_error(ArgumentError, /measure_on: :create already says when; drop on:/)
      expect { Class.new(Ticket) { judges :escalate, "q", if: :never? } }.to raise_error(ArgumentError, /if: needs measure_on:/)
      expect { Class.new(Ticket) { chooses :subtype, "q", categories: :subtypes, after: :department, on: :create } }
        .to raise_error(ArgumentError, /on: needs measure_on:/)
      expect { Class.new(Ticket) { chooses :subtype, "q", categories: :subtypes, after: :department, if: :gold? } }.not_to raise_error
    end
  end

  describe "the scale is given once, under any of its names, and never as a label named like an option" do
    def fields(&) = Class.new(Ticket, &).s1_fields

    it "takes criteria: and choices: on chooses, criteria: on scores, as the one code path" do
      expect(fields { chooses :department, "q", criteria: { a: "x", b: "y" } }[:department][:categories]).to eq(a: "x", b: "y")
      expect(fields { chooses :department, "q", choices: %i[a b] }[:department][:categories]).to eq(a: nil, b: nil)
      expect(fields { scores :severity, "q", criteria: %w[a b] }[:severity][:levels]).to eq(%w[a b])
      expect do
        fields do
          chooses :department, "q", categories: %i[a b], choices: %i[a b]
        end
      end.to raise_error(ArgumentError, /categories: and choices: are one thing/)
      expect(fields { measured_field :department, "q", criteria: { a: "x", b: "y" } }[:department][:kind]).to eq(:choice)
      expect(fields { measured_field :severity, "q", criteria: %w[a b] }[:severity][:kind]).to eq(:score)
      expect(fields { measured_field :escalate, "q", criteria: { true: "x" } }[:escalate][:kind]).to eq(:noul)
      expect(Class.new(Delivery) { choice_enum :status, "q", categories: { delivered: "d", attempted: "a" }, default: "attempted" }.new).to be_attempted
    end

    it "raises at declaration on a label that collides with an option, naming categories: / levels:" do
      expect { fields { chooses :department, "Is it on?", on: "switched on", off: "switched off" } }
        .to raise_error(ArgumentError, /on: "switched on" reads as a label named :on.*categories: \{ on: … \}/)
      expect { fields { chooses :department, "q", model: "a model issue", returns: "r" } }
        .to raise_error(ArgumentError, /model: "a model issue" beside keyword labels is ambiguous.*categories:/)
      expect { fields { scores :severity, "q", a: "x", unless: "unless they call back" } }.to raise_error(ArgumentError, /levels: \{ unless: … \}/)
      expect { fields { judges :escalate, "q", if: "they shout" } }.to raise_error(ArgumentError, /if: "they shout" reads as a label/)
      expect { Class.new(Delivery) { choice_enum :status, "q", model: "a model of something", other: "else" } }.to raise_error(ArgumentError, /ambiguous/)
      expect(fields { scores :severity, "q", :a, :b, model: "cheap" }[:severity]).to include(model: "cheap") # positional labels: not ambiguous
      expect(fields { chooses :department, "q", categories: { on: "switched on", off: "off" }, model: "m" }[:department]).to include(model: "m")
    end

    it "checks threshold: and a judge's criteria: at declaration, and threshold: at the call" do
      expect { fields { judges :escalate, "q", threshold: 90 } }.to raise_error(ArgumentError, /:escalate: threshold: is a number in 0..1 \(got 90\)/)
      expect { fields { judges :escalate, "q", threshold: "0.9" } }.to raise_error(ArgumentError, /threshold: is a number in 0..1/)
      expect { fields { judges :escalate, "q", threshold: 0 } }.not_to raise_error
      expect { ticket.as(threshold: "0.9") }.to raise_error(ArgumentError, /as\(threshold:\): threshold: is a number in 0..1/)
      expect { fields { judges :escalate, "q", criteria: { yes: "a", no: "b" } } }
        .to raise_error(ArgumentError,
                        %r{judges :escalate criteria: noul criteria may only clarify true/false \(got \["yes", "no"\]\); it takes true: / false:})
    end

    it "checks an explicit sibling part at declaration" do
      expect { fields { judges :escalate, "q", siblings: { confidence: :escalate_probability } } }
        .to raise_error(ArgumentError, /:escalate has no confidence: it is a noul/)
    end

    it "verify! sees a json-backed method behind given: / categories: before any record was built" do
      klass = Class.new(ActiveRecord::Base) do
        self.table_name = "pickers"
        include S1::Measurable

        chooses :pick, "q", categories: :labels, given: :policy
      end
      expect { klass.s1_verify_fields! }.not_to raise_error
    end
  end

  describe "a lens is a Hash of evidence" do
    it "raises when given: names a method that returns anything else, and symbolizes its keys" do
      klass = stub_const("Lensless", Class.new(Ticket) do
        judges :escalate, "q", given: :policy_lens
        attr_accessor :policy_lens
      end)
      row = klass.find(ticket.id)
      answers(escalate: 0.9)
      row.policy_lens = nil
      expect { row.judge(:escalate) }.to raise_error(ArgumentError, /:escalate given: :policy_lens returned nil; a lens is a Hash/)
      row.policy_lens = "30 days"
      expect { row.judge(:escalate) }.to raise_error(ArgumentError, /returned "30 days"; a lens is a Hash/)
      row.policy_lens = { "policy" => "30 days" }
      expect(row.s1_request(:escalate).state).to include(policy: "30 days")
      expect(row.s1_request(:escalate).state.keys).not_to include("policy")
    end

    it "evaluates a Proc at the top of a lens on the record, and refuses one nested inside" do
      answers(escalate: 0.9)
      expect(ticket.s1_request(:escalate, given: { policy: -> { plan } }).state).to include(policy: "gold")
      expect(ticket.given(policy: -> { plan }).request(:escalate).state).to include(policy: "gold")
      klass = stub_const("Lazy", Class.new(Ticket) { judges :escalate, "q", given: { policy: -> { plan } } })
      expect(klass.find(ticket.id).s1_request(:escalate).state).to include(policy: "gold")
      expect { ticket.s1_request(:escalate, given: { policy: { days: -> { 30 } } }) }.to raise_error(ArgumentError, /is not evidence/)
    end
  end

  describe "a score's distribution speaks the column's scale" do
    it "keeps a block's rewording of a declared score under the declared labels, and records that scale" do
      answers(severity: 2)
      ticket.update_measure { |q| q.score :severity, "Reworded?" }
      expect(requests.last.questions[:severity].levels).to eq(["no impact", "a workaround exists", "no workaround"])
      expect(ticket.reload).to have_attributes(severity: "blocking", severity_index: 2)
      expect(ticket.s1_answers["severity"]).to include("value" => "blocking", "position" => 2, "scale" => %w[cosmetic degraded blocking])
      expect(ticket.measurement(:severity).level).to eq("blocking")
      expect(ticket).to be_stale(:severity)
    end

    it "keeps the scale a dynamic score was asked over after an earlier stage's provisional collapse" do
      klass = stub_const("Dynamic", Class.new(Ticket) do
        scores :severity, "How severe?", levels: -> { department == "billing" ? { minor: "m", major: "M", critical: "C" } : { low: "l", high: "h" } },
                                         after: :department, siblings: false
      end)
      answers(department: :billing, severity: 2)
      row = klass.find(ticket.id)
      row.update_measure(:department, :severity)
      expect(row.s1_result[:severity].level).to eq("critical")
      expect(row.reload.severity).to eq("critical")
      expect(row.s1_answers["severity"]).to include("value" => "critical", "scale" => %w[minor major critical])
    end

    it "keeps position in the audit and the declared index in the _index sibling — two names for two numbers" do
      klass = stub_const("Indexed", Class.new(Ticket) { scores :severity, "q", { cosmetic: 0, degraded: 5, blocking: 9 } })
      answers(severity: 1)
      row = klass.find(ticket.id)
      row.update_measure(:severity)
      expect(row.reload).to have_attributes(severity: "degraded", severity_index: 5)
      expect(row.s1_answers["severity"]).to include("position" => 1)
      expect(row.s1_answers["severity"]).not_to have_key("index")
    end
  end

  describe "the audit knows the question whoever writes it" do
    before { answers(escalate: 0.9, department: :billing) }

    it "writes from the State that asked when given: is passed to update_measure / assign_measure" do
      ticket.as.update_measure(:escalate, given: { extra: 1 })
      expect(ticket.s1_answers["escalate"]).to include("question_digest" => Ticket.s1_question_digest(:escalate))
      expect(ticket.stale?(:escalate)).to be(false)
      ticket.as.assign_measure(:department, given: { extra: 1 })
      expect(ticket.s1_answers["department"]).to include("form" => "planned")
      expect(requests.last.state).to include(extra: 1)
    end

    it "gives a declared field assigned from another State's Result the declaration's digest" do
      result = ticket.measure(:escalate)
      ticket.as.assign(result)
      ticket.save!
      expect(ticket.reload.s1_answers["escalate"]).to include("question_digest" => Ticket.s1_question_digest(:escalate))
      expect(ticket.stale?(:escalate)).to be(false)
    end
  end

  describe "a declared column name stands for its question in every verb" do
    before { answers(escalate: 0.9) }

    it "routes is / is? / where_is to the declared judge" do
      expect(ticket.is?(:escalate)).to be(true)
      expect(ticket.is(:escalate)).to be_a(S1::Answer::Noul)
      expect(Ticket.where(id: ticket.id).where_is(:escalate).pluck(:id)).to eq([ticket.id])
      expect(Ticket.where(id: ticket.id).where_is_not(:escalate)).to be_empty
      expect(requests.map { |r| r.questions[:escalate].instructions }.uniq).to eq(["Is the customer asking for a human agent?"])
      expect { ticket.is?(:department) }.to raise_error(ArgumentError, "department is a choice; use choose")
    end

    it "takes as: on every verb, as the form" do
      expect(ticket.judge?(:escalate, as: :planned)).to be(true)
      expect(requests.last.state[:this]).to include(plan: "gold")
      expect(requests.last.options[:form]).to eq(:planned)
      expect(ticket.is?("angry", as: :planned)).to be(true)
      expect(requests.last.state[:this]).to include(plan: "gold")
    end

    it "refuses a String where column names go, naming the verbs" do
      expect { ticket.s1_request("Is it?") }.to raise_error(ArgumentError, %r{a String is a question for judge / choose / score.*q\.judge :id, "Is it\?"})
      expect { ticket.measure("Is it?") }.to raise_error(ArgumentError, /a String is a question for judge/)
    end
  end

  describe "two spellings of one act never disagree silently" do
    it "refuses update_measure_later on a record with unsaved changes" do
      ticket.body = "new body"
      expect do
        ticket.update_measure_later(:department)
      end.to raise_error(ArgumentError,
                         /unsaved changes to \["body"\] would not reach the job; save first, or update_measure/)
      expect(enqueued_jobs).to be_empty
    end

    it "raises from stale? without an s1_answers column, as Model.stale does" do
      delivery = Delivery.create!(status: :attempted)
      expect { delivery.stale?(:status) }.to raise_error(ArgumentError, "Delivery: stale? needs an s1_answers column")
      expect { Delivery.stale(:status) }.to raise_error(ArgumentError, /needs an s1_answers column/)
    end

    it "verifies named subclasses at boot" do
      stub_const("SubTicket", Class.new(Ticket) { judges :nope_column, "q" })
      expect { S1::Measurable.verify! }.to raise_error(ArgumentError, /SubTicket: measured field :nope_column is not a column/)
    end

    it "says so when stale runs in Ruby" do
      log = StringIO.new
      S1.config.logger = Logger.new(log)
      Ticket.stale(:subtype).to_a
      expect(log.string).to include("Ticket.stale(:subtype) runs in Ruby")
    end
  end

  describe "the cache" do
    before do
      S1.config.cache = ActiveSupport::Cache::MemoryStore.new
      answers(department: :billing, subtype: :missing, escalate: 0.9)
    end

    it "serves a later stage from the cache: provisional assignment does not make the record dirty to it" do
      2.times { ticket.measure(:department, :subtype) }
      expect(requests.size).to eq(2)
    end

    it "keys on the form's rendering, so a form that renders differently is a different measurement" do
      klass = stub_const("Reformed", Class.new(Ticket))
      row = klass.find(ticket.id)
      row.judge(:escalate)
      klass.measurable_as { { body: body, plan: plan } }
      klass.find(ticket.id).judge(:escalate)
      expect(requests.size).to eq(2)
    end
  end

  it "loads without ActiveRecord having been required first" do
    expect(system("bundle", "exec", "ruby", "-e", 'require "s1-rails"; S1::Measurable::Declarations', out: File::NULL, err: File::NULL)).to be(true)
  end
end
