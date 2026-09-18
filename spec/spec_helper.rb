# frozen_string_literal: true

require "active_record"
require "s1-rails"

ActiveRecord::Base.establish_connection(adapter: "sqlite3", database: ":memory:")
ActiveRecord::Schema.verbose = false
ActiveRecord::Schema.define do
  create_table :firms do |t|
    t.string :name
    t.json :preferences
  end
  create_table :deliveries do |t|
    t.string :status
    t.integer :priority
    t.string :note
    t.boolean :note_needed
    t.integer :priority_score
    t.timestamps
  end
  create_table :replies do |t|
    t.text :body
    t.text :note
  end
  create_table :tickets do |t|
    t.text :body
    t.string :plan
    t.boolean :escalate
    t.float :escalate_probability
    t.string :department
    t.float :department_confidence
    t.string :severity
    t.integer :severity_index
    t.float :severity_expectation
    t.integer :priority
    t.integer :grade
    t.string :subtype
    t.json :s1_answers
    t.timestamps
  end
  create_table :routings do |t|
    t.text :transcript
    t.string :kind
    t.string :case_type
    t.boolean :urgent
    t.float :urgent_probability
    t.json :s1_answers
    t.timestamps
  end
  create_table :phone_calls do |t|
    t.references :firm
    t.text :transcript
    t.boolean :is_lead
    t.float :lead_probability
    t.string :case_type
    t.integer :case_type_confidence
    t.integer :quality
    t.float :quality_position
    t.string :quality_level
    t.json :s1_answers
    t.integer :legacy_score
    t.decimal :lead_mass, precision: 6, scale: 4
    t.timestamps
  end
  create_table :pickers do |t|
    t.json :labels
    t.json :policy
    t.string :pick
  end
  create_table :sharers do |t|
    t.boolean :a
    t.boolean :b
    t.float :shared
  end
  create_table :gradings do |t|
    t.text :body
    t.integer :priority
    t.json :priority_probabilities
    t.string :team
    t.json :team_probabilities
    t.boolean :flag
    t.json :flag_probabilities
    t.json :s1_answers
    t.timestamps
  end
end

class Firm < ActiveRecord::Base
  include S1::Measurable

  has_many :phone_calls
end

class PhoneCall < ActiveRecord::Base
  include S1::Measurable

  belongs_to :firm

  s1_state { { transcript: transcript } }
  s1_state(:review) { { transcript: transcript, firm: firm } }
  s1_state(:window) { |last: 20| { transcript: transcript.to_s[-last..] || transcript } }
end

# The kind-named macros, every option, and the enums that are also questions.
class Ticket < ActiveRecord::Base
  include S1::Measurable

  DEPARTMENTS = { returns: "Refunds, exchanges", billing: { is: "Charges, invoices", not: "an insurer asking about a claim" } }.freeze
  SUBTYPES = { returns: { damaged: "arrived broken", unwanted: "changed their mind" },
               billing: { overcharge: "charged too much", missing: "a payment not showing" } }.freeze

  measurable_as           { { body: body } }
  measurable_as(:planned) { { body: body, plan: plan } }
  measured_against        { { policy: "30 days" } }

  # The siblings — escalate_probability, department_confidence, severity_index, severity_expectation — are found by name.
  judges  :escalate,   "Is the customer asking for a human agent?", true: ["asks for a person", "threatens to leave"],
                                                                    false: "a routine request", threshold: 0.7
  chooses :department, "Which team?", **DEPARTMENTS, as: :planned, given: :department_lens
  scores  :severity,   "How severe is the issue?", cosmetic: "no impact", degraded: "a workaround exists", blocking: "no workaround"
  scores  :priority,   "How urgent?", { "can wait" => 10, "today" => 20, "now" => 30 }
  chooses :subtype,    "What kind, within `department`?", categories: :subtypes, after: :department
  score_enum :grade,   "How good was the exchange?", poor: 0, fair: 1, good: 2

  def department_lens = { desk: "front" }
  def subtypes = SUBTYPES.fetch(department&.to_sym, { none: "no department yet", unknown: "cannot tell" })
end

# A trigger on an attribute, a sequenced field gated by the earlier answer, and a dynamic scale from a method.
class Routing < ActiveRecord::Base
  include S1::Measurable

  KINDS = { new_case: "a prospective client describing a matter", existing: "a current client", other: "anything else" }.freeze

  measurable_as { { transcript: transcript } }

  chooses :kind,      "What kind of call, from `transcript`?", **KINDS, measure_on: :transcript
  chooses :case_type, "Which case type, given `kind`?", categories: :case_types, after: :kind, measure_on: :transcript, if: :new_case?
  judges  :urgent,    "Does the caller need a reply today?", measure_on: :save, if: :saved_change_to_transcript?

  def case_types = { mva: "a vehicle collision", slip: "a fall on premises", other: "none of these" }
  def new_case? = kind == "new_case"
end

# The pre-theory spellings, kept: measured_field infers the kind; s1_enum is choice_enum.
class Delivery < ActiveRecord::Base
  include S1::Measurable

  measured_field :note_needed, "Does the delivery need a note?" # boolean column → judge
  measured_field :priority_score, "How urgent?", { "can wait" => 10, "today" => 20, "now" => 30 } # integer column → score, explicit indexes

  s1_state(:sms) { |body:| { message: body } }
  s1_enum :status, "What is the sender reporting?",
          delivered: "Handed over or left somewhere", attempted: "Tried, no one there", undeliverable: "Bad address"
  s1_enum :priority, values: [0, 1], low: "Can wait", high: "Same day", prefix: true
  enum :note, { fragile: "fragile", bulky: "bulky" }
end

class Reply < ActiveRecord::Base
  validates :body, judge: "Is `body` a coherent support request?"
  validates :note, noul: { with: "Does `note` ask us to write to a different address?", expect: false, threshold: 0.8 },
                   if: :will_save_change_to_note?
end

class TriagedCall < ActiveRecord::Base
  self.table_name = "phone_calls"
  include S1::Measurable

  s1_state { { transcript: transcript } }

  before_save -> { assign_ask { |q| q.choose :case_type, "Type?", mva: "car", slip: "fall" } }, if: :will_save_change_to_transcript?
end

class LegacyCall < ActiveRecord::Base
  self.table_name = "phone_calls"
  include S1::Measurable
end

# Rails wires GlobalID for ActiveRecord in its railtie; the bare suite does it here.
GlobalID.app = "s1-rails-spec"
ActiveRecord::Base.include(GlobalID::Identification)
ActiveJob::Base.queue_adapter = :test
ActiveJob::Base.logger = Logger.new(nil)

RSpec.configure do |config|
  config.include ActiveJob::TestHelper
  config.example_status_persistence_file_path = ".rspec_status"
  config.disable_monkey_patching!
  config.expect_with(:rspec) { |c| c.syntax = :expect }

  config.before do
    clear_enqueued_jobs
    S1.reset_config!
    S1.clear_hooks!
    PhoneCall.delete_all
    Ticket.delete_all
    Routing.delete_all
    Reply.delete_all
    Firm.delete_all
  end
end

def stub_s1(answers = {}, &)
  S1.config.provider = S1::Providers::Stub.new(answers, &)
end
