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
There is no crew, maintenance work, cold storage, ammunition or supply charge here.

Ownership intervals use nullable closing days: null means open; zero is a real
closed day. Schema 59 to 60 preserves nonzero closing days, closes legacy zero rows
at the successor interval's start, and leaves final zero rows open. Invalid ordered
history is rejected. Explicit acquisition reasons preserve conventional salvage
behavior and record artillery disposal as transfer.

All formation and offer records, acquisition facts, placement payloads and counters
are persisted. Catalogue facts and attached physical position are derived; quotes
and preparation records are operation-local scratch. P2g owns operational fields;
P2h owns artillery battle effects; P2i owns artillery query and textual/UI actions.
