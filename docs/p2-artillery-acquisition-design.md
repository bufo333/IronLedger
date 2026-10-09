# Artillery acquisition and attachment

Each formation owns one Mobile Long Tom carrier from the P2e catalogue, with a
permanent formation ID and physical HullInstance ID. Its explicit artillery
catalogue discriminator excludes it from ordinary Unit, crew, readiness, repair,
supply, roster and combat paths. Sold formations and hull provenance remain history.

These are project game abstractions, not external formation or logistics facts:
regional and brigade HQs receive one player-only offer per calendar month;
unsold stock never accumulates and consumed stock stays consumed until rollover.
The price is the catalogue's calculated construction cost. Commander founding
prepares the starting eligible HQ board atomically; the daily acquisition and
markets phase synchronizes newly founded or promoted eligible HQs and rollover.
Those later HQs receive their first offer during that phase. Legacy campaigns
initialize current-month boards through the explicit schema upgrade. Stable HQ ID order governs offer allocation,
and the board consumes no random stream.

An unattached carrier occupies an HQ pool. A combat company can attach at most
one formation, only while physically home at the same HQ. Detaching returns it
to that home pool. Attached location follows the company's authoritative posture;
there is no second persisted planet or company ETA. Company disband or changing
its home HQ requires detachment and explicit freight. Supplier changes do not
move a physical carrier. No placement grants a battle or support benefit.

HQ freight uses the catalogue's 75-ton mass, the existing route, weekly throughput,
source-HQ transport staff discount, cost and transit owners. Payment and route
reservation commit together with a disjoint transit placement; arrival logs are
prepared before delivery. Attached carriers add one vehicle bay to shared company
lift demand, including outward travel, redeployment and return. This bay equivalence
is a game abstraction, not a sourced tractor or vehicle-bay specification.
Own lift covers only matching vehicle bays; demand without those bays uses the
existing charter policy. The current stock ship catalogue has no vehicle bays.

Every player carrier incurs the existing active vehicle monthly carrying cost,
including transit. The existing outfit-wide monthly posting and contract operating
cost owner consume that total. Intact baseline-C resale uses the shared hull resale
owner, and contributes once to liquidation-backed credit. Sale is only from an HQ
pool, credits that HQ, closes player provenance and opens market provenance.
The acquisition boundary grants no crew or ammunition and adds no operating
charge. [Artillery operations](p2-artillery-operations-design.md) owns individual
crew, local service, magazines and repairs; cold storage remains unavailable.
Queued or active depot jobs block attachment, detachment, freight and sale.
Attachment clears the pool mechanic, detachment clears crew and mechanic, and
freight clears the mechanic; people remain on their existing books. Condition
and magazines travel with the carrier and remain in sold history. Sale uses
actual quality and armor, capped at the named chassis-damage valuation limit
when structure is non-intact, without extracting ammunition or creating stock.

Ownership intervals use nullable closing days: null means open; zero is a real
closed day. Schema 59 to 60 preserves nonzero closing days, closes legacy zero rows
at the successor interval's start, and leaves final zero rows open. Invalid ordered
history is rejected. Explicit acquisition reasons preserve conventional salvage
behavior and record artillery disposal as transfer.

All formation and offer records, acquisition facts, placement payloads and counters
are persisted. Catalogue facts and attached physical position are derived; quotes
and preparation records are operation-local scratch. P2g owns operational fields;
P2h owns artillery battle effects; P2i owns artillery query and textual/UI actions.

HQ sale preserves permanent historical identity in a separate `retired_hqs`
archive: original typed HQ ID, exact name, planet, tier and sale day (including
zero). Active and retired IDs are disjoint and never reused. The archive has no
funds, stock, facilities, projects or board. Operational services, upkeep,
liquidation, capacity, influence and site choices consume live HQs only.

Ledger and event-log HQ tags, retained contracts' board provenance, and terminal
part-order destinations resolve to exactly one live or retired identity. Sale
cancels inbound orders, removes unaccepted contract offers and other live boards,
unposts people, restores removed bay-job unit statuses, removes links/policies,
redirects fund couriers to the outfit, and moves transport berths to the surviving
seat. Remaining force supply assignments, pooled artillery and either live
artillery freight endpoint refuse sale before mutation. Historical identity never
makes an archived site an actionable supply or transport destination.

Retirement prepares archive capacity, proceeds posting and owned log text/capacity
before any cleanup. The arena-owned name outlives removal of its live map entry.
Commit installs the archive, removes active children/HQ, credits the unchanged
HQ-sale proceeds owner and records one HQ-tagged log. The outfit receives the
sale proceeds, including the disposed treasury, exactly once.

Schema 60 to 61 transactionally creates `retired_hq`; older campaigns receive an
empty archive. Lost legacy HQ names/worlds/tiers/days cannot be reconstructed:
legacy dangling historical tags are rejected as corrupt, including historical
references that old versions did not validate. Unexpected legacy archive rows
and inconsistent partially upgraded payloads also fail closed. Schema 59 to 60
ownership migration remains unchanged.

Current saves require a strictly checked archive row-count metadata value,
including zero, and original SQLite integer/text storage classes for every archive
field. IDs, tier, world and sale day are validated; current next-HQ metadata must
be an integer, nonzero and greater than every live/archived identity. Only the
legacy version boundary reconciles a counter after reference validation. Founding
checks HQ identity collision/exhaustion before allocation or gameplay mutation.

Existing typed history queries safely render archived names and retain original
HQ filters. Archived HQs never appear in treasury/action lists. This is shared
history integrity; P2i still owns artillery views, parser verbs and UI actions.
