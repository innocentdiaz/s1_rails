# s1-rails

![preview](https://github.com/innocentdiaz/s1_rails/blob/master/preview.png?raw=true)

s1-rails applies [s1-ruby](https://github.com/innocentdiaz/s1_ruby) — evidence prepared into a **state**, measured by a **question** into a **distribution** over a **scale**, collapsed to a **category** — where Rails keeps its data. An ActiveRecord **record** is measurable, a **column** is where a measurement collapses, a **relation** is a stream. Validations, callbacks, ActiveJob and notifications are where the verbs plug in.

**TABLE of CONTENTS**

- [TL;DR](#tldr)
- [The idea, applied to Rails](#the-idea-applied-to-rails) — measurable · lens · measure · collapse · stream · where the verbs plug in
- [Install](#install)
- [Declaring](#declaring) — [forms](#forms-how-a-record-is-measurable) · [the lens](#the-lens-what-a-record-is-judged-against) · [`judges` / `chooses` / `scores`](#judges--chooses--scores-how-a-column-is-measured) · [the scale as a value](#the-scale-as-a-value) · [when](#when-measure_on) · [sequenced fields](#sequenced-fields-after) · [a dynamic scale](#a-dynamic-scale) · [sibling columns](#sibling-columns) · [rehydration](#rehydration) · [many ways, one path](#many-ways-one-path) · [sharp knives](#sharp-knives) · [foot-guns](#foot-guns-this-dsl-refuses) · [`choice_enum`](#choice_enum-an-enum-that-is-a-choice)
- [Measuring](#measuring) — the verbs on a record · `given` per call
- [Collapsing](#collapsing) — [`update_measure`](#update_measure-measure-collapse-save) · [`assign_measure`](#assign_measure-collapse-without-saving) · [`update_measure_later`](#update_measure_later-off-the-request-thread) · [callbacks and validations](#callbacks-and-validations)
- [Streams](#streams) — [a relation: measure, collapse, or filter](#a-relation-measure-collapse-or-filter) · [`measure_all`](#measure_all-a-relation-measured) · [`update_measure_all`](#update_measure_all-a-relation-collapsed) · [`where_judged`](#where_judged--where_is--where_same_as-a-relation-filtered) · [predicates](#predicates-over-relations)
- [Assessments](#assessments) — [when the questions are data](#when-the-questions-are-data) · [an example: refund eligibility](#an-example-refund-eligibility) · [generating one](#generating-one) · [rules](#rules)
- [Plumbing](#plumbing) — [caching](#caching) · [cost and telemetry](#cost-and-telemetry) · [testing](#testing) · [the boot check](#the-boot-check)
- [Explicit vs on the record](#explicit-vs-on-the-record)
- [Dictionary and aliases](#dictionary-and-aliases)
- [Usage scenarios](#usage-scenarios) — models · callbacks · controllers and webhooks · mail · batch and console

## TL;DR

A lost-and-found office. Things get found on trains; people text to say something is theirs.
Two models, one judgement between them, and every Rails seam the verbs plug into.

```ruby
class Item < ApplicationRecord                       # something found on a train
  has_many :claims

  include S1::Measurable
  measurable_as { { description:, line:, since: created_at&.strftime("%Y-%m-%d") } }   # hash shorthand for columns; created_at is nil before the first save

  choice_enum :category, "What is it?",
    umbrella: "an umbrella",
    phone: "a phone",
    bag: "a bag or case",
    other: "anything else",
    measure_on: :create                            # collapse into the column, off the request thread (a job)

  scope :unclaimed, -> { where(claimed: false) }
end

class Claim < ApplicationRecord                      # someone says it's theirs
  belongs_to :item

  include S1::Measurable
  measurable_as { { story: story, item: item } }     # the item renders through its own form — an association is a nested measurable

  judges :plausible, "Is `story` a plausible account of losing the `item`?",           # float columns: the probabilities, kept
                 measure_on: :validation, if: :will_save_change_to_story?             # measured inside the save, before validations —
  judges :match,     "Is `story` describing the same object as `item`?",              # both fields, one call
                 measure_on: :validation, if: :will_save_change_to_story?
  validates :plausible, numericality: { greater_than: 0.5, message: "doesn't sound like this item" }   # the gate, in Rails' own words
  scope :likely, -> { where(match: 0.8..) }          # the collapse happens in SQL, later, at whatever threshold the query wants
end

# app/controllers/claims_controller.rb — an inbound SMS: "left my black umbrella on the 8:15 this morning, wooden handle"
def create
  item = Item.unclaimed.where(created_at: 1.week.ago..).where_same_as(params[:body], concurrency: 8).first   # which item is this text about?
  return redirect_to root_path, notice: "Nothing like that has been handed in yet." unless item

  claim = Claim.new(item: item, story: params[:body])          # measures plausibility and match, validates, saves
  claim.save ? redirect_to(claim) : redirect_to(root_path, alert: claim.errors.full_messages.to_sentence)
end

# a nightly cleanup: a relation is a stream, and the where_ verbs return relations
Item.unclaimed
    .where(created_at: ..30.days.ago)
    .given(note: "we keep anything with an owner's name or over £20")        # the lens for every judgement down the chain
    .where_is_not("worth keeping", concurrency: 8)                          # the relation's is?: "Is this worth keeping?"
    .destroy_all
Claim.likely.count                                   # how many claims are probably right — no threshold was ever hard-coded
```

Read down the right-hand side: `choice_enum … measure_on: :create` (a job), `judges …
measure_on: :validation` (a callback) feeding a plain `validates :plausible, numericality:` (a
validation on the measured column), `where_same_as(text)` (a cross-record judgement over the
relation), `where_is_not` (a stream), `where(match: 0.8..)` (the collapse, deferred to the query).
[This example runs](spec/s1/lost_and_found_spec.rb) against the Stub provider.

## The idea, applied to Rails

s1's movement is four positions and three arrows — **evidence** ─prepare─▶ **state** ─measure─▶
**distribution** ─collapse─▶ **category** — with plain Ruby between the last two; s1's
THEORY.md owns the theory. Rails already has a place for each position: the record is the
evidence, a form prepares it, the column type says what the row keeps.

```
Record  +  Form (given)  ──measurable_as──▶  state  ──judge / choose / score──▶  distribution  ──column type──▶  the row
                                                                                       │
Relation (a stream)  ──where_judged · update_measure_all · &ψ.is──▶  one call per record   float keeps it · boolean / integer / string collapse it
```

**A form prepares the record.** `measurable_as { { subject: subject, body: body } }` is the
rendering — what the record looks like to the model: the state, the facts, fixed once per
measurement. `(ψ record)` is `record.as_measurable` — a record defines `to_s1`, so ψ,
`S1.to_state` and every predicate convert it through its default form.

**The lens is what it is judged against.** A plan, a policy, a firm's criteria: `measured_against`
declares it once, `given` supplies it per call, and the state becomes `{ this: facts, **lens }`.
The two adjustments stay apart: a form changes the evidence (the rendering), a definition
changes what a question means, the lens changes what the question is applied to. `measured_against` is
the persistent spelling of s1's `given`: what the record is judged against travels with the
record instead of being passed at every call.

**Measure is a verb on the record.** `judge`, `choose`, `score`, `measure` (several at once)
live on the record and delegate to its default form, under s1's naming rule: a verb measures
and returns the distribution; a noun returns the thing it names; a `?` returns a boolean.
`ticket.judge "…"` is an `Answer::Noul`, `ticket.judge? "…"` a boolean; `choose` an
`Answer::Choice`, `choice` the category (a Symbol); `score` an `Answer::Score`, `level` the
level (an `S1::Level`) — exactly as on an `S1::State`, and by the same identity:
`ticket.choice(…) == ticket.choose(…).collapse`, `ticket.level(…) == ticket.score(…).collapse`.
The one asymmetry is deliberate: `noul` is the dichotomous distribution's proper name, so
`ticket.noul "…"` is `ticket.judge "…"` — the distribution, not a collapse. The nominal and
ordinal distributions have no name of their own, so their nouns can only name the category.

**Collapse is a write.** `update_measure` / `assign_measure` measure and put the distributions
into columns, and **the column type says what the row keeps**: a boolean column collapses a
judge at the threshold, an enum or string column keeps the category, an integer column keeps a
score's level index (declared, else its rank), and a float or decimal column is not a collapse
at all — it keeps a judge's whole distribution (its one number) or a score's expectation, a
number that names no level. Schema says how much of the distribution survives; a json
`s1_answers` column keeps the whole measurement beside its collapse, and is where a float
column's category is read back from.

**A relation is a stream.** `where_judged` / `where_is` / `where_same_as` filter it,
`update_measure_all` collapses every row, `measure_all` measures without writing, and s1's
predicates (`&ψ.is`, `&ψ.choose`, `&ψ.score`, `&ψ.judge`) work on records directly, so
`select`, `group_by`, `sort_by` and `sum` over a relation are semantic.

**The questions are declared on the schema.** `judges` / `chooses` / `scores` (and `measured_field`,
which resolves the kind) put each column's question and definitions — its levels and category
descriptions, or its own `S1::Scale` — and its own form, lens and threshold, when they differ,
next to the column, so `update_measure(:column)` needs nothing else and the labels are written
once.

**Facts, lens, questions.** Every measurement has three axes, declared once or chosen per call,
and every verb takes all three the same way:

| axis | what it answers | declared | per call |
|---|---|---|---|
| **facts** | what is measured | `measurable_as` (forms) | `as: :thread` |
| **lens** | what it is judged against | `measured_against` | `given: { … }` / `.given(…)` |
| **questions** | which measurements | `judges` / `chooses` / `scores` / `choice_enum` | the block, or column names |

**Where the verbs plug in.** Validations: `validates :body, judge: "…"` — a judgement that
gates a save. Callbacks: `measure_on: :validation`, or `assign_measure` in `before_validation`,
the collapse landing inside the same save. Jobs: `update_measure_later` runs the measure in
`S1::MeasureJob`. Notifications: every call emits `ask.s1`, the ledger's hook, labelled by the
caller's `metadata:` ([Cost and telemetry](#cost-and-telemetry)).

## Install

```ruby
gem "s1-rails"
```

```ruby
# config/initializers/s1.rb — only what differs from the defaults
S1.configure do |c|
  c.typesafe.api_key = Rails.application.credentials.typesafe_api_key
  c.cache            = Rails.cache
  c.psi              = true         # defines ψ; every ψ in this README assumes it
end
```

The Railtie sets `logger` to `Rails.logger`. Ruby ≥ 3.2, Rails ≥ 7.1. s1's own settings (`provider`, `threshold`, `primitives`)
are documented in its README.

# Declaring

## Forms: how a record is measurable

`measurable_as` (alias `s1_state`) declares the rendering once: the facts, and so the state.
`record.s1_facts(:name)` is that rendering alone — the plumbing word, what sits at `this` under
a lens (`s1_state` is its old name); the state, facts plus lens, is what `as` returns.
Declare several, named, when different questions need different views of the same record; pick
one with `as_measurable` (alias `as`). Every rendering omits, and the omission is invisible to
the judgement — a form is also a decision about what counts as evidence.

```ruby
class SupportTicket < ApplicationRecord
  include S1::Measurable

  measurable_as           { { subject: subject, body: body } }                                 # :default — what the ticket is
  measurable_as(:thread)  { |last: 5| { subject: subject, messages: messages.last(last).map(&:body) } }   # another view of the facts
end

ticket.as_measurable(:thread, last: 10).judge?("...")
ticket.update_measure(as: :thread) { |q| ... }
(ψ ticket)                                                              # the default form, as a State
(ψ ticket, as: :thread, last: 10)                                       # a named one, with arguments
```

Each form is an instance method (`s1_state_thread`), so subclasses override it and forms
can call each other. A nested record that is itself `Measurable` is rendered through its own
default form; any other record contributes its `attributes`; a record met inside its own form
(`item: self`) is its `attributes` rather than a recursion. A model with no form at all is its
`attributes` less what is never evidence — the key, the timestamps, `s1_answers`, and every
measured column with its siblings (`Model.s1_omitted`): a measurement is not its own evidence,
so a re-measure never shows the model its last verdict. `verify!` warns when a field would
measure through no declared form (none on the model, none on the field), and `s1_plan` prints
the attributes it sends; `measurable_as { attributes }` is the spelling that means all of them. `as_measurable` returns an `S1::Measurable::State` — an `S1::State` that also
knows its record: the same verbs, plus the writes under [Collapsing](#collapsing) — tagged
`owner: record, form: name` for the ledger.

A named form earns its place when the *facts* differ (`:thread` is a different view); "with
the policy attached" is not a different record, it is a different lens.

## The lens: what a record is judged against

A form holds facts — what a measurement is *of*. The lens — a plan, a policy, a firm's criteria —
is what it is judged *against*; it goes beside the facts, never among them. `measured_against`
(alias `measured_given`) declares the model's default lens, evaluated per record like a form;
`given:` on any verb — a string question or a declared column alike — or the fluent `.given(…)`
(alias `against`, "judged against"), merges a per-call lens over it.

```ruby
class SupportTicket < ApplicationRecord
  include S1::Measurable
  measurable_as    { { subject: subject, body: body } }         # the facts
  measured_against { { policy: store.refund_policy } }          # the lens, by default — evaluated per record, like a form
  judges :within_policy, "Is `this` within `policy`?", measure_on: :validation           # a declared trigger can use it
end

ticket.is? "within policy"                                     # state sent: { this: { subject:, body: }, policy: … }
ticket.judge? "Is `this` covered by `plan`?", given: { plan: customer.plan }   # given: on a string question
ticket.judge?(:within_policy, given: { policy: strict })           # given: on a declared column — its own question, this lens
ticket.update_measure(:within_policy, given: { policy: strict })   # per-call given: merges over the declared lens
ticket.given(plan: customer.plan).is? "covered by `plan`"          # fluent, same merge
SupportTicket.open.given(policy: p).where_is("within policy")      # a stream, same axes
ticket.update_measure_later(:within_policy, given: { policy: p })  # the job carries it
```

With any lens the state is `{ this: facts, **lens }`; with none, the facts alone — so a model
without `measured_against` behaves exactly as before. `given` on a record puts the default form
under `this` and the lens beside it, for one call; `measured_against` does the same job for
every call.

## judges / chooses / scores: how a column is measured

Declare a column's question once, by scale kind — `judges` (dichotomous: a boolean column stores
the collapse, a float the mass), `chooses` (nominal: string, text or enum), `scores` (ordinal:
integer with indexes, float, string, or an enum via `score_enum`) — and every spelling of that
measurement reaches one code path and sends one Request ([Many ways, one path](#many-ways-one-path)).

```ruby
class SupportTicket < ApplicationRecord
  include S1::Measurable
  measurable_as           { { subject: subject, body: body } }
  measurable_as(:planned) { { subject: subject, body: body, plan: plan } }
  measured_against        { { policy: store.refund_policy } }

  judges  :is_lead,   "Is this a potential new client?", true: "a new matter", false: "an existing client", threshold: 0.7
  chooses :team,      "Which team?", returns: "Refunds", billing: { is: "Charges, invoices", not: "an insurer asking about a claim" },
                      as: :planned, given: :desk
  chooses :subtype,   "What kind, within `team`?", categories: :subtypes_for_team, after: :team
  scores  :severity,  "How severe?", cosmetic: "no impact", degraded: "a workaround exists", blocking: "none"
  scores  :priority,  "How urgent?", { "can wait" => 10, "today" => 20, "now" => 30 }
  score_enum :grade,  "How good was the exchange?", poor: 0, fair: 1, good: 2

  def desk = { desk: store.desk }
  def subtypes_for_team = store.subtypes.fetch(team, { none: "no team yet", unknown: "cannot tell" })
end
```

| macro | the scale, once | aliases |
|---|---|---|
| `judges name, q` | `true:` / `false:` — a String, or Strings joined `"; "`; `criteria:` the wire form (`{ true:, false: }`, checked at declaration) | `noul_field` |
| `chooses name, q` | bare labels · `label: "description"` · `label: { is:, not: }` · a nominal `S1::Scale` ([below](#the-scale-as-a-value)) · `categories:` (a Hash, an Array, a Scale, or a Proc / method name — [a dynamic scale](#a-dynamic-scale)) — `choices:` and `criteria:` spell it too, one of the three · nothing: the enum's keys | `choice_field` |
| `scores name, q` | positional labels · one `{ label => integer }` Hash · `label: "description"` · an ordinal `S1::Scale` · `levels:` (a list, a Hash, a Scale, or a Proc / method name; `criteria:` spells it too) · `indexes: { label => integer }` beside positional labels, a `levels:` list, or `label: "description"` (a `{ label => integer }` Hash already gives them; a dynamic scale takes none) | `score_field` |
| `measured_field name, q, …` | the resolving form: a static `S1::Scale` by its kind; levels or `indexes:` → scores; `true:` / `false:` → judges; a description hash or `categories:` → chooses; `criteria:` by its shape (`{ true:, false: }` → judges, a list → scores, a Hash → chooses); else the column — an enum → chooses, boolean / float / decimal → judges, integer → scores, string / text → chooses; any other column raises, naming the three | `s1_field`, `measured_attribute`, `measurable_field` |
| `choice_enum name, q, **descriptions` | the Rails `enum` (string-backed unless `values:`) and the chooses; `categories: { label => description }` in place of the keywords — [below](#choice_enum-an-enum-that-is-a-choice) | `measured_enum`, `s1_enum` |
| `score_enum name, q, **label_to_int` | the Rails `enum` with those integers and the scores with those indexes | `measured_score_enum` |

**Definition: the label, and what it means.** The scale's labels are what the row stores; the
definitions are what the model reads, and they differ when the declaration says so (`criteria:`
is the wire word for them, and the keyword). A judge's
`true:` / `false:` take a String or an Array (`true: ["asks for a person", "threatens to
leave"]` is sent as `"asks for a person; threatens to leave"`). A choose's `label: { is:, not: }`
sends `"Charges, invoices. Not: an insurer asking about a claim"` — an exclusion, in the
description. A score's `label: "description"` shows the description and stores the label:

```ruby
ticket.s1_request(:severity).questions[:severity].levels   # => ["no impact", "a workaround exists", "none"]   what the model reads
ticket.score(:severity).level                              # => "degraded"           the distribution, over the labels — the verb's collapse is the noun
ticket.level(:severity)                                    # => "degraded"           the label — an S1::Level, position 1
ticket.update_measure(:severity); ticket.severity          # => "degraded"           what the row stores
ticket.measurement(:severity).collapse == ticket.level(:severity)   # => true
```

The descriptions live on the Question alone: the distribution that comes back speaks the
column's scale, so `score(:col).collapse == level(:col)`, `case measure(:col) in { col:
^(Model.cols.fetch(:degraded)) }` matches (the literal `"degraded"` does too, until the label is
renamed — [The scale as a value](#the-scale-as-a-value)), and the row, the audit and the rehydrated
measurement all name the same point. A block that rewords a declared score's levels (`q.score :severity, "…", "a",
"b"`, or `criteria: %w[a b]`, the wire word) is measured over *those* labels — `measure` keeps
the distribution, and the audit's `scale` would say so — but `update_measure` / `assign_measure`
refuse it, naming both scales: reword without a scale, or ask under another id
([Foot-guns](#foot-guns-this-dsl-refuses)).

`true:` / `false:` / `not:` and every description are prompt text: they adjust what the concept
*means*, and how the model honours them is the provider's behaviour, not the gem's.

### The scale as a value

The labels of a `chooses` / `scores` field are one `S1::Scale` — built from the inline list or
hash, or declared as one and handed to the macro where the list went. Both spellings send the
same Request and keep the same digest; the difference is where the labels live:

```ruby
scores :severity, "How severe?", "cosmetic", "degraded", "blocking"     # inline: the scale is built for you
Severity = S1.scale "cosmetic", "degraded", "blocking"                  # as a value: spelled once …
scores :severity, "How severe?", Severity                               # … and referenced here, and everywhere else
```

Either way `SupportTicket.severities` is the scale, and a static one generates an enum-shaped
surface that reads the column *through* it:

| generated | on | reads |
|---|---|---|
| `SupportTicket.severities` (the field pluralised) · `SupportTicket.severity_scale` | every static `scores` / `chooses`; an enum column, declared above the macro, gets `_scale` only (below it, verify! refuses) | the field's `S1::Scale` (`Severity` itself when given) |
| `ticket.severity_blocking?` — one per label, by its snake-cased key | non-enum fields | the column through the scale: `nil` or `""` → false, a value off the scale raises — `KeyError` on a string column (`"critical"`), an integer column's off-index `ArgumentError` naming the indexes; a float column answers from the audit, not the number |
| `SupportTicket.severity_at_least(:degraded)` · `_at_most` · `_above` · `_below` | every ordinal field, `score_enum` included | `where(severity: …)` over the stored labels, or an integer column's indexes; a float column raises (it keeps the expectation). An `IN` list: a row holding a value off the scale is in no rank scope — `where.not(severity: Model.severity_scale.labels)` finds them |
| `SupportTicket.with_team(:billing)` | non-enum `chooses` | `where(team: "billing")`; `:typo` raises `KeyError: :typo is not on SupportTicket#team (returns, billing)` — a scale built by the macro is named `Model#field`; one given to it prints its `name:`, else "the scale" |
| `ticket.s1_category(:severity)` | any `chooses` / `scores`, static or dynamic, the enum declared above the macro | the column as a category on the scale — an `S1::Level`, or a Symbol |
| `SupportTicket.s1_scale(:severity)` · `s1_scale_for(:case_type, record)` | any `chooses` / `scores` (a judge raises, as does a `chooses` whose enum is declared below it) | the registry's scale; a dynamic one resolved on the record |

```ruby
SupportTicket.severities                                   # => #<S1::Scale cosmetic < degraded < blocking>   Severity itself
ticket.severity_blocking?                                  # nil → false; "critical" → KeyError
SupportTicket.severity_at_least(:degraded).to_sql          # … WHERE "severity" IN ('degraded', 'blocking')
SupportTicket.priority_at_least(:today).to_sql             # … WHERE "priority" IN (20, 30)   an integer column, by its indexes
SupportTicket.with_team(:billing)                          # a nominal field; SupportTicket.with_team(:typo) raises
ticket.s1_category(:severity)                              # => "degraded", an S1::Level on Severity
ticket.measurement(:severity).level.scale.equal?(Severity) # => true   rehydration keeps the field's Scale when the row was stored over it
```

**The foot-gun this closes** is s1's [Scales: one place for the labels](https://github.com/innocentdiaz/s1_ruby#scales-one-place-for-the-labels):
a label spelled as a bare literal somewhere else — `ticket.severity == "blocking"`, `case …
when "blocking"`, `in { severity: "blocking" }`, `where(severity: "blocking")` — goes silently
false the day the label is renamed at the declaration. So does `ticket.department ==
SupportTicket.departments[:billing]` today: a nominal category is a Symbol and the column holds
the label, so read the column through the scale — `ticket.s1_category(:department)`,
`ticket.department_billing?`, `with_department(:billing)`. Every generated name above is a lookup
through the scale, so the same rename fails at the reference: `SupportTicket.severities.fetch(:blocking)`
raises `KeyError`, `ticket.severity_blocking?` raises `NoMethodError`,
`severity_at_least(:blocking)` raises `KeyError` — and `ticket.severity_blocked?` is there
instead. An enum column keeps Rails' own mapping, predicates and scopes and gets only
`<name>_scale`, plus the rank scopes on a `score_enum`: the predicates and scopes already fail
loud; the mapping's `[]` and `where(col: literal)` do not — reference through
`Model.<col>s.fetch(…)` there, or `<col>_scale.fetch(…)`. `Model.<names>` on a non-enum field is
the `S1::Scale`, not a Rails mapping: Enumerable over its categories, `labels` the Strings,
`keys` the `{ key => label }` Hash, `to_h` the definitions — none of Rails' enum idioms. An
integer column with `indexes:` casts a Level, or a label on the scale, to its index — so
`where(priority: SupportTicket.priorities[:today])` and `update!(priority: …[:today])` land on the
stored integer, and a Level of another scale raises `KeyError` at the read; `ticket.priority ==
SupportTicket.priorities[:today]` is still the position against the integer — read the column
through `s1_category` or `priority_today?`.

A name in use raises at declaration (`:severity's scale would define severities, which would
overwrite SupportTicket's own severities; rename it, or scale_methods: false`); a generated one
redefined below the macro raises at `verify!`; `scale_methods: false` generates none. So does a
predicate spelling an attribute method Rails defines lazily (`severity_index?` beside a
`severity_index` column, `department_changed?`), or another field's predicate. A dynamic
scale generates none either — `S1.scale(-> { … })` and `levels: -> { … }` are the same
declaration — and `s1_plan` says so. Its kind is the macro's: a dynamic Scale that never said
`ordered:` takes it, one that said the other is refused, and a Scale the method returns is held
to it at the call; it resolves with the descriptions the method returned, named `Model#field`.

**Options, and their precedence.** Every macro takes `as:` (a form) · `given:` (a lens — a Proc
`instance_exec`'d on the record, a method name, or a Hash) · `threshold:` (judges only) ·
`provider:` / `model:` · `measure_on:` with `if:` / `unless:` / `on:` ([When](#when-measure_on)) ·
`after:` ([Sequenced fields](#sequenced-fields-after)) · `siblings:` ([Sibling
columns](#sibling-columns)) · `scale_methods: false`. A category or level named like an option goes through
`categories:` / `levels:` — as a keyword it would be taken for the option, so the macro raises
naming that spelling ([Foot-guns](#foot-guns-this-dsl-refuses)). One rule decides who wins, for
the form, the lens, the threshold, the provider and the model alike — **call-site > field >
declared default**:

| | form | lens | threshold | provider / model |
|---|---|---|---|---|
| call-site | `record.as(:planned)` · `as:` on any verb (`judge?(:col, as: :planned)` is `as(:planned).judge?(:col)`), `measure_all`, `update_measure_later` | `given:` on any verb · `record.given(…)` · `Relation.given(…)` · `as(given:)` | `judge?(:col, threshold:)` · `where_judged(:col, threshold:)` · `as(threshold:)` — also `threshold:` on the record's `measure` / `update_measure`, which route through it | `as(provider:, model:)` |
| field | `as: :planned` | `given: :desk` — over the declared lens | `threshold: 0.7` | `provider:` / `model:` |
| declared default | `:default` (`measurable_as`) | `measured_against` | `S1.config.threshold` | `S1.config.provider` and its model |
| sequenced | — | `after: :kind` puts `kind`'s collapse in the lens last, over every spelling; a call or field lens naming `kind:` raises | — | — |

A lens merges: the call's over the field's over `measured_against`. A call-site form replaces
the field's for every field in the call; their lenses stay their own, so the plan may still
split ([the plan](#sharp-knives)).

```ruby
ticket.s1_request(:team).state                              # => { this: { subject:, body:, plan: "gold" }, policy: "30 days", desk: "front" }
ticket.s1_request(:team, given: { policy: "none" }).state   # => { this: { subject:, body:, plan: "gold" }, policy: "none", desk: "front" }
ticket.given(policy: "none").request(:team).state           # same
ticket.as(:default).request(:team).state                    # => { this: { subject:, body: }, policy: "30 days", desk: "front" }
ticket.as(:planned, given: { desk: "back" }).request(:team).state   # => { this: { …, plan: "gold" }, policy: "30 days", desk: "back" }
ticket.judge(:is_lead).threshold                            # => 0.7
ticket.judge?(:is_lead, threshold: 0.9)                     # => false   (at 0.8)
ticket.as(threshold: 0.9).judge(:is_lead).threshold         # => 0.9
```

**A score on an integer column is stored by index — give the indexes.** Positional levels
(`"Cosmetic", "Degraded", "Blocking"`) mean `1` is "Degraded" until the day someone inserts
"Minor" in the middle and every stored `1` silently becomes "Minor" — the same foot-gun as an
array-backed Rails `enum`, and the same remedy: an explicit `{ level => integer }` (or
`indexes:`), which makes adding a level an append and changing one a migration. A bare list on
an integer column is accepted and **warns loudly** at boot; a `string` column stores the label
and has no such problem. Indexes must increase with the levels, so `where(priority: 20..)` keeps
meaning "at least today".

**On demand.** A declaration says how a column is measured, not when; nothing measures until a
verb runs, and a declared column name stands for its question in every verb:

```ruby
ticket.update_measure(:team)                   # measure, collapse into the column, save: true / false; ticket.s1_result
ticket.assign_measure(:team)                 # collapse into the attribute, no save
ticket.update_measure_later(:team)           # enqueue — the column travels by name, builds in the job
SupportTicket.where(team: nil).update_measure_all(:team, concurrency: 5)
ticket.choose(:team)                         # => #<S1::Answer::Choice billing>   the measurement alone, nothing written
ticket.judge?(:is_lead)                      # => true                            the decision, at the field's threshold
ticket.level(:severity)                      # => "degraded"                      the point on the declared scale
ticket.measure(:is_lead, :severity)          # => #<S1::Result …>                 several, one call, nothing written
ticket.measure(:is_lead, :severity).collapse # => { is_lead: true, severity: "degraded" }
ticket.measurement(:team)                    # => #<S1::Answer::Choice billing>   what the column was last written from (s1_answers)
```

### When: measure_on

`measure_on:` puts the verb on the Rails lifecycle, and the lifecycle already decides sync vs
async: a `before_*` hook must produce the value now, an `after_*_commit` hook can enqueue. Three
shapes:

| `measure_on:` | hook | how |
|---|---|---|
| `:validation` | `before_validation` | sync — `assign_measure`; the column exists at insert, validations can read it, the save absorbs the call |
| `:create` / `:save` / `:update` | `after_create_commit` / `after_save_commit` / `after_update_commit` | async — `update_measure_later`; the request returns, the column fills in a moment |
| `:transcript`, `%i[transcript kind]` | `after_save_commit`, when any of them changed in any save of the transaction (a list is a set: either order is one trigger) | async — `measure_on: :transcript` measures as `measure_on: :save, if: :saved_change_to_transcript?` does, and sees more: every save of the transaction, and an attribute a later `before_save` set |
| `-> { … }` | `after_save_commit`, when it is true | async — checked on every save, on the record |
| omitted | — | on demand |

The four lifecycle names are reserved; anything else is an attribute, and one the model does not
have raises at declaration. `if:` / `unless:` compose with every shape; `on:` with `:validation`,
`:save`, an attribute and a Proc (`measure_on: :body, on: :create`) — `:create` / `:update`
already say when, so `on:` beside them raises, and conditions with no `measure_on:` at all raise
rather than sit unread. Fields on the same trigger — the same hook, and the same spelling of its
conditions and watched attributes — go in one job, which runs the plan over them; `measure_on:
:transcript` and `measure_on: :save, if: :saved_change_to_transcript?` measure the same way but
are two triggers, so two jobs, and they differ at the edges: the attribute form watches every
save of the transaction (`s1_changed?(:transcript)` is that test, for an `if:` that must agree),
the `if:` form reads the last save's `saved_changes`. Share the spelling to share the call; a
lambda condition is its own trigger, a method name groups. A save that wrote only what a
measurement writes — the columns, their siblings, `s1_answers` — enqueues nothing, and
`assign_measure` followed by the caller's own `save!` is that write too; a save that also
carried the caller's own changes triggers as any save would, less the fields the measuring save
already wrote from the state it saved (`Ticket.new(body:).update_measure(:is_lead)` enqueues no
second `is_lead`), and a transaction's saves count together whichever came first. A commit whose
saves changed nothing — a `touch`, a child's `belongs_to … touch: true`, a `save!` with no
changes — is not a trigger. A record dirtied after its save is enqueued on the committed row,
and the log names what stayed behind (`update_measure_later` itself raises). A `:validation`
field is skipped only by a save that is a measurement's own write and nothing else's. A
sequenced field joins
its predecessor's trigger — declared after it, with the same `measure_on:` spelling — and its
own `if:` / `unless:` are read when its stage runs, not by the callback (next).

```ruby
class Routing < ApplicationRecord
  include S1::Measurable
  measurable_as { { transcript: transcript } }

  chooses :kind,      "What kind of call, from `transcript`?", **KINDS, measure_on: :transcript
  chooses :case_type, "Which case type, given `kind`?", categories: :case_types, after: :kind, measure_on: :transcript, if: :new_case?
  judges  :urgent,    "Does the caller need a reply today?", measure_on: :save, if: :saved_change_to_transcript?

  def new_case? = kind == "new_case"
end

Routing.create!(transcript: "I was rear-ended on I-95 yesterday")   # two jobs: [kind] → [case_type], and [urgent]
```

### Sequenced fields: after

`after: :kind` puts a field in a later stage: it is measured once `kind` is collapsed, with
`kind`'s collapse in its lens as `{ kind: value }` — so its question can say "given `kind`" —
and its `if:` / `unless:` are read on the record with that collapse in place. The stages run
inside a trigger's job or callback, in `update_measure(:kind, :case_type)`, `measure_all` and
`measure` alike (inside `measure`, provisionally — the record is put back). `after:` takes one
field or a list; a cycle raises at declaration. The collapse in the lens is the one the column
will hold: a judge at its own threshold (the field's, or the call's — the lens and the column
never disagree), a category's text, a level's label — an integer score column relabelled through
its indexes or its positions. A float or decimal column is not a collapse, so its lens is the
stored measurement's (`measurement(:col)`, the audit): a score's argmax; a judge's verdict at
the threshold stamped there, the call's winning — so `measurement(:col).collapse` and the lens
agree whatever the config says now; a field `threshold:` changed since the measure reaches the
row on remeasure, as it does on a boolean column, and `Model.s1_collapsed` reads the same way
(the call's threshold, else the audit's, else the field's — never the config's). Without an
audit row a noul column collapses at the call's or the field's threshold and otherwise raises,
and a score column's read raises (an `ArgumentError`: `not measured; a float or decimal column
keeps the expectation, not the category`) — `after:` such a column needs `s1_answers`, or for a
judge a declared `threshold:` (a stamp by declaration), or `verify!` refuses it. The row must
hold a category on the scale: `nil`, a blank, or a label the scale no longer has raises naming
the remeasure.

Above, `case_type` shares `kind`'s trigger: a sequenced field with `measure_on:` joins its
predecessor's trigger (the same spelling, declared after it — anything else raises at
declaration, so the two are never enqueued apart), and `kind`'s own `if:` gates both. A
sequenced field's `if:` / `unless:` is its **gate** (THEORY.md's plumbing word): read on the
record with the earlier collapses in place, it decides whether to ask, never what — neither a
trigger (a moment), a lens (evidence) nor a definition (meaning). When `new_case?` is false on the
collapsed `kind`, `case_type` is not asked and is absent from the Result (`result[:case_type]`
is a `KeyError`) and nothing is written; a predecessor gated out of a call takes its dependents
with it. The bare verbs (`routing.choose(:case_type)`) ask regardless — a
question asked is a question asked — and read `kind` as the row holds it now; a row that holds
nothing raises naming the spelling that measures both (`measure(:kind, :case_type)`), because
`nil` is not a category to judge against.

```ruby
puts Routing.s1_plan
# Routing.s1_plan — 2 stage(s), 2 call(s)
# stage 1
#   call 1: as: :default  →  kind (measure_on: :transcript), urgent (measure_on: :save)
# stage 2
#   call 1: after: kind  →  case_type (dynamic; measure_on: :transcript)

routing.update!(kind: "new_case")
routing.s1_request(:case_type).state         # => { this: { transcript: "…" }, kind: "new_case" }   the sequenced lens, from the row
routing.s1_request(:kind, :case_type).last.state                    # the same, from stage 1's (Stub) collapse
```

A block's questions are built when the block runs; a field that must see an earlier stage's
collapse goes by column name.

### A dynamic scale

`categories:` / `levels:` as a method name or a Proc (`instance_exec`'d on the record, handed
the record when it takes one) is evaluated at measure time — `chooses :case_type, "Which case
type?", categories: -> { law_firm.case_types }` and `categories: :case_types` are the same
declaration, and send the same Request. It must return at least 2 labels — a list, or `{ label
=> description }` (ordered, for a score) — else a `ValidationError` naming the field. The
registry marks it `dynamic: true`; `verify!` checks what boot can see (the method exists, the
Proc takes the record at most); `s1_plan` prints `(dynamic, no scale methods)`. On an enum column it raises at
declaration (the enum is the scale), a dynamic score on an integer column is refused (the stored
integer would follow position), and so is an `_index` sibling beside one. The measurement
stores the scale it was taken over, so `measurement(:col)` rehydrates over that scale even
after the method's answer moves. A dynamic scale's question is per record, so `stale` for it
runs in Ruby.

```ruby
ticket.update!(team: "billing")
ticket.s1_request(:subtype).questions[:subtype].categories   # => ["overcharge", "missing"]   the scale, from the record
```

### Sibling columns

A column named for a part of the distribution, beside the measured column, is found by name at
declaration and written with the collapse — the distribution kept in the schema, one part per
column, with no declaration:

| column | type | beside a | holds |
|---|---|---|---|
| `<field>_probability` | float / decimal | judges | the mass on true |
| `<field>_expectation` | float / decimal | scores | the expected position |
| `<field>_index` | integer | scores | the level's index (declared indexes honoured); refused beside a dynamic scale |
| `<field>_confidence` | float / decimal | chooses, scores | the provider's confidence |
| `<field>_probabilities` | json / jsonb | any | the whole distribution, keyed by label — a score's by the labels it stores, never by wire position |

Three spellings, one registry key: the convention (`siblings: { probability: :is_lead_probability }`
appears in `s1_fields` unasked), an explicit map (`siblings: { probability: :lead_p }` — over the
convention, the map wins per part), and `siblings: false` to opt out. `verify!` checks the
columns' types, notes in the log every column the convention claimed (`Ticket: :is_lead writes
is_lead_probability (probability)` — an existing column of that name and type is claimed too:
rename it, or `siblings: false`), and a column named for a part the field cannot write
(`is_lead_confidence` beside a judge) or mapped elsewhere raises rather than sit silently
unwritten; `s1_plan` prints the siblings per field. When the schema cannot be read at
declaration (no connection yet), detection waits for `verify!`. A score's `_probabilities`
are keyed by label; an `_index` beside a `score_enum` holds the enum's integer.

```ruby
ticket.update_measure(:is_lead, :team, :severity)
ticket.is_lead, ticket.is_lead_probability           # => true, 0.8
ticket.team, ticket.team_confidence                  # => "billing", 1.0
ticket.severity, ticket.severity_index, ticket.severity_expectation   # => "degraded", 1, 1.0
```

### Rehydration

With a json / jsonb `s1_answers` column, every write keeps the whole measurement beside its
collapse — per field: `kind`, `value` (the collapse as text), a score's `position` (its rank on
the scale; the `_index` sibling holds the declared index, a different number), `probabilities`
(a score's by rank — `"0"`, `"1"`, … in the scale's order, whatever keys the provider's legend
used), `confidence`, `scale` (the labels the question was asked over), a noul's `threshold`,
`question_digest` (SHA-256 of the question as asked — instructions, definitions, the evaluated
scale, a score's stored labels — whichever State asked it: a `Result` from `measure` remembers
its questions; a plain `S1::State`'s Result carries none, so the entry has no digest and the row
reads stale), `form`, `provider`, `model`, `measured_at`. The entry merges over the row's audit
read fresh under a row lock, so two measurements of one row keep both:

```ruby
ticket.s1_answers["is_lead"]
# => { "kind" => "noul", "value" => "true", "probabilities" => { "true" => 0.8, "false" => 0.2 }, "scale" => ["true", "false"],
#      "threshold" => 0.7, "question_digest" => "59391de2…", "form" => "default", "provider" => "stub", "model" => "stub",
#      "measured_at" => "2026-09-21T05:02:20Z" }
```

`record.measurement(:col)` rebuilds the `Answer::Noul` / `Choice` / `Score` over that scale, at
that threshold, with that confidence — nil when never measured, a raise without the column
(nothing was ever stored). The audit keys a score by rank, as every `Score` is (a provider's
legend keys survive only in `raw`), so the rebuilt score reads as the live one did — `key` is
its level's position, `to_s` prints that key before the label, and `level`, `levels`,
`expectation` and `probabilities` are the measurement's — when the entry stored its scale; a
row stored without one keeps the wire keys as its labels. A noul stored before thresholds
were, on a field with none, is stamped with the config's now. A source, not just an audit:

```ruby
ticket.measurement(:is_lead)                 # => #<S1::Answer::Noul 0.8>
ticket.measurement(:is_lead).true?(0.9)      # => false      re-collapsed, without re-asking
ticket.measurement(:is_lead).probabilities   # => { "true" => 0.8, "false" => 0.2 }
ticket.measurement(:severity).level          # => "degraded"
ticket.measurement(:severity).levels.map(&:to_s)   # => ["cosmetic", "degraded", "blocking"]   the stored scale
ticket.measurement(:priority)                # => nil   never measured
```

`Model.stale(:col)` is the rows whose stored digest differs from the question the declaration
asks now — reworded, redefined, rescaled — or that were never measured; in SQL on
PostgreSQL, SQLite and MySQL, in Ruby elsewhere and for a dynamic scale (row by row, and the log
says so). `record.stale?(:col)` is the same for one row; both need the column and raise
without it. `Model.s1_question_digest(:col, record = nil)` is the digest they compare against —
the SHA-256 the declaration asks now (a dynamic scale needs the record, and raises without it).
`Model.stale(:col).update_measure_all(:col)` is the remeasure; `rake s1:remeasure[Model,col]`
(`BATCH=100 CONCURRENCY=1`) does it in batches with progress.

```ruby
SupportTicket.stale(:is_lead).to_sql   # => SELECT … WHERE (json_extract("support_tickets".s1_answers, '$.is_lead.question_digest') IS NOT '59391de2…')
SupportTicket.stale(:is_lead).update_measure_all(:is_lead, concurrency: 5)
# rake s1:remeasure[SupportTicket,is_lead] BATCH=200 CONCURRENCY=5
```

### Many ways, one path

Seven spellings of "measure `team` on this ticket", and every one sends the same Request —
`{ this: { subject:, body:, plan: }, policy:, desk: }`, the declared question and categories,
`owner: ticket, form: :planned` — because every one is the same call, with the naming rule
deciding only what comes back:

| spelling | what comes back |
|---|---|
| `ticket.choose(:team)` — the verb | the distribution, an `Answer::Choice` |
| `ticket.choice(:team)` — the noun | the category, `:billing` |
| `ticket.measure(:team)` · `ticket.measure { \|q\| q.choose :team }` | a `Result`, nothing written |
| `ticket.update_measure(:team)` · `update_measure!` | `true` / `false` as `update` (`!` raises as `update!`); the collapse in the row, the `Result` as `ticket.s1_result` |
| `ticket.assign_measure(:team)` · `update_measure_later(:team)` | the `Result` (also `s1_result`), the collapse in the attribute · the job |
| `SupportTicket.where(…).measure_all(:team)` · `update_measure_all(:team)` | `{ record => Result }` · the same, written |
| `tickets.group_by(&ψ.choice(:team))` | per element, as `Enumerable` would |
| `ticket.s1_request(:team)` | the Request itself, unsent |

A judge has the `?` and the filter beside these — `ticket.judge?(:is_lead)` / `is?(:is_lead)`
(a boolean, at the field's threshold), `where_judged(:is_lead)` / `where_is(:is_lead)` (a
relation), `select(&ψ.judge?(:is_lead))` — each sending `is_lead`'s own Request the same way.

`ticket.s1_request(:team)` is the proof: the Request all seven send, unsent. Inside a block,
`q.choose :team` fills the declared question and categories, `q.choose :team, "Other wording?"`
keeps the categories under other wording, and inline `true:` / categories / levels override the
declaration on `measure` — still through the field's form and lens. A write is the column's:
`update_measure` refuses a distribution over another scale than the declared one (the raise
names both scales and the spelling), and a block's declared score writes its stored labels, not
the descriptions shown. [The spec](spec/s1/fields_spec.rb) asserts the table.

### Sharp knives

Every layer has a way to the object under it, with nothing sent:

- **`record.s1_request(…)`** / `record.as(…).request(…)` — the `S1::Request` the provider would
  receive: `state`, `questions`, `model`, `timeout`, `options` (`owner`, `form`), with every form,
  lens, sequenced collapse and dynamic scale resolved; an Array, in order, when the plan splits.
  No call, no cache read or write, no `ask.s1`. Takes column names or a block, never a bare
  String question (that is for `judge` / `choose` / `score`, and the raise says so; a String
  naming a declared column is that column, alone or in a list). A gated
  field's Request is shown too — the gate decides whether to ask, not what. A dry run across
  stages carries the bare Stub's collapse for the earlier stage (the first category, 0.5, the
  first level); ask for the later field alone to see the row's own (which must hold one).
- **`Model.s1_question_digest(:col, record = nil)`** — the digest `stale` compares against: the
  SHA-256 of the question the declaration asks now; a dynamic scale needs the record and raises without it.
- **`Model.s1_fields`** — the registry, frozen: `name => { kind:, question:, scale:, levels:, indexes:,
  categories:, criteria:, as:, given:, threshold:, provider:, model:, measure_on:, conditions:,
  after:, siblings:, dynamic: }`, absent keys omitted — `kind` by the wire name (`:noul` /
  `:choice` / `:score`), `scale` the field's `S1::Scale` (the very object when one was given),
  `criteria` the texts shown when they differ from the labels.
  `Model.s1_kind(:col)` is the declared kind, or the column's own for an undeclared column.
- **`Model.s1_scale(:col)`** / `Model.s1_scale_for(:col, record)` — the field's `S1::Scale`, the
  second with a dynamic one resolved on the record; `Model.<col>s` / `<col>_scale` are the same
  reader for a static field ([The scale as a value](#the-scale-as-a-value)). A judge has none
  and raises. **`record.s1_category(:col)`** is the column read through it — what the generated
  `<col>_<label>?` predicates read.
- **`Model.s1_plan(*fields, **fixed)`** — the calls the registry implies: `stages` (by `after:`),
  each a list of batches (one call each: fields sharing a form, a lens, a sequence, a provider
  and a model), `size`, `to_s`. `fixed` are call-site settings (`as:`, `provider:`, `model:`;
  anything else raises naming them; a name that is not a measured field raises too). At the
  call, a `given:` that covers every key of a field's lens batches that field with the others.
  The print says what the conventions decided: the sibling columns each field writes, and the
  attributes a model with no default form sends.
- **`record.measurement(:col)`** — the stored distribution, as an `Answer`.
- **`record.as.assign(result)` / `record.as.apply(result)`** — any `S1::Result` whose ids name
  columns, collapsed by column type (assigned, or saved as a measurement's own write): declared
  judges are re-stamped at the field's threshold; `question_digest` comes only from a
  `Measurable::Result` (`Result#asked`), so a foreign Result — another State's, a job payload's
  — leaves the row stale. `update_measure_all` is this per slice.
- **`Result#asked`** — a `measure` on a record returns an `S1::Measurable::Result`: an `S1::Result`
  that also keeps, per id, the question, the form and the stored labels it was asked with, so a
  write from any State audits the question as asked.
- **`S1.on_result { |result, request| … }`** — s1's hook under every completed call; the Railtie
  turns it into the `ask.s1` notification ([Cost and telemetry](#cost-and-telemetry)).

```ruby
puts SupportTicket.s1_plan
# SupportTicket.s1_plan — 2 stage(s), 3 call(s)
# stage 1
#   call 1: as: :default  →  is_lead (writes is_lead_probability), severity (writes severity_expectation, severity_index), priority, grade
#   call 2: as: :planned, given: :desk  →  team (writes team_confidence)
# stage 2
#   call 1: after: team  →  subtype (dynamic)

SupportTicket.s1_fields[:team]
# => { kind: :choice, question: "Which team?", categories: { returns: "Refunds", billing: "Charges, invoices. Not: an insurer asking about a claim" },
#      as: :planned, given: :desk, siblings: { confidence: :team_confidence } }
ticket.s1_request(:is_lead, :team).map { |r| r.questions.keys }   # => [[:is_lead], [:team]]   two calls: team's form and lens differ
ticket.as(:planned).request { |q| q.choose :team, "Other wording?" }.questions[:team].instructions   # => "Other wording?"
```

### Foot-guns this DSL refuses

A silent misread becomes a raise that names the correct spelling. At declaration:

- `chooses :team, "q", :a, :b, threshold: 0.7` — `threshold: is a judge's collapse rule; :team is declared with chooses`
- `judges :is_lead, "q", categories: …` — `judges :is_lead has unknown option(s) [:categories]; it takes true:, false:, as:, given:, threshold:, …`
- `measured_field :s1_answers, "q"` — `cannot tell how to measure :s1_answers (column type :json): declare it with judges, chooses or scores`
- `chooses :team, "q", :a, :b, categories: …` — `give the categories once — bare labels or keywords, or categories:`
- `scores :severity, "q", :a, :b, levels: …` — `give the levels once — positional, levels:, or label => description`
- `scores :rank, "q", { a: 1, b: 2 }, indexes: …` — `{ label => integer } already gives the indexes`; `levels: :lv, indexes: …` — `a dynamic scale takes no indexes`
- `chooses :yesno, "q", true: "…", false: "…"` (or `scores :yesno, "q", :false, :true`) — `chooses :yesno over { true, false } is a dichotomous scale; declare it with judges`
- `scores :rank, "q", :a, :b, indexes: { a: 2, b: 1 }` — `indexes must increase with the levels ["a", "b"]`
- `scores :rank, "q", :a, :b, indexes: { a: 1 }` — `indexes: must give one integer per level ["a", "b"] (got ["a"])`
- `score_enum :grade, "q", poor: "a"` — `score_enum :grade takes label => Integer pairs`
- `given: "policy"` — `given: is a Proc, a method name or a Hash (got "policy")`
- `siblings: :x` — `siblings: is false or { part => column } (got :x)`
- `siblings: { confidence: :is_lead_confidence }` on a judge — `:is_lead has no confidence: it is a noul`
- `measure_on: 3` — `measure_on: is a lifecycle name [:validation, :create, :save, :update], an attribute name (or a list), or a Proc`
- `measure_on: :nope` — `measure_on: :nope is not an attribute of Ticket`
- `after: :subtype` and `after: :team` on each other — `after: cycle :team → :subtype → :team`
- `scores :severity, "q", Team` with `Team` nominal — `scores :severity takes an ordinal scale (got #<S1::Scale returns | billing>)`; a `chooses` with an ordinal one likewise
- `def self.severities = …` then `scores :severity, "q", Severity` — `:severity's scale would define severities, which would overwrite Ticket's own severities; rename it, or scale_methods: false` (the same for `severity_blocking?`, `severity_at_least`, `with_team`)
- `categories: :case_types` on an enum column — `has a dynamic scale on an enum column: the enum is the scale`
- `chooses :team, "q", on: "put on hold", other: "…"` — `on: "put on hold" reads as a label named :on, which collides with the option on:; give the scale with categories: { on: … }`; the same for `if:` / `unless:` and an enum's `values:` / `scopes:` (`given:` / `siblings:` / `after:` are checked for shape first and raise theirs — above)
- `chooses :team, "q", model: "a model issue", returns: "…"` — `model: "a model issue" beside keyword labels is ambiguous — a model or a label?; give the scale with categories: { … }, or model: as a Symbol` (`provider:`, and an enum's `default:` / `prefix:` / `suffix:`, likewise; positional labels are never ambiguous)
- `categories: …, choices: …` — `categories: and choices: are one thing; give it once`; `true: "a", criteria: { true: "b" }` — `criteria: and true:/false: are one thing; give it once`
- `chooses :team, "q", levels: …` — `levels: is a scores' scale; :team is declared with chooses`; `scores :rank, "q", categories: …` — `categories: is a chooses' scale`
- `chooses :team, "q", :only` / `scores :rank, "q", :a, :a` — `a scale is at least 2 distinct labels (got [:only])`
- `scores :rank, "q", { a: 1 }, { b: 2 }` — `levels are positional labels, or one { label => integer / description } Hash`
- `criteria: "x"` on a judge — `criteria: is { true:, false: } (got "x")`; `categories: "a,b"` — `categories: is a Hash, an Array, or a Proc / method name (got "a,b")`
- `judges :is_lead, nil` — `judges :is_lead needs a question — a String, or a structured Hash (got nil)`; a `choice_enum` with no question is an enum with descriptions, not a measured field
- `judges :is_lead, "q", threshold: 90` (or `"0.9"`, `-1`) — `threshold: is a number in 0..1 (got 90)`; the same from `as(threshold: "0.9")`
- `judges :is_lead, "q", criteria: { yes: "a", no: "b" }` — `criteria: noul criteria may only clarify true/false (got ["yes", "no"]); it takes true: / false:`
- `judges :is_lead, "q", if: :never?` — `if: needs measure_on: (a sequenced field's if: / unless: gate its stage; on: rides on a trigger)`
- `measure_on: :create, on: :update` — `measure_on: :create already says when; drop on:`
- `after: :team, measure_on: :body` with `team` on no trigger — `after: :team has no measure_on: trigger to share; declare :team with measure_on: :body first, or drop measure_on: … and measure both with update_measure(:team, :subtype)`; with another spelling — `measure_on: :save differs from :team's measure_on: :body; a sequenced field shares its predecessor's spelling`; with `on:` — `shares its predecessors' trigger [:team]; on: goes on theirs`

At `verify!` — the Railtie runs it at boot when the app eager-loads ([the boot check](#the-boot-check)); keep it green in a spec (`expect { S1::Measurable.verify! }.not_to raise_error`):

- a field that is not a column — `measured field :nope is not a column`
- a kind that does not fit — `:team is measured as noul but its column is string: declare it with chooses or scores`; `:rank is measured as choice but its column is integer: declare it with scores with indexes`
- `chooses :team, "q"` with no enum — `is a chooses with no categories: give them, or declare the enum`
- categories outside the enum — `:team categories ["c"] are not in the enum ["a", "b"]`
- levels on an enum column that are not its keys — `has levels on an enum column that are not its keys: use one or the other (score_enum makes an enum a score; a Scale over the enum's keys is its scale)`
- a dynamic score on an integer column — `the stored integer would follow position`; an `_index` sibling beside a dynamic scale — `would follow position: drop the column or siblings: false`
- `as: :nope` — `is not a declared form (measurable_as)`; `given: :nope` — `names no method` (a json column counts as one); `after: :nope` — `is not a measured field`; `categories: :nope` — `dynamic scale :nope names no method`; `->(a, b) { … }` — `dynamic scale takes the record at most (arity 2)`
- a sequenced field on a trigger its predecessor left (redeclared with another `measure_on:`) — `:subtype is triggered without its predecessors [:team]; a sequenced field shares their trigger`
- `measured_against { { team: … } }` beside `after: :team` — `measured_against :team is a field it comes after: its collapse is that key` (read on a blank record when it can be; else at the call)
- `after: :quality` where `quality` is a score on a float column and there is no `s1_answers` — `a score on a float column keeps the expectation, not the level; add an s1_answers column`
- `provider: :nope` — `:is_lead provider: unknown S1 provider: :nope`
- a generated name redefined below the macro — `severities is a scale's generated method, redefined at app/models/ticket.rb:12`
- two fields mapping one sibling column — `sibling :shared is claimed by both :a and :b`
- a subclass's declarations are verified with its parent's, when its constant names it (an anonymous class is a spec's, verified by the spec)
- a convention-named column the field cannot write — `:is_lead_confidence is named as :is_lead's confidence, but a noul has no confidence; map it, rename it, or opt out with siblings: false`; a sibling of the wrong type — `sibling :severity_index is float; index needs integer`
- positional levels on an integer column or beside an `_index` sibling, a positional-values enum, or a field measured through no declared form (the warning names the attributes sent) — a **warning**, loud, not a raise; the sibling columns claimed by name are a **note** in the log (`Ticket: :is_lead writes is_lead_probability (probability)`)
- a model `verify!` never reached (no eager load) verifies itself once, at its first measurement — the same raises, in development too

At the call:

- `ticket.judge?(:team)` on a chooses — `team is a choice; use choose`
- `ticket.judge(:is_lead, true: "x")` — `a declared column carries its own question; pass options in its declaration`
- `ticket.judge(:is_lead, threshold: 0.9)`, `(ψ ticket).measure(:is_lead, threshold: 0.9)` — `threshold: only applies to a collapse (judge?, is?, same_as?)`; on the record,
  `ticket.measure(:is_lead, threshold: 0.9)` is `ticket.as(threshold: 0.9).measure(:is_lead)` — a call-site threshold, not a raise
- `ticket.judge?(:is_lead, threshold: "0.7")` — `judge?(threshold:): threshold: is a number in 0..1 (got "0.7")`; `is?` and `same_as?` likewise
- `q.judge :priority, "q?"` on a declared score, in a block — `priority is a score; use score`, on `measure`, `update_measure`, `s1_request` and `update_measure_later` alike
- `update_measure { |q| q.score :severity, "q", "x", "y" }` on a field declared over other levels — `:severity is declared over ["cosmetic", "degraded", "blocking"]; a measurement over ["x", "y"] does not collapse into its column — ask it under another id, or reword without a scale (q.score :severity, "…")` (`measure` keeps the distribution)
- `update_measure { |q| q.judge :id, "?" }` (or `updated_at`, `s1_answers`) — `:id is not a column a measurement collapses into`; `q.judge :plan, "?"` on an undeclared string column — `a noul does not collapse into :plan (column type :string); declare it with chooses or scores`
- `Model.s1_plan(:team, given: …)` — `s1_plan takes as:, provider:, model: (got [:given])`; `Model.s1_plan(:nope)` — `s1_plan: [:nope] are not measured fields`
- `Ticket.select(:id, :body).find(id).update_measure(:team)` — `:team is a measured field this record was loaded without (a select?); load the column to write it`
- `q.judge :status, "?"` on an undeclared enum — `a noul does not collapse into :status (an enum); declare it with chooses (or score_enum)` (an enum takes a choice, or a score when its values are integers)
- `q.score(:severity, "q", "x", "y").stores(:severity, %w[a b c])` — `:severity was asked over ["x", "y"] but stores ["a", "b", "c"]; a scale of another size is another question`
- `q.judge :is_lead` in a block, undeclared — `has no declared question for :is_lead (judges / chooses / scores / choice_enum)`
- a dynamic scale returning one label — `dynamic scale returned [:one]; a scale is at least 2 labels — a list, or { label => description }` (a `ValidationError`)
- `Model.stale(:col)` / `record.stale?(:col)` without `s1_answers` — `stale needs an s1_answers column`; on an undeclared column — `is not a measured field`; `record.measurement(:col)` without the column — `measurement needs an s1_answers column`
- `routing.s1_request(:case_type, given: { kind: "existing" })` — `given: :kind is a field :case_type comes after; its collapse is that key — write the column to judge against another`
- `ticket.measure` with nothing — `no questions given`; a column and a block question with one id — `duplicate question id :is_lead`
- `ticket.s1_request("Is it?")` / `ticket.measure("Is it?")` — `a String is a question for judge / choose / score; measure and s1_request take column names or a block (q.judge :id, "Is it?")`
- `routing.choose(:case_type)` with `kind` never written, or `""` — `:kind has not been measured, and :case_type is judged given it; measure both — measure(:kind, :case_type)`; holding a label off the scale — `:kind holds "legacy", which is not on its scale ["new_case", "existing", "other"]; measure it again — update_measure(:kind)`
- an integer score column holding none of its indexes — `:priority holds 15, not one of its indexes [10, 20, 30]`
- `ticket.severity_blocking?` on a row holding `"critical"` — `KeyError: "critical" is not on the scale (cosmetic, degraded, blocking)`; `Ticket.severity_at_least(:typo)` / `with_department(:typo)` — `KeyError: :typo is not on Ticket#department (returns, billing)`; `_at_least` on a float score column — `:quality keeps the expectation on a float column; its level is the audit's`; `Ticket.s1_scale(:escalate)` — `:escalate has no scale (a judge, or an enum declared after it)`
- `given: :policy_lens` returning nil, a String, or pairs — `given: :policy_lens returned nil; a lens is a Hash`; a Proc nested inside a lens — `is not evidence; call it, or put it at the top of a lens` (a Proc at the top is evaluated on the record)
- `ticket.body = "x"; ticket.update_measure_later(:team)` — `unsaved changes to ["body"] would not reach the job; save first, or update_measure`

## choice_enum: an enum that is a choice

An enum that is also a chooses: the question, and a description per category — declared once,
measured anywhere.

A category is stored **by name** — string-backed by default — so inserting one later is safe;
the by-position foot-gun belongs to scores, whose integer *is* the order. Integer-backed enums are
fine when the integers are explicit; only positional ones are the problem — the same distinction
Rails draws between `enum status: { a: 0, b: 1 }` and `enum status: [:a, :b]`.

```ruby
choice_enum :category, "What is it?", personal: "…", other: "…"                                       # string-backed: stored as "personal"
choice_enum :category, "What is it?", values: { personal: 0, other: 1 }, personal: "…", other: "…"   # integer-backed, explicit: stable
choice_enum :category, "What is it?", values: [0, 1], personal: "…", other: "…"                       # positional: warns
```

`chooses :category, "…", umbrella: "…", other: "…"` measures the same way and stores the same
category text; what `choice_enum` adds is Rails' `enum` — `item.umbrella?`, the `Item.umbrella`
scope, `Item.categories`, and a guard against values outside the set. Use `chooses` when the
categories are the model's business, `choice_enum` when they are the app's. It is not folded
into `chooses` because an enum defines methods named after your categories, which a declaration
called "chooses" should not do silently.

```ruby
class Delivery < ApplicationRecord
  include S1::Measurable
  choice_enum :status, "What is the sender reporting?",
              delivered: "Handed over or left somewhere", attempted: "Tried, no one there", undeliverable: "Bad address"
  measurable_as(:sms) { |body:| { message: body } }
end

Delivery.statuses              # => { "delivered" => "delivered", ... }   a normal enum (string-backed; `values:` for integers)
Delivery.choice_enum(:status)  # => { delivered: "Handed over or left somewhere", ... }   the descriptions, by the bare name

delivery.update_measure(:status, as: :sms, body: text)                        # measure the enum's question, write the column
delivery.update_measure(as: :sms, body: text) { |q| q.choose :status }        # same, inside a batch
delivery.choose("What happened?", enum: :status)                              # your question, its categories
```

A `choose` with no categories takes them from the `choice_enum` (or plain `enum`) of the same
name; with no question, `choice_enum`'s — a plain `enum` has none, so it lends its keys only
under a question (`q.choose :note, "Which?"`). `categories:` names them explicitly (`choices:` and
`criteria:`, the wire word, are accepted too — on `choose`, `q.choose` and `chooses` alike), or
they go inline as keywords. `update_measure` / `assign_measure` / `measure` accept an enum name
or a list of them in place of a block. Other keywords (`prefix:`, `suffix:`, `default:`,
`values:`, …) pass through to `enum`; a category named like one of them, or like a macro option,
goes through `categories:` (`choice_enum :bucket, "q", categories: { model: "…", on: "…" }`) — as
a keyword it would be taken for the option, so it raises naming that spelling.

# Measuring

The verbs live on the record and measure through its default form (`as:` picks another).
Nothing is written; what comes back is the **distribution** — a collapsable — exactly as on an
`S1::State`: an `Answer::Noul` / `Choice` / `Score` for one measurement, a `Result` for
`measure { … }`. A verb keeps the distribution; `?`, `collapse` and `!!` collapse it; a `Result`
collapses to a hash and pattern-matches.

```ruby
ticket.judge  "Is the customer asking for a human agent?"   # => #<S1::Answer::Noul 0.7>   the distribution, kept
ticket.noul   "Is the customer asking for a human agent?"   # => the same — noul names the dichotomous distribution
ticket.judge? "Is the customer asking for a human agent?"   # => true                       the decision
ticket.is  "angry"                                          # "Is this angry?" — the phrase completes the question
ticket.is? "angry"
ticket.choose "Which team should handle this?", returns: "Refunds", billing: "Charges"   # => #<S1::Answer::Choice>
ticket.choice "Which team should handle this?", returns: "Refunds", billing: "Charges"   # => :returns
ticket.score  "How severe is the issue?", "Cosmetic", "Degraded", "Blocking"             # => #<S1::Answer::Score>
ticket.level  "How severe is the issue?", "Cosmetic", "Degraded", "Blocking"             # => "Degraded"   an S1::Level
ticket.measure do |q|                                                                    # several, one call, independent
  q.judge  :escalate,   "Is the customer asking for a human agent?"
  q.choose :department, "Which team should handle this?", returns: "Refunds", billing: "Charges"
  q.score  :severity,   "How severe is the issue?", "Cosmetic", "Degraded", "Blocking"
end
```

The rule of thumb, for every verb and its stream twin: does the argument read as a question
("Is the customer angry?") → `judge?` / `where_judged`; as a phrase ("angry") → `is?` /
`where_is`. A declared column name stands for its question in every verb —
`item.choose(:category)`, `item.judge?(:plausible)`, `item.measure(:plausible, :match)` — and
carries that question alone: `given:` and a collapse's `threshold:` ride along, any other option
belongs in the declaration and raises, as does the wrong verb (`item.judge?(:category)` on a
choice column: "category is a choice; use choose"). See
[`judges` / `chooses` / `scores`](#judges--chooses--scores-how-a-column-is-measured).

`given` per call is the lens for one measurement: the default form becomes `this`, the lens
sits beside it, merged over any declared `measured_against`.

```ruby
ticket.given(plan: customer.plan, policy: store.refund_policy).is? "within policy"
ticket.given(plan: customer.plan).judge? "Is `this` covered by `plan`?"
```

# Collapsing

## update_measure: measure, collapse, save

Measure, collapse into the columns, save — and return what ActiveRecord's `update` returns:
`true`, or `false` when the save is invalid. `update_measure!` is `update!`: `true`, or it raises
`ActiveRecord::RecordInvalid`. Aliases `update_judge` / `update_ask` (and `update_judge!` /
`update_ask!`). Question ids that name a column are written, coerced by column type; every
distribution — written or not — stays on the record in memory as `s1_result`, the `Result`
the provider returned: measure speculatively, gate in code. Column names alone measure each
column's declared question (`judges` / `chooses` / `scores` / `choice_enum`):
`ticket.update_measure(:escalate, :department)`.

```ruby
if ticket.update_measure(:escalate, :department)       # => true / false, as update
  ticket.escalate                                     # => true              the collapse, in the row
  ticket.s1_result[:department]                       # => #<S1::Answer::Choice billing>   the distribution behind it
  ticket.s1_result.usage                              # => { input_tokens: 812, output_tokens: 0 }
end
ticket.update_measure!(:escalate)                       # => true, or raises RecordInvalid, as update!
```

The record is the collapse, so the record is what you keep: no wrapper class, nothing that
stops being a `Ticket`. `s1_result` is the last `Result` this instance collapsed — through
`update_measure`, `update_measure!` or `assign_measure` — held in memory only, still set when the save
returned `false` (the provider was called; its answer is not lost), and not cleared by `reload`.
What persists is the optional `s1_answers` json column below, rebuilt per field by
`measurement(:col)`; the bare verbs (`measure`, `judge`, `choose`, …) return their distributions
directly and leave `s1_result` alone.

What the column keeps:

| distribution | boolean | float / decimal | integer | string / enum |
|---|---|---|---|---|
| noul | `true?` at the threshold | the whole distribution (its one number) | — | — |
| choice | — | — | — | the category |
| score | — | the expectation | level index (declared, else its rank) | level text |

The boolean, integer and string columns are collapses; a float or decimal column is not — it keeps
a judge's whole distribution, or a score's expectation, a number that names no level, so a score's
category is read back from the audit. A "—" is a pairing that means nothing, and the write raises
naming the macro to declare the column with (`a noul does not collapse into :n (column type
:integer); declare it with scores with indexes`); for a declared field `S1::Measurable.verify!`
catches the same mismatch at boot.

The save runs validations and callbacks. Sibling columns are written beside the
collapse, and a json/jsonb `s1_answers` column keeps the whole measurement per id — the
distribution, persisted beside its collapse, and rebuilt by `measurement(:col)`
([Rehydration](#rehydration)).

```ruby
ticket.update_measure!(as: :thread) do |q, ticket|                            # the block also receives the record
  q.judge  :escalate,  "Is the customer asking for a human agent?"          # boolean column: written, collapsed
  q.choose :department, "Which team should handle this?", **ticket.store.departments   # string column: written
  q.judge  :prior_contact, "Has the customer contacted support about this before?"     # not a column: s1_result only
end
ticket.escalate                        # => true
ticket.s1_result[:prior_contact]       # => #<S1::Answer::Noul 0.7>   the distribution, still yours to route on
```

## assign_measure: collapse without saving

`update_measure` without the save: the collapse is assigned to the record, the `Result` is its
`s1_result`, and nothing else happens. There is no save to report on, so it returns the `Result`
itself. This is the one to call from inside a save (see [callbacks](#callbacks)). Aliases
`assign_judge`, `assign_ask`.

```ruby
ticket.assign_measure { |q| q.choose :department, "Which team should handle this?", **DEPARTMENTS }
ticket.changed?   # => true
```

## update_measure_later: off the request thread

Same call, enqueued. The block runs now (it can read the record); the measure runs in
`S1::MeasureJob` (alias `S1::AskJob`; a payload enqueued under the earlier name still performs),
which retries `S1::TransientError` with ActiveJob's backoff (five attempts, polynomially
longer). Questions travel as their `to_h` — a declared score's with the labels its column
stores beside it (`stores:`), so the job writes `"degraded"` and not the description shown;
column names travel as names and build in the job, on the reloaded record — `as:`, `given:` and
the form's keyword arguments with them; the lens is evidence, fixed at enqueue, so a Proc at its
top is evaluated on the record here, as on every other path. Alias `update_ask_later`.

```ruby
ticket.update_measure_later(as: :thread) { |q| q.choose :department, "Which team should handle this?", **departments }
ticket.update_measure_later(:escalate, :severity)                             # the columns' own questions, built in the job
```

## Callbacks and validations

**Measure into a column, validate the column.** `measure_on: :validation` fills the column in
`before_validation`; `validates` runs after it. So measure into a column and validate the
column with an ordinary validation — one call, the probability kept, the threshold in Rails'
own words:

```ruby
judges :plausible, "Is `story` a plausible account of losing the `item`?", measure_on: :validation
validates :plausible, numericality: { greater_than: 0.5, message: "doesn't sound like this item" }
```

**`validates … judge:` is for the gate whose measurement you do not want to keep**: no column,
one extra call, nothing stored. A validation that is a question. The state is the model's
default form when it has one, otherwise just the attribute. Nothing is persisted from the
distribution — it only gates.

```ruby
validates :body, judge: "Is `body` a coherent support request?"
validates :body, judge: { with: "Does `body` contain a password, token, or another customer's data?", expect: false },
                 if: :will_save_change_to_body?
```

Options: `with` (the question; `judge: "…"` is shorthand), `expect` (default `true`),
`threshold`, `message`, plus the usual `if:` / `unless:` / `on:`. `noul:` spells the same
validator by the scale's wire name. Each rule is one call, so guard with
`if: :will_save_change_to_…?` when the attribute rarely changes. The validator works on any
`ActiveModel` class; `S1::Measurable` is not required.

# Streams

## A relation: measure, collapse, or filter

Three things can happen to a measurement over a relation, and the verb says which:

| do | verb | record twin |
|---|---|---|
| **measure** — keep the distributions, write nothing | `measure_all(…)` → `{ record => Result }` | `measure` |
| **collapse** — write into the columns | `update_measure_all(…)` → `{ record => Result }` | `update_measure` |
| **filter** — keep the records a judge says yes to | `where_judged(q)` · `where_judged_not(q)` · `where_is(p)` · `where_is_not(p)` · `where_same_as(x)` | `judge?` · `is?` · `same_as?` |

`where_` is reserved for filtering, as in Rails; a choose or a score does not filter — it
buckets or ranks — so those live in `Enumerable` with a predicate: `group_by(&ψ.choice(…))`,
`sort_by(&ψ.score(…))`. `where_same_as` is a judge with a fixed question ("do `this` and `other`
describe the same thing?"), spelled for its most common case. All take `concurrency:` (provider
calls in flight; everything else, the block included, runs on the calling thread and may read
the database) and `as:`; the block also receives the record. `measure_select` / `measure_reject` / `measure_grep` are the
same filters in Enumerable's words, `ask_all` is `measure_all`, `update_ask_all` is
`update_measure_all`.

```ruby
SupportTicket.today.measure_all(:escalate, :severity, concurrency: 8)        # { ticket => Result }, nothing written
SupportTicket.where(department: nil).update_measure_all(:department, concurrency: 5)
SupportTicket.today.where_judged("Does the customer mention a competitor by name?", concurrency: 8)
Item.unclaimed.where_same_as(params[:Body], concurrency: 8)
```

## measure_all: a relation, measured

The relation's `measure`: one call per record, `concurrency` in flight, `{ record => Result }`,
nothing written. Column names measure each column's declared question; a block builds the
questions and receives the record. Alias `ask_all`.

```ruby
SupportTicket.today.measure_all(:escalate, :severity, concurrency: 8)
SupportTicket.today.measure_all(concurrency: 8) { |q, ticket| q.judge :escalate, "Is the customer asking for a human agent?" }
```

## update_measure_all: a relation, collapsed

One `update_measure` per record in a relation, in `find_each` batches. `concurrency` is how
many provider calls are in flight at once, and that is all a thread does: each record's
measurement runs on the calling thread — the block, the forms, the lenses, the gates, the
dynamic scales and the writes read and write the database on its connection — and only the
provider call is handed over, so the block may load associations and the pool needs no sizing.
(The hand-off is a Fiber per record; under `isolation_level = :fiber` each would take its own
connection.) Column names work here as well: `update_measure_all(:department)`. Alias
`update_ask_all`.

```ruby
SupportTicket.where(department: nil).update_measure_all(concurrency: 5) do |q, ticket|
  q.choose :department, "Which team should handle this?", **ticket.store.departments
end
# => { ticket => Result, ... }
```

Written slice by slice: a `find_each` slice of `concurrency` records is measured, then written,
before the next is measured — the first failing call raises, and the slices before it stay
written; `Model.stale(:col).update_measure_all(:col)` picks up where it stopped.

## where_judged / where_is / where_same_as: a relation, filtered

The records in a relation for which a question is true (`where_judged`) or false
(`where_judged_not`). One call per record, `concurrency` at a time. `as:` picks the form;
anything else (`threshold:`, `true:` / `false:` clarification) goes to the judge.
`where_is` / `where_is_not` are the relation's `is?`: the phrase completes "Is this …?"
(`where_is_not("worth keeping")`). Aliases: `measure_select` / `measure_reject` (as Enumerable
would say it), `s1_select` / `s1_reject`.

```ruby
SupportTicket.today.where_judged("Does the customer mention a competitor by name?", concurrency: 8)
SupportTicket.open.where_judged_not("Is this resolved by the last agent message?", as: :thread, threshold: 0.8)
SupportTicket.today.where_is("an angry customer", concurrency: 8)
Claim.where_judged(:plausible, threshold: 0.8)                    # a declared column: each record's own question
```

**The filters return relations** — `where(id: …)` after the judging, the idiom Rails uses when
something outside SQL chose the rows (`elasticsearch-model`'s `.records`, `searchkick`'s
`load: true`) — so `.destroy_all`, `.update_all`, `.count`, further `.where` continue in SQL. Be
clear about what that is not: the *filtering* ran in Ruby, one model call per record, before the
relation existed. Narrow with SQL first and judge the survivors; `concurrency:` on a method is the
tell that it is not a query.

**The lens** for the judge comes per call — `where_judged("…", given: { text: body })` — or as a
scope up the chain: `Item.unclaimed.given(note: policy).where_judged_not("Is `this` worth keeping,
per `note`?")` (alias `against`) — the lens for every judgement down the chain. Backticked names
(`` `this` ``, `` `note` ``) are the path convention for pointing at a field; the model sees the
whole state either way, so use them when a question could be ambiguous, not by rule.

```ruby
Item.unclaimed.given(note: "we keep anything with an owner's name or over £20").where_is_not("worth keeping", concurrency: 8)
SupportTicket.today.given(policy: store.refund_policy).where_is("within policy", concurrency: 8)
```

**`where_same_as(other, concurrency:)`** (alias `measure_grep`) is the relation's `same_as?` /
`===`: the records that describe the same thing as `other`. `grep(ψ other)` is the same test,
one at a time.

```ruby
Item.unclaimed.where_same_as(params[:Body], concurrency: 8)      # which items is this text about?
Item.unclaimed.grep(ψ params[:Body])                              # same, sequential
```

## Predicates over relations

s1's predicates (`ψ.is?`, `ψ.choose`, `ψ.score`, `ψ.judge` — see its *Collections* section)
work on records and relations directly, since a record converts to its default form. A verb in a
boolean slot is always truthy, so `select` / `find` / `count` take the `?` form; `sum` and `sort_by` the verb.
`where_judged` / `where_is` / `update_measure_all` are the same idea with `concurrency:` and
the form choice built in.

```ruby
SupportTicket.today.select(&ψ.is?("an angry customer"))                      # one call per record, sequential
SupportTicket.today.where_judged("Is the customer angry?", concurrency: 8)   # same, 8 in flight
SupportTicket.today.group_by(&ψ.choice("Which team?", enum: :department))    # choice_enum categories and question resolve per record
SupportTicket.today.sum(&ψ.judge("the customer is angry"))                   # expected number of angry tickets, no threshold
SupportTicket.today.max_by(&ψ.score("How urgent?", "can wait", "today", "now"))
```

`given` is the lens: what every judgement down the chain is made against.

```ruby
SupportTicket.today.given(policy: store.refund_policy).where_is("within policy", concurrency: 8)
SupportTicket.today.select(&ψ.is?("within `policy`", given: { policy: store.refund_policy }))  # the predicate form
```

# Assessments

An assessment measures a record against a standard when **the set of questions is built from
data at run time** — which questions, and how many — so they cannot be declared as columns. It
returns a plain value and writes nothing; the caller decides what to save.

## When the questions are data

Most of what makes a judgement look big is already a declaration or a verb:

| Looks like a reason | Already covered by |
|---|---|
| Several questions in one call | `measure { \|q\| … }` batches them |
| One answer decides the next question | `after:` stages a field behind the fields it depends on |
| A scale that depends on the record | A dynamic scale: `categories: :method_name` |
| Answers feeding several places | Any saved column |

What a declaration cannot say: one question per item of a standard whose items are data — a
store's return conditions, a firm's intake checklist, a rubric's criteria — when the count changes
from one account to the next. There is no column to bind each question to, and the answers are
gathered into something else.

| Situation | Use |
|---|---|
| A fixed question whose answer is a column (staging and dynamic scales included) | A declaration: `judges :refund_requested, "Is the customer asking for a refund?"` |
| Filter or batch over many records | A relation verb: `SupportTicket.open.where_is("asking for a refund", concurrency: 8)` |
| A fixed set of questions asked once, answers handled in a few lines | An inline `measure` in the caller |
| **The set of questions is built from data** | **An assessment** |

## An example: refund eligibility

Each store writes its own return policy, per product category — one store's electronics have three
conditions, another's six, and apparel has others again. `is?("within the store's return policy")`
is one judgement: enough to triage a queue. Support needs more: which category the return is about,
which of *that* category's conditions the conversation shows are met, not met, or not yet known —
and to ask the customer for the unknown ones.

```ruby
class Store < ApplicationRecord
  include S1::Measurable

  # return_policy: { "electronics" => ["Returned within 15 days of delivery", "Unopened, or opened and defective",
  #                                    "Order number or receipt provided"], "apparel" => [...] }
  measurable_as { { return_policy: return_policy } }
end

class SupportTicket < ApplicationRecord
  include S1::Measurable

  belongs_to :store
  measurable_as(:conversation) { { subject: subject, messages: messages.map(&:body) } }
end
```

```ruby
# app/assessments/refund_eligibility_assessment.rb
class RefundEligibilityAssessment
  Result = Data.define(:category, :conditions, :eligible, :to_ask)

  VERDICTS = {
    "met" => "The conversation establishes it.",
    "not_met" => "The conversation establishes it is not the case.",
    "unknown" => "The conversation does not say."
  }.freeze

  def self.call(...) = new(...).call

  def initialize(ticket)
    @ticket = ticket
    @policy = ticket.store.return_policy
  end

  def call
    category = state.choice("Which of the store's product categories is this return about?", categories: @policy.keys).to_s
    conditions = @policy.fetch(category)

    # One question per condition of that category; positional ids, since conditions are free text.
    result = state.measure do |q|
      conditions.each_with_index do |condition, n|
        q.choose :"c#{n}", "Does this return satisfy the store's condition \"#{condition}\"?", categories: VERDICTS
      end
    end
    verdicts = conditions.each_with_index.to_h { |condition, n| [condition, result[:"c#{n}"].collapse.to_s] }

    Result.new(
      category: category,
      conditions: verdicts,
      eligible: verdicts.values.all?("met"),
      to_ask: verdicts.filter_map { |condition, verdict| condition if verdict == "unknown" }
    )
  end

  private

  # The conversation (the facts) judged against the store (the lens, through its own form);
  # metadata: labels both calls for the ledger.
  def state = @state ||= @ticket.as(:conversation, metadata: { call_type: "refund_eligibility" }).given(store: @ticket.store)
end
```

```ruby
assessment = RefundEligibilityAssessment.call(ticket)
ticket.update!(return_category: assessment.category, refund_eligible: assessment.eligible)
if assessment.to_ask.any?
  ticket.replies.create!(draft: true, body: "To process your return, could you confirm: #{assessment.to_ask.to_sentence}?")
end
```

Why it is an assessment and not a declaration:

- **The questions are data.** They are the store's conditions for the category Jev picked — three
  here, six at the next store, different after tomorrow's policy edit. No column per condition.
- **The first answer decides the second question set.** The category chooses which conditions exist.
- **The answers become a value.** Eligibility, a saved category, and a drafted reply built from the
  unknowns — the caller composes them; the assessment writes nothing.

## Generating one

```bash
bin/rails generate s1:assessment refund_eligibility
#   create  app/assessments/refund_eligibility_assessment.rb
#   create  spec/assessments/refund_eligibility_assessment_spec.rb   (test/assessments/…_test.rb without spec/)

bin/rails generate s1:assessment billing/refund_eligibility
#   create  app/assessments/billing/refund_eligibility_assessment.rb  → Billing::RefundEligibilityAssessment
```

`app/assessments` is autoloaded like any `app/*` directory — Rails picks up a new one at boot, so
restart the server after the first — and the class is named for what it assesses with the
`Assessment` suffix, as jobs and mailers are.

The skeleton has a `Result`, a three-way `VERDICTS` scale (yes / no / unknown), positional
question ids, a `question(item)` to reword, and a `state` labelled with the name you gave —
`metadata: { call_type: "refund_eligibility" }`, or `"billing/refund_eligibility"` when
namespaced. Its `standard` raises `NotImplementedError` until you return the items to judge, and
the spec (or test) is a commented example to fill in with a record and its standard.

## Rules

- **Facts in a form, the standard in the lens.** The evidence about the record goes in a
  `measurable_as` form; what it is judged against goes in `given(…)` — ideally a record, so it
  renders through its own `measurable_as` rather than as raw JSON.
- **Positional question ids** (`c0`, `c1`…), mapped back by position: a standard's own ids are
  rarely guaranteed present or unique, and a duplicate question id raises `S1::ValidationError`.
- **Label every call** with `metadata: { call_type: … }` on the state, so the `ask.s1` subscriber
  can say which assessment spent what ([Cost and telemetry](#cost-and-telemetry)).
- **Return, don't save.** The caller decides which values win over other sources and where they go.
- **Retry what can change.** `S1::TransientError` (timeouts, rate limits) and `S1::ValidationError`
  (a missing or malformed answer) are worth retrying in the caller's job; any other
  `S1::PermanentError` (a bad API key) should fail loudly.

# Plumbing

## Caching

With `c.cache = Rails.cache`, distributions on a record are keyed by its `cache_key_with_version`,
form, form arguments, the form's rendering (a form whose code changed is a different
measurement), lens, questions, and who answers (the provider by name or class, and the model —
the State's (`record.as(provider: …, model: …)`), else the named provider's configured one): an
unchanged record never measures twice, and a write (including `update_measure`) invalidates by
bumping `updated_at`. A cached `Result` has its nouls re-stamped with the measuring State's
threshold — else the field's, else the config's at serve time — so it collapses as the fresh
call would have, not at the first caller's threshold. New and dirty records bypass
the cache — dirty as the caller left it: the provisional assignment between stages does not
count, so a later stage is cached like the first. A nested record changing does not bump the
key — `touch: true` the association if its changes should count.

## Cost and telemetry

Every completed call emits an `ask.s1` notification. `request.options[:owner]` is the record,
`request.options[:form]` the form it was measured through, and `request.metadata` the labels
the caller put on it (`{}` when none).

### metadata: why the call was made

A form says what the record looks like, not why it was asked — `:transcription` is measured by
routing, by a coach and by a nightly backfill alike. `metadata:` is the caller's label for the
call: a Hash that rides on the Request for your ledger, logs and traces, and is never sent to the
model, never shown in the prompt, and never part of the cache key.

```ruby
# a record's State, a lens, a verb — all carry it
call.as(:transcription, metadata: { call_type: "pre_score" }).given(policy: firm.policy).measure { |q| ... }
call.judge?("Did the caller sign a retainer?", metadata: { call_type: "signed_check" })
call.update_measure(:customer_interaction_kind, metadata: { call_type: "routing" })

# a relation labels every record's call
PhoneCall.today.where_is("a viable new case", concurrency: 8, metadata: { call_type: "search", chat_id: chat.id })
PhoneCall.stale(:is_lead).update_measure_all(:is_lead, metadata: { call_type: "backfill" })

# in the background — update_measure_later carries it into S1::MeasureJob
call.update_measure_later(:is_lead, metadata: { call_type: "backfill", batch: 12 })

# declared on a field: every trigger, update_measure and job for that column carries it
class PhoneCall < ApplicationRecord
  choice_enum :customer_interaction_kind, "What kind of call?", new_case_intake: "…", existing_matter: "…",
              measure_on: :transcription, metadata: { call_type: "routing" }
end
```

**Merging.** A field's `metadata:` is the base; the call's (`as(metadata:)`, `.with(metadata:)`,
a verb's `metadata:`) merges over it, the narrowest winning key by key:

```ruby
call.measure(:customer_interaction_kind, metadata: { batch: 12 })
# request.metadata # => { call_type: "routing", batch: 12 }
```

**One request, one set of labels.** Declared fields with different `metadata:` never share a
call — `s1_plan` splits them, as it splits fields with different forms or providers, and prints
each call's `metadata:`.

**JSON's values only.** Strings, symbols, numbers, booleans, nil, and arrays or hashes of them,
keys symbolized — checked when set (a record in `metadata:` raises at once), because it travels
through ActiveJob and into logs. Put the record in `owner`, not in `metadata`.

### A cost ledger

One subscriber records every call — foreground, relation, trigger, job — under the reason its
caller gave:

```ruby
# config/initializers/s1.rb
ActiveSupport::Notifications.subscribe("ask.s1") do |event|
  result, request = event.payload.values_at(:result, :request)
  owner = request.options[:owner]

  AiCosts.create!(
    request_name: request.metadata[:call_type] || "unlabelled",
    owner: owner,                                   # the record measured (polymorphic)
    form: request.options[:form],
    model: result.model,
    input_tokens: result.input_tokens,
    output_tokens: result.output_tokens,
    duration_ms: result.duration_ms,
    metadata: request.metadata                      # the rest of the labels, e.g. chat_id, batch
  )
end

AiCosts.where(request_name: "routing").sum(:input_tokens)
AiCosts.where(created_at: Date.current.all_day).group(:request_name).sum(:input_tokens)
```

A cached result makes no provider call, so it emits nothing and costs nothing — the ledger sees
only calls that were paid for. Keep the subscriber cheap and never let it raise: it runs on the
thread that made the provider call, after the answer is back — for a relation with
`concurrency:`, one of its worker threads, so a subscriber that writes takes a connection from
the pool (size it for the concurrency you use).

## Testing

Point the provider at the Stub from s1; a declared column's verb (`ticket.judge(:escalate)`,
`ticket.choose(:department)`) and a batch are keyed by the column name — the question's id;
a String question's single call by the scale kind's wire name (`noul` / `choice` / `score`).
`update_measure_later` goes through ActiveJob, so `perform_enqueued_jobs` runs it under the
test adapter.

```ruby
S1.config.provider = S1::Providers::Stub.new(escalate: 0.9, department: :billing)      # declared columns, alone or in a batch
S1.config.provider = S1::Providers::Stub.new(noul: 0.9, choice: :billing, score: 2)     # single String questions
S1.config.provider = S1::Providers::Stub.new { |req| { escalate: req.state[:body].include?("supervisor") ? 0.95 : 0.1 } }
```

## The boot check

The Railtie runs `S1::Measurable.verify!` after initialize when the app eager-loads
(production): every declared field against the schema — each check and its raise is under
[Foot-guns this DSL refuses](#foot-guns-this-dsl-refuses). Where the app does not eager-load, the spec there keeps it green.

## Explicit vs on the record

Every form has an explicit spelling in s1; the Rails one is the same call with the plumbing
removed. `t` is a `SupportTicket`; `DEPTS` is `{ returns: "…", billing: "…" }`.

| you want | explicit | on the record |
|---|---|---|
| a yes/no about a record | `S1::State.new({ subject: t.subject, body: t.body }).judge?("Is the customer angry?")` | `ticket.judge? "Is the customer angry?"` · `ticket.is? "angry"` · `(ψ ticket).is? "angry"` |
| the distribution | `S1::State.new({ subject: t.subject, body: t.body }).judge("…")` | `ticket.judge "…"` · `ticket.noul "…"` · `ticket.is "angry"` |
| one of a set | `S1::State.new({ … }).choose("Which team?", **DEPTS)` | `ticket.choose "Which team?", **DEPTS` · `delivery.choose "What happened?", enum: :status` |
| the category alone | `S1::State.new({ … }).choose("Which team?", **DEPTS).to_sym` | `ticket.choice "Which team?", **DEPTS` |
| several at once | `S1::State.new({ … }).measure { \|q\| … }` | `ticket.measure { \|q\| … }` |
| the collapse in the row | `t.update!(department: S1::State.new({ … }).choose("Which team?", **DEPTS).to_s)` | `ticket.update_measure(:department)` |
| the collapse in the row, inside a save | `before_validation { self.department = S1::State.new({ … }).choose(…).to_s }` | `before_validation { assign_measure(:department) }` · `chooses :department, "…", **DEPTS, measure_on: :validation` |
| the collapse in the row, later | a job class that rebuilds the state and the questions | `ticket.update_measure_later { \|q\| q.choose :department }` |
| a column's question, once | the string, wherever it is asked | `judges :escalate, "…"` · `choice_enum :department, "…", **DEPTS` |
| filter a relation | `tickets.select { \|t\| S1::State.new({ … }).judge?("…") }` | `SupportTicket.today.where_judged("…", concurrency: 8)` · `SupportTicket.today.select(&ψ.is?("…"))` |
| bucket a relation | `tickets.group_by { \|t\| S1::State.new({ … }).choose("…", **DEPTS).to_sym }` | `SupportTicket.today.group_by(&ψ.choice("…", enum: :department))` |
| measure a relation, write nothing | `tickets.to_h { \|t\| [t, S1::State.new({ … }).measure { \|q\| … }] }` | `SupportTicket.today.measure_all(:escalate, concurrency: 8)` |
| backfill a column | `tickets.each { \|t\| t.update!(department: …) }` | `SupportTicket.where(department: nil).update_measure_all(:department, concurrency: 5)` |
| against a preference | `S1::State.new({ this: { … }, policy: p }).judge?("… per \`policy\`")` | `ticket.given(policy: p).is? "… per \`policy\`"` · `Ticket.open.given(policy: p).where_is("…")` · `measured_against { { policy: … } }` |
| the same thing? | `S1::State.new({ this: a.attributes, other: b.attributes }).judge?("Do \`this\` and \`other\` describe the same thing?")` | `candidates.any?(ψ vendor)` · `case other when (ψ vendor)` · `Vendor.where(…).where_same_as(vendor)` |
| gate a save | `validate { errors.add(:body, :invalid) unless S1::State.new({ body: body }).judge?("…") }` | `validates :body, judge: "…"` |
| keep the measurement | write `probabilities` somewhere yourself | a `float` column, or an `s1_answers` json column |

## Dictionary and aliases

s1's dictionary (THEORY.md) is the vocabulary; each term below is one of its positions or
arrows, as Rails spells it. Aliases are the earlier spellings, kept as plain Ruby `alias`es.

| term | in s1 | in Rails | also |
|---|---|---|---|
| **evidence** | the particular, before any presentation | the record | — |
| **state** | the evidence as rendered for judgement, fixed once, with its lens attached | the record through a form: `record.as_measurable` is an `S1::Measurable::State` (an `S1::State` that knows its record); `(ψ record)`, `S1.to_state(record)` and every predicate reach it | `as`; `S1::Measurable::Subject`; `rendered` (`state`) |
| **rendering** | the function from evidence to state | a **form**: `measurable_as(:name) { … }`; `:default` when unnamed — with none declared, the attributes less the key, the timestamps, `s1_answers` and the measured columns with their siblings (`Model.s1_omitted`); nested `Measurable` records render through their own default form, any other record as its `attributes`; `record.s1_facts(:name)` is the rendering alone | `s1_state` (the macro, and the old name of `s1_facts`) |
| **lens** | evidence added beside the state to judge against; the state becomes `{ this: facts, **lens }` | `measured_against { … }` declared; `given:` / `.given(…)` per call, merged over it; on a relation, `given(…)` is a scope carrying it down the chain | `measured_given`; `against` |
| **question** | a concept on a scale | declared beside the column by scale kind: `judges` / `chooses` / `scores` (`measured_field` resolves the kind from the shape and the column), `choice_enum` and `score_enum` (a real `enum` that is also the question); `Model.s1_fields` is the frozen registry, `Model.s1_plan` the calls it implies, `record.s1_request` the Request it sends | `noul_field`, `choice_field`, `score_field`; `s1_field`, `measured_attribute`, `measurable_field`; `s1_enum`, `measured_enum`; `measured_score_enum`; `enum: :name` borrows the categories |
| **scale** | the finite set of categories: dichotomous, nominal, ordinal — a value a category is a point on | the column type or the enum; `s1_kind` names it by the wire name (`:noul` / `:choice` / `:score`); a `chooses` / `scores` field's `S1::Scale` is `Model.<field>s` / `<field>_scale` (`s1_scale`), given to the macro or built from the inline labels; it generates `record.<field>_<key>?` (by `Scale#keys`, the snake-cased label), `<field>_at_least` and kin, `with_<field>` | `scale_methods: false` |
| **definition** | the working definition of the scale; *criteria* is the wire word | `true:` / `false:` on a judge; `label: "…"` or `label: { is:, not: }` (or `categories:`) on a choose; the levels on a score — `label: "description"` shows the description and stores the label, `{ level => integer }` or `indexes:` on an integer column; a Scale's own `definitions` | `choices:` on `chooses` / `choose` / `q.choose`; `criteria:` on those and on `scores` / `q.score` (as `levels:`, never the declaration's) |
| **measure** | the act: judgement, by scale kind | `judge`, `choose`, `score` on the record (one question each); `measure` (several at once); a declared column name stands for its question in every verb | `noul` (the noun for the judge's distribution); `ask`, `batch`, `ask_about` |
| **distribution** | the product of a judgement: mass over every category | what a verb returns: `Answer::Noul` / `Choice` / `Score`, a `Result` for `measure`; kept whole in an `s1_answers` json column (a `float` column keeps a noul whole — its one number — and a score's expectation only) | `S1::Distribution` (`Answer::Base`); `Result#distributions` (`answers`) |
| **collapse** | the decision rule: distribution → category | `?` on the record (`judge?`, `is?`, `same_as?`), the nouns `choice` / `level`, and the column type on a write — boolean at the threshold, integer the level's index (its rank when none is declared), string or enum the category; a float or decimal column is not a collapse (it keeps a judge's whole distribution or a score's expectation); a declared column name is its own question under every one of them (`is?(:is_lead)`, `where_is(:is_lead)`) | `noul?`, `ask?` |
| **category** | one point on the scale | a boolean, a Symbol, an `S1::Level`; what a boolean, enum or integer column stores; `record.s1_category(:col)` reads a column back as one, and `Model.<col>_scale[:label]` / `.fetch` name one — a rename fails there, where a literal goes silently false. A nominal category is a Symbol and a string column holds the label, so `record.col == Model.cols[:x]` is always false: compare through `s1_category`, `<col>_<key>?` or `with_<col>` | — |
| **threshold** | the dichotomous decision rule's parameter | `S1.config.threshold`; `judges :col, "…", threshold:` on the field; `as(threshold:)`; `judge?("…", threshold:)` — call > field > config; a noul carries the one it was measured under; a cached `Result` is re-stamped at serve time (the State's, else the field's, else the config's then) | — |
| **predicate** | a question not yet applied to a state | `ψ.is?`, `ψ.choose`, `ψ.score`, `ψ.judge`, with `as:` for the form and `given:` for the lens; works on records and relations through `to_s1` | `S1.predicates` |
| **stream** | many particulars under one question | a relation: `measure_all` (`{ record => Result }`, nothing written), `update_measure_all` (collapsed into the columns), `where_judged` / `where_judged_not` / `where_is` / `where_is_not` / `where_same_as` (filtered; relations back) | `ask_all`; `update_ask_all`; `measure_select` / `s1_select`, `measure_reject` / `s1_reject`, `measure_grep` |
| **update_measure** | collapse as a write | measure, collapse column-named distributions into the row, save; returns `true` / `false` as `update` (`update_measure!` raises as `update!`), the `Result` kept as `record.s1_result`; `assign_measure` the same without the save; `update_measure_later` the same enqueued in `S1::MeasureJob` (which uses the bang); `measure_on:` puts one on the lifecycle | `update_judge`, `update_ask` (and `!`); `assign_judge`, `assign_ask`; `update_judge_later`, `update_ask_later`; `update_judge_all`, `update_ask_all`; `S1::AskJob` |
| **judge:** | a judgement that gates a save | `validates :attr, judge: "…"` — `with:` / `expect:` / `threshold:` / `message:`; nothing stored | `noul:` (`NoulValidator` is `JudgeValidator`) |
| **s1_answers** | the distribution, persisted beside its collapse | optional json column: per id, `kind`, `value`, `position` (a score's rank), `probabilities`, `confidence`, `scale`, `threshold` (a noul's), `question_digest`, `form`, `provider`, `model`, `measured_at`; `measurement(:col)` rebuilds it, `Model.stale(:col)` reads the digest | — |
| **provider** | an implementation of measure that honours calibration | `S1.config.provider`; the Stub in tests; every completed call emits the `ask.s1` notification (`result`, `request`; `request.options[:owner]` is the record) | `S1.on_result` in s1 |
| **noul** | the wire name for the dichotomous scale — and the proper name of its distribution | `record.noul("…")` is `record.judge("…")`; `s1_kind` says `:noul`; the Stub's key for a single String question (a declared column is keyed by its name) | — |
| **cache** | — | `c.cache = Rails.cache`: distributions keyed by record version, form, arguments, lens, questions and who answers | — |

Aliases are plain Ruby `alias`es, so a class's own method with the same name always wins.

# Usage scenarios

Each is free text (or two records) in, a boolean or enum out, inside a request or a save —
where a regex can't and a text-generating model is the wrong tool. Where a String or Hash is
the receiver, `c.primitives = true` (s1's core extension) is on.

## Models

### Checking another model's output

An LLM extracts an order number and drafts a refund recommendation from an email. Asking the
same model whether it did well is grading its own work; S1 is a different model answering a
narrow question.

```ruby
class RefundRequest < ApplicationRecord
  include S1::Measurable
  measurable_as(:grounding) { { email: email_body, order_number: order_number, recommendation: recommendation, approve: approve } }

  validate do
    g = as_measurable(:grounding).measure do |q|
      q.judge :order_in_email,  "Does `order_number` appear in `email`?"
      q.judge :reason_supports, "Does `recommendation` justify `approve` being true?"
    end
    errors.add(:order_number,   :not_in_source)  unless g.true?(:order_in_email)
    errors.add(:recommendation, :does_not_support) if approve && !g.true?(:reason_supports)
  end
end
```

### Uniqueness that `uniqueness: true` can't see

"Acme Inc" and "ACME, Incorporated" are one vendor; a regex compares strings, `===` compares
what they describe. Narrow with SQL, then measure the survivors (one call each).

```ruby
validate do
  candidates = Vendor.where(account: account).where("similarity(name, ?) > 0.3", name)
  errors.add(:base, :duplicate) if candidates.any?(ψ self)      # State#=== is same_as?
end
```

### Prose configuration that has to be coherent

A store owner writes the return policy customers read; the checkout enforces an integer. The
prose says "two weeks", "a fortnight", "within the month", or nothing about time at all, and
may say two things ("30 days, 60 for members") — there is no number to parse out and compare.
The check is whether the two agree, not what the number is.

```ruby
class Store < ApplicationRecord
  # refund_policy:      "Returns accepted within two weeks of delivery; final-sale items excluded."  (textarea, shown to customers)
  # return_window_days: 30                                                                            (integer, enforced at checkout)
  validate do
    errors.add(:refund_policy, "promises a different return window than #{return_window_days} days") if
      { policy: refund_policy, window_days: return_window_days }
        .judge?("Does `policy` state a return window other than `window_days` days?")
  end
end
```

### Content that must never be saved

The distribution isn't data to keep; it's a gate. A failing `judge:` leaves the record unsaved
and the user sees a normal validation error.

```ruby
class Reply < ApplicationRecord
  validates :body, judge: { with: "Does `body` contain a password, token, or another customer's data?", expect: false },
                   if: :will_save_change_to_body?
end
```

## Callbacks

### Enriching on save

Sync in `before_validation` / `before_save` when the columns must exist at insert and the save
can absorb ~400ms; async via `after_commit` + `update_measure_later` when it can't.
`measure_on:` is the declared spelling of both.

```ruby
class SupportTicket < ApplicationRecord
  before_validation -> { assign_measure { |q| q.choose :department, "Which team should handle this?", **DEPARTMENTS } },
                    if: :will_save_change_to_body?
  validates :department, presence: true

  after_create_commit { update_measure_later(as: :thread) { |q| q.score :severity, "How severe is the issue?", "Cosmetic", "Degraded", "Blocking" } }
end
```

### Re-measuring on every event

State changes per message; S1 is cheap enough to measure again each time, and the collapse
lands in a column the UI already renders.

```ruby
class Message < ApplicationRecord
  belongs_to :ticket, touch: true
  after_create_commit { ticket.update_measure(as: :thread) { |q| q.judge :escalate, "Is the customer asking for a human agent?" } }
end
```

## Controllers and webhooks

### Free-text replies that must become state

A courier texts back "left with neighbour" / "nobody home, tried twice" / "address doesn't
exist".

```ruby
def create   # inbound SMS webhook
  delivery.update!(status: params[:Body].choice("What is the sender reporting?",
    delivered: "Handed over or left somewhere", attempted: "Tried, no one there", undeliverable: "Bad address"))
end
```

Or keep the categories with the column, via `choice_enum`:

```ruby
class Delivery < ApplicationRecord
  include S1::Measurable
  choice_enum :status, "What is the sender reporting?",
              delivered: "Handed over or left somewhere", attempted: "Tried, no one there", undeliverable: "Bad address"
  measurable_as(:sms) { |body:| { message: body } }
end

def create
  delivery.update_measure(:status, as: :sms, body: params[:Body])
end

# or, when the state isn't the record:
delivery.update!(status: params[:Body].choice("What is the sender reporting?", **Delivery.s1_enum(:status)))
```

### Intent dispatch

One endpoint for replies of any kind; `choice` decides the action.

```ruby
def create
  case params[:body].choice("What does the sender want?",
                            cancel: "Cancel or stop", reschedule: "Change a time", question: "Asks something else")
  when :cancel     then appointment.cancel!
  when :reschedule then redirect_to new_reschedule_path(appointment)
  else                  Inbox.hold(params[:body])
  end
end
```

### Routing by confidence

A choice or score carries `confident?(at)` — the provider's confidence, at least `at`. A noul
has no separate confidence: `confident?(margin)` (alias `decided?`) is at least `margin` from
the threshold on either side, the complement of `undecided?(margin)`. The convention at the
edge: act when confident, hand off when not — collapse late.

```ruby
team = ticket.choose("Which team?", **departments)
team.confident?(0.8) ? ticket.assign!(team.to_sym) : ticket.hold_for_triage!
lead = ticket.judge("Is this a lead?")
lead.decided?(0.2) ? ticket.update!(is_lead: lead.true?) : ticket.hold_for_triage!
```

### Locale from content

`Accept-Language` describes the browser, not the message.

```ruby
around_action do |_, action|
  I18n.with_locale(params[:message].choice("Which language is this written in?", en: "English", es: "Spanish"), &action)
end
```

## Mail

### Routing inbound mail by content

`ActionMailbox` routes on headers; a lambda can route on what the mail says. Then drop
auto-replies before they open tickets.

```ruby
class ApplicationMailbox < ActionMailbox::Base
  routing ->(inbound) { inbound.mail.decoded.judge?("Is this a refund or return request?") } => :refunds
  routing :all => :support
end

class SupportMailbox < ApplicationMailbox
  before_processing { bounced! if mail.decoded.judge?("Is this an automated or out-of-office reply?") }
end
```

### Guarding outbound mail

For mail assembled from templates, with no record to validate:

```ruby
class OutboundGuard
  def self.delivering_email(mail)
    mail.perform_deliveries = false if mail.body.decoded.judge?("Does this message contain a password, token, or another customer's data?")
  end
end
ActionMailer::Base.register_interceptor(OutboundGuard)
```

## Batch and console

### Backfilling a column

```ruby
SupportTicket.where(department: nil).update_measure_all(concurrency: 5) do |q, ticket|
  q.choose :department, "Which team should handle this?", **ticket.store.departments
end
SupportTicket.where(department: nil).update_measure_all(:department, concurrency: 5)   # the column's own question
SupportTicket.stale(:department).update_measure_all(:department, concurrency: 5)       # rows measured under an older question
# rake s1:remeasure[SupportTicket,department] BATCH=200 CONCURRENCY=5                  # the same, in batches, with progress
```

### Ad-hoc triage

```ruby
SupportTicket.today.where_judged("Does the customer mention a competitor by name?", concurrency: 8)
SupportTicket.today.sum(&ψ.judge("the customer is threatening a chargeback"))   # expected count, nothing collapsed

SupportTicket.last.as_measurable(:thread).judge? "Is the customer threatening a chargeback?"   # console
```

## Development

`bin/setup`, then `bundle exec rake` (specs on in-memory SQLite + rubocop). The Gemfile points
`s1` at `../typesafe-ruby`.

## License

MIT.
