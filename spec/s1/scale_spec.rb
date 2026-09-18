# frozen_string_literal: true

# The scale as a value in the macros: an S1::Scale declares a scores / chooses field as a list or
# a hash does, the registry keeps it under scale:, and a static scale generates an enum-shaped
# surface that reads the column through it — where a typo or a rename fails at the reference.
RSpec.describe "S1::Scale in the macros" do
  let(:severity) { S1.scale "cosmetic", "degraded", "blocking" }
  let(:team) { S1.scale returns: "Refunds, exchanges", billing: "Charges, invoices. Not: an insurer asking about a claim" }
  let(:ticket) { Ticket.create!(body: "x", plan: "gold") }

  before { stub_s1 { { severity: 2, department: :billing, priority: 1, grade: 1, quality_position: 2, kind: :new_case, case_type: :slip } } }

  describe "the spellings" do
    it "declares a scores with an ordinal Scale, a chooses with a nominal one — the same Request, digest and registry as the list or hash" do
      sev = severity
      tm = team
      by_scale = Class.new(Ticket) do
        scores :severity, "How severe is the issue?", sev
        chooses :department, "Which team?", tm, siblings: false
      end
      by_list = Class.new(Ticket) { scores :severity, "How severe is the issue?", "cosmetic", "degraded", "blocking" }
      expect(by_scale.find(ticket.id).s1_request(:severity).questions).to eq(by_list.find(ticket.id).s1_request(:severity).questions)
      expect(by_scale.find(ticket.id).s1_request(:department).questions).to eq(Ticket.find(ticket.id).s1_request(:department).questions)
      expect(by_scale.s1_question_digest(:severity)).to eq(by_list.s1_question_digest(:severity))
      expect(by_scale.s1_question_digest(:department)).to eq(Ticket.s1_question_digest(:department))
      expect(by_scale.s1_fields[:severity]).to include(scale: severity, levels: %w[cosmetic degraded blocking])
      expect(by_scale.s1_fields[:severity][:scale]).to be(severity)
      expect(by_scale.s1_fields[:department]).to include(scale: team, categories: team.definitions.transform_keys(&:to_sym))
      expect(by_list.s1_fields[:severity][:scale]).to eq(severity)
      expect(by_list.s1_fields[:severity][:scale].name).to end_with("#severity")
      expect(by_scale.find(ticket.id).s1_request(:severity).questions[:severity].scale).to be(severity)
    end

    it "shows an ordinal Scale's definitions as the levels and stores its labels, as label => description does" do
      described = S1.scale({ cosmetic: "no impact", degraded: "a workaround exists", blocking: "no workaround" }, ordered: true)
      klass = Class.new(Ticket) { scores :severity, "How severe is the issue?", described }
      expect(klass.find(ticket.id).s1_request(:severity).questions).to eq(ticket.s1_request(:severity).questions)
      expect(klass.s1_question_digest(:severity)).to eq(Ticket.s1_question_digest(:severity))
      expect(klass.s1_fields[:severity]).to include(levels: %w[cosmetic degraded blocking], criteria: ["no impact", "a workaround exists", "no workaround"])
      expect(Ticket.s1_fields[:severity][:scale].definitions).to eq(described.definitions)
      expect(klass.find(ticket.id).level(:severity)).to eq("blocking")
      expect(klass.find(ticket.id).level(:severity).scale).to be(described)
    end

    it "sends a described static score as the field's Scale — the texts on the wire, the digest as before, the result on the Scale" do
      question = ticket.s1_request(:severity).questions[:severity]
      expect(question.scale).to be(Ticket.severities)
      expect(question.scale.fetch(:degraded)).to be_degraded
      expect(question.levels).to eq(["no impact", "a workaround exists", "no workaround"])
      expect(Ticket.s1_question_digest(:severity)).to eq("f28cd84bcd020cdbf6e84fe561ebbd6b5bc4566edacc100c7962246c9e97d3f7")
      live = S1.config.provider.call(ticket.s1_request(:severity))[:severity]
      expect(live.level).to be_blocking
      expect(live.level.scale).to be(Ticket.severities)
      expect(live.scale).to be(Ticket.severities)
    end

    it "shows the label for a level with no description — keywords, a Hash, a dynamic Hash or Scale — as Scale#texts does" do
      shown = ->(klass) { klass.find(ticket.id).s1_request(:severity).questions[:severity].levels }
      expect(shown[Class.new(Ticket) { scores :severity, "q", lo: "low", hi: nil, siblings: false }]).to eq(%w[low hi])
      expect(shown[Class.new(Ticket) { scores :severity, "q", levels: { lo: "low", hi: nil }, siblings: false }]).to eq(%w[low hi])
      expect(shown[Class.new(Ticket) { scores :severity, "q", levels: -> { { lo: "low", hi: nil } }, siblings: false }]).to eq(%w[low hi])
      expect(shown[Class.new(Ticket) { scores :severity, "q", levels: -> { S1.scale({ lo: "low", hi: nil }, ordered: true) }, siblings: false }])
        .to eq(%w[low hi])
      expect(shown[Class.new(Ticket) { scores :severity, "q", S1.scale({ lo: "low", hi: nil }, ordered: true), siblings: false }]).to eq(%w[low hi])
    end

    it "takes a Stub's score by label or by Scale[:label] on a described field" do
      stub_s1(severity: Ticket.severities[:degraded])
      ticket.update_measure(:severity)
      expect(ticket.reload.severity).to eq("degraded")
      stub_s1(severity: "cosmetic")
      expect(ticket.level(:severity)).to be_cosmetic
      stub_s1(severity: "a workaround exists")
      expect(ticket.level(:severity)).to be_degraded
    end

    it "takes a Scale as levels: / categories: / criteria:, and measured_field picks the kind from a static one" do
      sev = severity
      tm = team
      expect(Class.new(Ticket) { scores :severity, "q", levels: sev }.s1_fields[:severity][:scale]).to be(severity)
      expect(Class.new(Ticket) { scores :severity, "q", criteria: sev }.s1_fields[:severity][:scale]).to be(severity)
      expect(Class.new(Ticket) { chooses :department, "q", categories: tm }.s1_fields[:department][:scale]).to be(team)
      expect(Class.new(Ticket) { measured_field :severity, "q", sev }.s1_fields[:severity][:kind]).to eq(:score)
      expect(Class.new(Ticket) { measured_field :department, "q", tm }.s1_fields[:department][:kind]).to eq(:choice)
      expect { Class.new(Ticket) { scores :severity, "q", sev, "extra" } }.to raise_error(ArgumentError, /levels are positional labels, or one/)
      expect { Class.new(Ticket) { scores :severity, "q", sev, levels: %w[a b] } }.to raise_error(ArgumentError, /give the levels once/)
    end

    it "refuses a Scale of the other kind, at declaration and at verify!" do
      sev = severity
      tm = team
      expect { Class.new(Ticket) { scores :severity, "q", tm } }
        .to raise_error(ArgumentError, /scores :severity takes an ordinal scale \(got #<S1::Scale returns \| billing>\)/)
      expect { Class.new(Ticket) { chooses :department, "q", sev } }
        .to raise_error(ArgumentError, /chooses :department takes a nominal scale \(got #<S1::Scale cosmetic < degraded < blocking>\)/)
      klass = Class.new(Ticket) { scores :severity, "q", sev }
      klass.s1_registry[:severity] = klass.s1_registry[:severity].merge(scale: tm)
      expect { klass.s1_verify_fields! }.to raise_error(ArgumentError, /scores :severity takes an ordinal scale/)
    end

    it "a dynamic Scale — a Proc or a method name — resolves per record like levels: / categories: do, and may return a Scale" do
      sev = severity
      by_scale = Class.new(Ticket) { scores :severity, "q", S1.scale(-> { plan == "gold" ? %w[lo hi] : sev }), siblings: false }
      by_proc = Class.new(Ticket) { scores :severity, "q", levels: -> { plan == "gold" ? %w[lo hi] : sev }, siblings: false }
      expect(by_scale.s1_fields[:severity]).to include(dynamic: true)
      expect(by_scale.s1_fields[:severity][:levels]).to be_a(Proc)
      expect(by_scale.s1_fields[:severity][:scale]).to be_dynamic
      expect(by_scale.find(ticket.id).s1_request(:severity).questions).to eq(by_proc.find(ticket.id).s1_request(:severity).questions)
      expect(by_scale.find(ticket.id).s1_request(:severity).questions[:severity].levels).to eq(%w[lo hi])
      ticket.update!(plan: "free")
      expect(by_scale.find(ticket.id).s1_request(:severity).questions[:severity].levels).to eq(%w[cosmetic degraded blocking])
      expect(by_scale.s1_plan.to_s).to include("severity (dynamic, no scale methods)")
      expect(by_scale).not_to respond_to(:severities)
      expect(by_scale.new).not_to respond_to(:severity_blocking?)
      by_name = Class.new(Routing) { chooses :case_type, "q", S1.scale(:case_types), after: :kind }
      expect(by_name.s1_fields[:case_type]).to include(categories: :case_types, dynamic: true)
      expect { Class.new(Routing) { chooses :case_type, "q", S1.scale(:nope), after: :kind }.s1_verify_fields! }
        .to raise_error(ArgumentError, /dynamic scale :nope names no method/)
    end
  end

  describe "a dynamic Scale's kind" do
    it "is the macro's when the Scale never said, and refused when it said the other; what it resolves to is held to it" do
      by_scores = Class.new(Ticket) { scores :severity, "q", S1.scale(-> { %w[lo hi] }), siblings: false }
      expect(by_scores.s1_scale(:severity).ordered).to be(true)
      expect(by_scores.s1_scale(:severity).name).to end_with("#severity")
      expect(by_scores.s1_scale(:severity).resolve(ticket)).to eq(S1.scale("lo", "hi"))
      by_chooses = Class.new(Routing) { chooses :case_type, "q", S1.scale(:case_types), after: :kind }
      expect(by_chooses.s1_scale(:case_type).ordered).to be(false)
      expect(by_chooses.s1_scale(:case_type).resolve(Routing.new)).to be_nominal
      expect { Class.new(Ticket) { scores :severity, "q", S1.scale(-> { %w[lo hi] }, ordered: false) } }
        .to raise_error(ArgumentError, /scores :severity takes an ordinal scale \(got #<S1::Scale dynamic/)
      expect { Class.new(Routing) { chooses :case_type, "q", S1.scale(:case_types, ordered: true), after: :kind } }
        .to raise_error(ArgumentError, /chooses :case_type takes a nominal scale/)
      nominal = Class.new(Ticket) { scores :severity, "q", levels: -> { S1.scale(a: "A", b: "B") }, siblings: false }
      expect { nominal.find(ticket.id).s1_request(:severity) }
        .to raise_error(ArgumentError, /scores :severity takes an ordinal scale \(got #<S1::Scale a \| b>\)/)
      ordinal = Class.new(Ticket) { chooses :department, "q", categories: -> { S1.scale("a", "b") }, siblings: false }
      expect { ordinal.s1_scale_for(:department, ticket) }.to raise_error(ArgumentError, /chooses :department takes a nominal scale/)
      expect(Class.new(Ticket) { measured_field :severity, "q", S1.scale(-> { %w[lo hi] }, ordered: false) }.s1_fields[:severity][:kind]).to eq(:choice)
      expect(Class.new(Ticket) { measured_field :severity, "q", S1.scale(-> { %w[lo hi] }) }.s1_fields[:severity][:kind]).to eq(:choice)
      expect(Class.new(Ticket) { measured_field :priority, "q", S1.scale(-> { %w[lo hi] }) }.s1_fields[:priority][:kind]).to eq(:score)
    end

    it "resolves on the record with the descriptions the method returned, named for the field" do
      klass = Class.new(Ticket) { scores :severity, "q", levels: -> { { lo: "low", hi: "high" } }, siblings: false }
      resolved = klass.s1_scale_for(:severity, ticket)
      expect(resolved.definitions).to eq("lo" => "low", "hi" => "high")
      expect(resolved.name).to end_with("#severity")
      expect(klass.s1_scale_for(:severity, ticket)).to be_ordinal
      expect(Routing.s1_scale_for(:case_type, Routing.new).definitions["mva"]).to eq("a vehicle collision")
      expect(Routing.s1_scale_for(:case_type, Routing.new).name).to eq("Routing#case_type")
      expect { Ticket.new(department: "billing", subtype: "nope").s1_category(:subtype) }
        .to raise_error(KeyError, '"nope" is not on Ticket#subtype (overcharge, missing)')
      named = Class.new(Ticket) { scores :severity, "q", S1.scale(-> { %w[lo hi] }, name: "Sev"), siblings: false }
      expect(named.s1_scale_for(:severity, ticket).name).to eq("Sev")
      said = Class.new(Routing) { chooses :case_type, "q", S1.scale(:case_types, ordered: false), after: :kind }
      expect(said.s1_scale(:case_type).name).to eq("#{said}#case_type")
      expect(said.s1_scale_for(:case_type, Routing.new).name).to eq("#{said}#case_type")
      expect { said.s1_scale_for(:case_type, Routing.new).fetch(:nope) }.to raise_error(KeyError, /:nope is not on #<Class:.*>#case_type \(mva/)
    end
  end

  describe "the generated surface" do
    let(:sev) { severity }
    let(:tm) { team }
    let(:klass) do
      s = sev
      t = tm
      Class.new(Ticket) do
        scores :severity, "q", s
        chooses :department, "q", t, siblings: false
      end
    end

    it "Model.<names> and Model.<name>_scale are the Scale; record.<name>_<key>? reads the column through it, nil being false" do
      expect(klass.severities).to be(severity)
      expect(klass.severity_scale).to be(severity)
      expect(klass.departments).to be(team)
      expect(klass.new.severity_blocking?).to be(false)
      expect(klass.new(severity: "blocking")).to be_severity_blocking
      expect(klass.new(severity: "blocking")).not_to be_severity_degraded
      expect(klass.new(department: "billing")).to be_department_billing
      expect(klass.new(department: "billing").s1_category(:department)).to eq(:billing)
      expect(klass.new(severity: "degraded").s1_category(:severity)).to eq(severity[:degraded])
      expect(klass.new(severity: "degraded").s1_category(:severity).scale).to be(severity)
      expect { klass.new(severity: "critical").severity_blocking? }.to raise_error(KeyError, /"critical" is not on the scale/)
      expect(Ticket.new(priority: 20)).to be_priority_today
      expect(Ticket.new(priority: 10)).to be_priority_can_wait
      call = Class.new(PhoneCall) do
        scores :quality_position, "q", s = S1.scale("cosmetic", "degraded", "blocking")
        s
      end
      record = call.create!(firm: Firm.create!(name: "f"), transcript: "x")
      expect(record.quality_position_blocking?).to be(false)
      record.update_measure(:quality_position)
      expect(record.quality_position).to eq(2.0)
      expect(record).to be_quality_position_blocking
    end

    it "gives an ordinal scale _at_least / _at_most / _above / _below scopes over the stored labels or indexes, a nominal with_<name>" do
      expect(klass.severity_at_least(:degraded).to_sql).to include(%q("severity" IN ('degraded', 'blocking')))
      expect(klass.severity_above("degraded").to_sql).to include(%q("severity" = 'blocking'))
      expect(klass.severity_at_most(:degraded).to_sql).to include(%q("severity" IN ('cosmetic', 'degraded')))
      expect(klass.severity_below(severity[:degraded]).to_sql).to include(%q("severity" = 'cosmetic'))
      expect(Ticket.priority_at_least(:today).to_sql).to include('"priority" IN (20, 30)')
      expect(Ticket.grade_at_least(:fair).to_sql).to include('"grade" IN (1, 2)')
      expect(klass.with_department(:billing).to_sql).to include(%q("department" = 'billing'))
      klass.create!(body: "a", severity: "blocking", department: "billing")
      klass.create!(body: "b", severity: "cosmetic", department: "returns")
      expect(klass.severity_at_least(:degraded).pluck(:body)).to eq(["a"])
      expect(klass.where(body: "b").severity_at_most(:degraded).pluck(:body)).to eq(["b"])
      expect(klass.with_department(:returns).pluck(:body)).to eq(["b"])
      expect { klass.severity_at_least(:typo) }.to raise_error(KeyError, /:typo is not on the scale/)
      expect { klass.with_department(:typo) }.to raise_error(KeyError, /:typo is not on the scale/)
      float = Class.new(PhoneCall) { scores :quality_position, "q", "lo", "hi" }
      expect { float.quality_position_at_least(:hi) }.to raise_error(ArgumentError, /keeps the expectation on a float column/)
    end

    it "casts a Level, or a label, to its index on an integer column with indexes — where and assignment land on the stored integer" do
      expect(Ticket.where(priority: Ticket.priorities[:today]).to_sql).to end_with('"priority" = 20')
      expect(Ticket.where(priority: "today").to_sql).to end_with('"priority" = 20')
      expect(Ticket.where(priority: 20).to_sql).to end_with('"priority" = 20')
      ticket.update!(priority: Ticket.priorities[:today])
      expect(ticket.reload.priority).to eq(20)
      expect(ticket).to be_priority_today
      expect(ticket.s1_category(:priority)).to eq(Ticket.priorities[:today])
      ticket.update!(priority: "now")
      expect(ticket.reload.priority).to eq(30)
      expect(Ticket.new(priority: "20").priority).to eq(20)
      expect(Ticket.new(priority: nil).priority).to be_nil
      expect { Ticket.new(priority: S1.scale("today", "later")[:today]).priority }.to raise_error(KeyError, /is on #<S1::Scale today < later>, not/)
      expect(Ticket.grades.fetch("ok", nil)).to be_nil
      expect(Class.new(Ticket) { score_enum :grade, "q", poor: 0, fair: 1, good: 2 }.new(grade: "fair").grade).to eq("fair")
    end

    it "takes a Scale over an integer enum's keys on that column as its scale, ranking by the enum's integers" do
      on_enum = Class.new(ActiveRecord::Base) do
        self.table_name = "tickets"
        include S1::Measurable

        enum :grade, { poor: 0, fair: 1, good: 2 }
        scores :grade, "q", S1.scale("poor", "fair", "good"), siblings: false
      end
      expect { on_enum.s1_verify_fields! }.not_to raise_error
      expect(on_enum.grade_at_least(:fair).to_sql).to include('"grade" IN (1, 2)')
      expect(on_enum.grade_scale).to eq(S1.scale("poor", "fair", "good"))
      reversed = Class.new(on_enum) { scores :grade, "q", S1.scale("good", "fair", "poor"), siblings: false }
      expect { reversed.s1_verify_fields! }.not_to raise_error
      other = Class.new(on_enum) { scores :grade, "q", S1.scale("bad", "fair", "good"), siblings: false }
      expect { other.s1_verify_fields! }.to raise_error(ArgumentError, /has levels on an enum column that are not its keys/)
      mismatched = Class.new(on_enum) { scores :grade, "q", S1.scale("poor", "fair", "good"), indexes: { poor: 5, fair: 6, good: 7 }, siblings: false }
      expect { mismatched.s1_verify_fields! }.to raise_error(ArgumentError, /has levels on an enum column that are not its keys/)
    end

    it "choice_enum takes a static nominal Scale as its categories, and refuses an ordinal or a dynamic one" do
      team = S1.scale(delivered: "Handed over", attempted: "Tried")
      klass = Class.new(Delivery) { choice_enum :status, "q", categories: team }
      expect(klass.s1_enums[:status]).to eq(delivered: "Handed over", attempted: "Tried")
      expect(klass.statuses).to eq("delivered" => "delivered", "attempted" => "attempted")
      expect(klass.s1_fields[:status][:categories]).to eq(delivered: "Handed over", attempted: "Tried")
      expect { Class.new(Delivery) { choice_enum :status, "q", categories: S1.scale("a", "b") } }
        .to raise_error(ArgumentError, /chooses :status takes a nominal scale \(got #<S1::Scale a < b>\)/)
      expect { Class.new(Delivery) { choice_enum :status, "q", categories: S1.scale(:kinds) } }
        .to raise_error(ArgumentError, /:status has a dynamic scale on an enum column: the enum is the scale/)
    end

    it "an enum column keeps Rails' own surface and gets _scale (and the rank scopes on a score_enum); a dynamic field gets none" do
      expect(Delivery.status_scale).to eq(S1.scale(delivered: nil, attempted: nil, undeliverable: nil))
      expect(Delivery.statuses).to eq("delivered" => "delivered", "attempted" => "attempted", "undeliverable" => "undeliverable")
      expect(Delivery).not_to respond_to(:with_status)
      expect(Delivery.new).not_to respond_to(:status_delivered?)
      expect(Ticket.grade_scale).to eq(S1.scale("poor", "fair", "good"))
      expect(Ticket.grades).to eq("poor" => 0, "fair" => 1, "good" => 2)
      expect(Ticket).to respond_to(:grade_at_least)
      expect(Ticket.new).not_to respond_to(:grade_fair?)
      expect(Ticket).not_to respond_to(:subtype_scale)
      expect(Ticket).not_to respond_to(:subtypes)
      expect(Routing).not_to respond_to(:case_type_scale)
      expect { Routing.s1_scale(:case_type).fetch(:mva) }.to raise_error(S1::ValidationError, /dynamic; resolve it first/)
      expect(Routing.s1_scale_for(:case_type, Routing.new)).to eq(S1.scale(mva: nil, slip: nil, other: nil))
    end

    it "refuses a predicate spelling an attribute method of a column, or another field's predicate" do
      fresh = -> { Class.new(ActiveRecord::Base) { self.table_name = "tickets" }.include(S1::Measurable) } # no attribute methods yet
      expect { fresh.call.scores :severity, "q", "low", "index", "expectation" }
        .to raise_error(ArgumentError, /:severity's scale would define severity_index\?, which is an attribute method of "severity_index"; rename the label/)
      expect { fresh.call.chooses :department, "q", changed: "it changed", same: "the same", siblings: false }
        .to raise_error(ArgumentError, /would define department_changed\?, which is an attribute method of "department"/)
      expect { Class.new(Ticket) { scores :severity, "q", "low", "index", "expectation" } } # Ticket's attribute methods are defined
        .to raise_error(ArgumentError, /would define severity_index\?, which would overwrite .*'s own severity_index\?/)
      expect do
        Class.new(Ticket) do
          chooses :plan, "q", b_c: "x", d: "y"
          chooses :plan_b, "q", c: "x", e: "y"
        end
      end.to raise_error(ArgumentError, /:plan_b's scale would define plan_b_c\?, which would overwrite .*'s own plan_b_c\?/)
      expect { Class.new(Ticket) { scores :severity, "q", "low", "index", "expectation", scale_methods: false } }.not_to raise_error
    end

    it "reads a blank string column as no category, like nil" do
      expect(Ticket.new(department: "").department_billing?).to be(false)
      expect(Ticket.new(department: "").s1_category(:department)).to be_nil
      expect { Ticket.new(department: " ").s1_category(:department) }.to raise_error(KeyError)
    end

    it "raises at declaration on a name in use, at verify! on one redefined since; scale_methods: false generates none" do
      s = sev
      expect do
        Class.new(Ticket) do
          def self.severities = 1
          scores :severity, "q", s
        end
      end
        .to raise_error(ArgumentError, /:severity's scale would define severities, which would overwrite .*'s own severities; rename it/)
      expect do
        Class.new(Ticket) do
          def severity_blocking? = true
          scores :severity, "q", s
        end
      end
        .to raise_error(ArgumentError, /would define severity_blocking\?, which would overwrite/)
      expect { Class.new(Ticket) { scores :severity, "q", s } }.not_to raise_error # Ticket's own generated names: a redeclaration
      redefined = Class.new(Ticket) do
        scores :severity, "q", s
        def self.severities = 1
      end
      expect { redefined.s1_verify_fields! }.to raise_error(ArgumentError, /severities is a scale's generated method, redefined at/)
      below = Class.new(ActiveRecord::Base) do
        self.table_name = "tickets"
        include S1::Measurable

        chooses :department, "q", returns: "R", billing: "B", siblings: false
        enum :department, { returns: "returns", billing: "billing" }
      end
      expect { below.s1_verify_fields! }.to raise_error(ArgumentError, /:department is an enum declared below its macro; declare the enum above it/)
      bare = Class.new(ActiveRecord::Base) do
        self.table_name = "tickets"
        include S1::Measurable

        chooses :department, "q", siblings: false
        enum :department, { returns: "returns", billing: "billing" }
      end
      expect { bare.s1_verify_fields! }.not_to raise_error
      expect { bare.s1_scale(:department) }.to raise_error(ArgumentError, /has no scale \(a judge, or an enum declared after it\)/)
      expect(bare).not_to respond_to(:department_scale)
      quiet = Class.new(Ticket) { chooses :department, "q", :a, :b, scale_methods: false, siblings: false }
      expect(quiet).not_to respond_to(:with_department)
      expect(quiet.new).not_to respond_to(:department_a?)
      expect(quiet).not_to respond_to(:departments) # Ticket's, dropped by the redeclaration
      expect(Ticket).to respond_to(:departments)
      expect(quiet.s1_scale(:department)).to eq(S1.scale(a: nil, b: nil))
      expect(Class.new(Ticket)).to respond_to(:departments) # inherited as is, reading this class's registry
      expect { Ticket.s1_scale(:escalate) }.to raise_error(ArgumentError, /:escalate has no scale \(a judge/)
      expect { Ticket.s1_scale(:nope) }.to raise_error(ArgumentError, /:nope is not a measured field/)
    end
  end

  describe "the audit and the lens" do
    it "rehydrates a static field's Level on the field's Scale, and a dynamic one's on a Scale of the stored labels" do
      ticket.update_measure(:severity, :department, :grade)
      ticket.reload
      expect(ticket.measurement(:severity).level.scale).to be(Ticket.severities)
      expect(ticket.measurement(:severity).level).to be_blocking
      expect(ticket.measurement(:severity).levels.map(&:scale)).to all(be(Ticket.severities))
      expect(ticket.measurement(:department).scale).to be(Ticket.departments)
      expect(ticket.measurement(:grade).level.scale).to be(Ticket.grade_scale)
      expect(ticket.measurement(:severity).level.scale == Ticket.severities).to be(true)
      expect(ticket.measurement(:severity).level).to eq(Ticket.severities.fetch(:blocking))
      routing = Routing.create!(transcript: "rear-ended", kind: "new_case")
      routing.update_measure(:case_type)
      expect(routing.reload.measurement(:case_type).scale).to eq(S1.scale(mva: nil, slip: nil, other: nil))
      renamed = Class.new(Ticket) { scores :severity, "q", "cosmetic", "degraded", "blocked" }
      expect(renamed.find(ticket.id).measurement(:severity).level.scale).to eq(Ticket.severities)
      expect(renamed.find(ticket.id).measurement(:severity).level.scale).not_to eq(renamed.severities)
    end

    it "keeps the field's Scale when the provider leaves a zero-mass category out, and the audit stores the whole scale" do
      stub_s1 { { department: { choice: :billing, probabilities: { billing: 1.0 }, confidence: 1.0 } } }
      ticket.update_measure(:department)
      expect(ticket.reload.measurement(:department).scale).to be(Ticket.departments)
      expect(ticket.measurement(:department).scale.fetch(:returns)).to be(:returns)
      expect(ticket.measurement(:department)[:returns]).to eq(0.0)
      expect(ticket.s1_answers.dig("department", "scale")).to eq(%w[returns billing])
      expect(ticket.s1_answers.dig("department", "probabilities")).to eq("returns" => 0.0, "billing" => 1.0)
    end

    it "a sequenced field's lens carries the earlier collapse as the column holds it; the scale takes it back as a category" do
      routing = Routing.create!(transcript: "rear-ended", kind: "new_case")
      lens = routing.s1_request(:case_type).state.fetch(:kind)
      expect(lens).to eq("new_case")
      expect(Routing.kinds.fetch(lens)).to eq(:new_case)
      expect(Routing.kinds.fetch(lens)).to eq(Routing.kinds[:new_case])
      expect(routing).to be_kind_new_case
    end
  end

  describe "the foot-gun" do
    it "a label spelled as a literal goes silently false when the label is renamed; a reference through the scale raises" do
      original = Class.new(Ticket) { scores :severity, "q", S1.scale("cosmetic", "degraded", "blocking") }
      original.find(ticket.id).update_measure(:severity)
      expect(original.find(ticket.id).severity == "blocking").to be(true)
      expect(original.severities.fetch(:blocking)).to eq("blocking")
      renamed = Class.new(Ticket) { scores :severity, "q", S1.scale("cosmetic", "degraded", "blocked") }
      renamed.find(ticket.id).update_measure(:severity)
      expect(renamed.find(ticket.id).severity == "blocking").to be(false) # the literal: silently false
      expect { renamed.severities.fetch(:blocking) }.to raise_error(KeyError, ":blocking is not on the scale (cosmetic, degraded, blocked)")
      expect { renamed.find(ticket.id).severity_blocking? }.to raise_error(NoMethodError)
      expect(renamed.find(ticket.id)).to be_severity_blocked
      expect { renamed.severity_at_least(:blocking) }.to raise_error(KeyError)
      expect { renamed.find(ticket.id).s1_category(:severity).blocking? }.to raise_error(NoMethodError)
    end
  end
end
