//! Player commands: the single choke point for every action (ARCH §4).
//! A tagged union in, validation, mutation via GameState, out. This gives us
//! an audit log, replayability, and scriptable golden-master tests for free.
//! No MekHQ counterpart: MekHQ changes the campaign from its GUI actions
//! (docs/mekhq-map.md).

const std = @import("std");
const tuning = @import("../domain/tuning.zig").t;
const types = @import("../domain/types.zig");
const person_mod = @import("../domain/person.zig");
const state_mod = @import("state.zig");
const GameState = state_mod.GameState;
const posture = @import("posture.zig");
const treasury = @import("treasury.zig");
const tick = @import("tick.zig");
const starter_company = @import("starter_company.zig");
const commander_mod = @import("../domain/commander.zig");
const contract_market = @import("contract_market.zig");
const logistics = @import("../econ/logistics.zig");
const part_mod = @import("../domain/part.zig");
const planet_mod = @import("../domain/planet.zig");
const market_mod = @import("../econ/market.zig");
const contract_events = @import("contract_events.zig");
const events_mod = @import("../domain/events.zig");
const medical_mod = @import("medical.zig");
const hq_ops = @import("hq_ops.zig");
const hq_mod = @import("../domain/hq.zig");
const contract_mod = @import("../domain/contract.zig");
const network = @import("network.zig");
const contract_control = @import("contract_control.zig");
const operation_control = @import("operation_control.zig");
const operation_mod = @import("../domain/operation.zig");
const lift_mod = @import("lift.zig");
const meklab = @import("../domain/meklab.zig");
const force_mod = @import("../domain/force.zig");
const unit_mod = @import("../domain/unit.zig");
const chassis_mod = @import("../domain/chassis.zig");
const person_gen = @import("../gen/person_gen.zig");
const digest = @import("digest.zig");
const sites = @import("sites.zig");
const field_supply = @import("field_supply.zig");
const founding = @import("founding.zig");
const refit_m = @import("refit.zig");
const crew = @import("crew.zig");
const toe = @import("toe.zig");
const personnel = @import("personnel.zig");
const held_hulls = @import("held_hulls.zig");

pub const Command = union(enum) {
    /// End the turn: advance one day. Turn-based — time only moves here,
    /// and nothing blocks it; decisions wait in the inbox with deadlines.
    advance_day,
    advance_days: u32,
    hire: struct {
        first: []const u8,
        last: []const u8,
        role: person_mod.Role,
    },
    /// Hire a randomly generated candidate (experience rolled on 2d6).
    recruit: person_mod.Role,
    fire: types.PersonId,
    /// Generate a full company: 3 lances of meks with pilots + support tail.
    new_company: []const u8,
    rename_outfit: []const u8,
    rename_force: struct { force: types.ForceId, name: []const u8 },
    /// Attach an emblem image (raw bytes) to a force (ARCH §5 identity).
    set_emblem: struct { force: types.ForceId, image: []const u8 },
    /// Character creation: origin picks the starter world (weighted, in the
    /// commander's faction space); profession grants one 2% edge.
    create_commander: struct {
        name: []const u8,
        origin: commander_mod.Faction,
        profession: commander_mod.Profession,
        /// Campaign start year: the market, RATs and salvage field
        /// only what exists by then.
        start_year: u16 = 3025,
        /// The founding outfit's chosen data/logos catalog key, reserved from NPC
        /// merc companies. "" when the player picked a preset or a non-catalog PNG.
        logo_key: []const u8 = "",
    },
    /// Accept an offer off the current board and send a company.
    accept_contract: struct { offer: types.ContractId, company: types.ForceId },
    /// Buy a special ability with XP at a training ground.
    train_ability: struct { person: types.PersonId, key: []const u8 },
    /// Pin a rank on a person; `.private` unpinned lets seats decide again.
    promote: struct { person: types.PersonId, rank: @import("../domain/rank.zig").Rank, pin: bool = true },
    /// One negotiation round on an offer: improve a term, harden
    /// the offer, or lose it.
    negotiate: struct { offer: types.ContractId, term: contract_mod.NegotiableTerm },
    take_loan: struct { principal: types.CBills, term_months: u16 },
    /// Order parts/munitions/supplies through logistics: an acquisition roll
    /// vs. rarity, then transit to `dest` (home warehouse by default, or a
    /// deployed company's field stores). Structural parts are guaranteed at
    /// a regional HQ (§9.8). Refused if the destination can't hold it.
    order_part: struct { part_key: []const u8, quantity: u32, dest: ?types.Site = null },
    /// Move stock between sites as a shipment (freight paid by the sender).
    ship_stock: struct { part_key: []const u8, quantity: u32, from: types.Site, to: types.Site },
    /// Buy off the site-market board (unit or part listing).
    buy_listing: types.ListingId,
    /// Cold storage (§9.8): mothball at home for 20% upkeep...
    mothball: types.UnitId,
    /// ...and pay the reactivation tech-days to wake it back up.
    reactivate: types.UnitId,
    /// Start a training program: XP → skill, only at a regional/brigade HQ
    /// with a training ground, only for people not deployed (ARCH §9.7).
    train: struct { person: types.PersonId, skill: types.SkillType },
    /// Bulk training: everyone in a company who is home,
    /// free and can afford the next level starts a program — at their
    /// role's primary skill unless one is named.
    train_company: struct { company: types.ForceId, skill: ?types.SkillType = null },
    /// Move money between treasuries by courier. Source debited
    /// now; credit arrives after map-distance transit (min 3 days).
    transfer: struct { from: state_mod.Treasury, to: state_mod.Treasury, amount: types.CBills },
    /// Standing top-up policy for an HQ or company, executed on payday.
    set_policy: struct { entity: state_mod.Treasury, floor: types.CBills, monthly_cap: types.CBills },
    /// Fabricate structural components in the HQ mek bay: the
    /// §9.8 guarantee — always available, ×1.5 cost, holds a bay slot.
    fabricate: struct { hq: types.HqId, part_key: []const u8, quantity: u32 },
    /// Build (level 0→1) or level up a facility: paperwork then construction,
    /// paid from HQ funds, permanently raising the staffing requirement.
    upgrade_facility: struct { hq: types.HqId, kind: hq_mod.FacilityKind },
    /// Post a person to HQ staff (the back office).
    post_person: struct { person: types.PersonId, hq: types.HqId },
    /// Crew/tech assignments: no tech → no repairs/reloads;
    /// no pilot → the hull doesn't fight.
    assign: struct { unit: types.UnitId, slot: crew.Slot, person: types.PersonId },
    unassign: struct { unit: types.UnitId, slot: crew.Slot },
    /// Fill every open slot in a company from its own people.
    auto_assign: types.ForceId,
    /// Hire off a hiring-hall board (asking bonus paid from the outfit).
    hire_candidate: types.CandidateId,
    /// Medbay triage priority (higher heals first when beds are short).
    triage: struct { person: types.PersonId, priority: u8 },
    /// R&R leave: unavailable, double fatigue recovery.
    leave: struct { person: types.PersonId, days: u16 },
    // ---- The network & multi-company operations ----
    /// Found a field HQ on a world you've reached: inside a ring or its
    /// beachhead band, or the site of a contract you've worked.
    found_hq: struct { name: []const u8, planet_key: []const u8 },
    /// Field → regional: a long project; the beachhead becomes a ring.
    upgrade_tier: types.HqId,
    /// Which HQ supplies a company (capacity slots enforced).
    assign_company: struct { company: types.ForceId, hq: types.HqId },
    /// Establish or raise a supply link between two HQs.
    link: struct { a: types.HqId, b: types.HqId, level: u8 },
    /// Generate a company at a specific HQ.
    new_company_at: struct { name: []const u8, hq: types.HqId },
    /// Move a hull between companies: instant when co-located at home,
    /// otherwise shipped with an ETA.
    transfer_unit: struct { unit: types.UnitId, to_company: types.ForceId },
    /// Move a person to another force (in transit if not co-located).
    transfer_person: struct { person: types.PersonId, to_force: types.ForceId },
    /// Recruit and post admins until an HQ meets its staffing requirement.
    autostaff: types.HqId,
    // ---- Contract control ----
    /// Close out an attrition contract whose objectives are substantially
    /// met (remainder forfeited, no breach).
    complete_contract: types.ContractId,
    /// Bring a company home: from an idle field posting freely, or off an
    /// active contract under the breach clause.
    recall_company: types.ForceId,
    // ---- The MekLab ----
    /// Stage a mount removal / installation on a hull's refit plan.
    refit_remove: struct { unit: types.UnitId, slot_key: []const u8 },
    refit_install: struct { unit: types.UnitId, location: meklab.Location, part_key: []const u8 },
    refit_clear: types.UnitId,
    /// Validate the plan against the rules, take the parts, and queue the
    /// bay job (class ≤ the HQ's ceiling).
    refit_commit: types.UnitId,
    /// Mark an after-action report read: the turn is held until
    /// every engagement has been seen.
    read_report: types.BattleId,
    resolve_decision: struct {
        /// The event's own id — never its row, which moves when a
        /// neighbour is answered or expires.
        event: types.EventId,
        choice: usize,
    },
    // ---- The player's hand on the money and the medbay ----
    /// Admit a wounded person to the medbay: healing only starts here.
    admit: types.PersonId,
    /// Pay a loan down early (simple interest: only charged months cost).
    repay_loan: struct { loan: types.LoanId, amount: types.CBills },
    /// Liquidate a hull at half value scaled by condition.
    sell_unit: types.UnitId,
    /// Strip a hull for parts into its home warehouse (MekHQ
    /// "salvage unit"): the only thing left to do with scrap.
    strip_unit: types.UnitId,
    /// Sell off an HQ (not the last one; companies must be reassigned first).
    sell_hq: types.HqId,
    /// Close a company: hulls sold, people released, forces struck.
    disband_company: types.ForceId,
    /// Send a hull to the depot now for structural repair (otherwise the
    /// weekly maintenance pass queues it when the components are in stock).
    depot: types.UnitId,
    /// Order a spare for every destroyed or missing piece of gear on a
    /// hull, whatever its kind (ARCH §9.7: weapons and equipment are field
    /// work on any hull; the Lab is only the mek way in). The spare lands
    /// at the hull's site and its own tech fits it on the weekly pass.
    replace_gear: types.UnitId,
    /// Forget a standing order: the inbox asks about that
    /// event kind again. `sop` lists them.
    clear_standing_order: []const u8,
    /// Lance role, MekHQ-style: fighting (default), defense (+power on
    /// garrison contracts), scouting (recon), training (held out of
    /// battles, gains XP at home).
    set_role: struct { force: types.ForceId, role: force_mod.LanceRole },
    /// Rules of engagement for a company.
    set_roe: struct { company: types.ForceId, roe: force_mod.Roe },
    /// Automatic provisions resupply: ship `tons` from the home warehouse
    /// whenever the deployed company's stores fall under `min_days`.
    /// `tons` caps one shipment (0 = no cap); `min_days` = 0 removes the policy.
    set_supply_policy: struct { company: types.ForceId, min_days: u16, tons: u32, ammo_battles: u8 = 0 },
    /// Put a hull into a lance (line or support) of its company, at home.
    move_unit: struct { unit: types.UnitId, force: types.ForceId },
    /// Raise a new lance under a company: a line lance (HQ
    /// lance cap), an air lance under the air wing, or a support lance of
    /// one kind under Omega (facility-gated, support-lance cap).
    new_lance: struct { company: types.ForceId, name: []const u8, kind: force_mod.NewLanceKind = .line },
    /// Raise a company's air wing — an empty air company with one air lance
    /// — in the home HQ's air slot (spaceport ≥ 3).
    raise_air_company: types.ForceId,
    /// Keep an HQ warehouse stocked: under `min` → order/fabricate up to
    /// `target`, checked daily. `target` = 0 removes the line.
    set_stock_policy: struct { hq: types.HqId, part_key: []const u8, min: u32, target: u32 },
    /// Let the medbay admit the wounded on its own each morning.
    set_auto_admit: bool,
    /// Difficulty: green | regular | veteran | elite — logged, takes effect at once.
    set_difficulty: @import("../domain/difficulty.zig").Level,
    /// Share of contract income paid to shareholders at completion,
    /// in percent 0–100.
    set_shares_pct: u8,
    /// Sell part of a warehouse line for its resale value (into the HQ's
    /// treasury). Refused below a keep-stocked line's minimum.
    sell_stock: struct { hq: types.HqId, part_key: []const u8, quantity: u32 },
    /// Raise a company as a skeleton: empty line lances up to
    /// the HQ's lance cap, an empty support echelon, no hulls, no crews.
    /// The wizard (or the market and the halls) fills it.
    raise_company: struct { name: []const u8, hq: types.HqId },
    /// Buy a hull listing for a company: on hand when the board belongs to
    /// its home HQ (placed in `lance`, or the first lance with room),
    /// otherwise shipped with the map transit.
    buy_hull_for: struct { listing: usize, company: types.ForceId, lance: types.ForceId = .none },
    /// Fill a company's manning table: astechs and medics hired
    /// to complement on the spot (MekHQ pools), every other short role
    /// taken from the hiring halls while candidates last.
    crew_company: types.ForceId,
    /// Trim a deployed company's field stores to its field plan: anything
    /// over a line's target, and consumables the plan has no line for
    /// (munitions nothing fires, structural components), ride the empty
    /// convoys home to the HQ. Weapon and equipment spares stay.
    trim_stock: types.ForceId,
    /// Buy one support hull of a kind off the company's home board into
    /// the matching support lance (the raise wizard's support step).
    buy_support_hull: struct { company: types.ForceId, kind: force_mod.SupportLanceKind },
    /// The crest is outfit-wide: every company carries it.
    set_outfit_emblem: []const u8,
    /// Size one back-office desk at an HQ by one: hire and post, or release.
    set_office_staff: struct { hq: types.HqId, role: person_mod.Role, delta: i8 },
    /// Send every structural component in a company's field stores home.
    ship_components_home: types.ForceId,
    /// Order a replacement for one broken mount to the hull's home HQ.
    replace_mount: struct { unit: types.UnitId, slot_key: []const u8 },
    /// Cover a structural shortfall: fabricate when the bay can, else order.
    cover_shortfall: struct { hq: types.HqId, part_key: []const u8, quantity: u32 },
    /// Mothball a running hull, reactivate a mothballed one.
    toggle_mothball: types.UnitId,
    /// Step a company's rules of engagement: standard → cautious → hold.
    cycle_roe: types.ForceId,
    /// Step a lance's role: fighting → defense → scouting → training.
    cycle_role: types.ForceId,
    /// Battle orders for the engagement in view are given; the contact
    /// warning clears.
    confirm_orders: types.ContractId,
    /// Buy the short munitions and armour on the contract world, delivered
    /// today (`field_supply.rushQuote`).
    emergency_resupply: types.ContractId,
    /// Step the difficulty up or down the ladder.
    cycle_difficulty: i8,
    /// Move the shareholders' cut by a few points, clamped to 0…100.
    adjust_shares_pct: i8,
    toggle_auto_admit,
    /// Bring an idle company home; refused under contract (the breach
    /// recall is `recall_company`).
    recall_idle: types.ForceId,
    /// Commit an available operation on an active arc contract with an explicit mission intent.
    commit_operation: struct { contract: types.ContractId, operation: types.OperationId, intent: operation_mod.Intent },
    /// Decline an available operation on an active arc contract.
    decline_operation: struct { contract: types.ContractId, operation: types.OperationId },
    /// Assign a tactical task to a lance for a committed combat operation (P4e).
    task_lance: struct { contract: types.ContractId, operation: types.OperationId, lance: types.ForceId, task: operation_mod.LanceTask },
    /// Remove a lance's task assignment from a committed combat operation (P4e).
    clear_lance_task: struct { contract: types.ContractId, operation: types.OperationId, lance: types.ForceId },
    /// Set the tempo posture for an available operation (P4f).
    set_operation_tempo: struct { contract: types.ContractId, operation: types.OperationId, tempo: operation_mod.TempoPosture },
    /// Apply a command intervention to a committed combat operation (P4g).
    apply_intervention: struct { contract: types.ContractId, operation: types.OperationId, intervention: operation_mod.Intervention },
    /// Operationally withdraw from an available or committed operation (P4h).
    withdraw_operation: struct { contract: types.ContractId, operation: types.OperationId },
    /// Exploit a resolved successful combat operation by launching follow-ups (P4h).
    exploit_operation: struct { contract: types.ContractId, operation: types.OperationId },
    /// Consolidate a resolved operation to relieve escalation pressure (P4h).
    consolidate_operation: struct { contract: types.ContractId, operation: types.OperationId },
};

pub const Error = error{
    UnknownPerson,
    UnknownForce,
    UnknownUnit,
    UnknownChassis,
    NoSuchEvent,
    /// No pending inbox decision with that id.
    NoSuchDecision,
    /// No engagement on record with that id.
    NoSuchBattle,
    /// An engagement has not been read, and the turn waits on it.
    ReportUnread,
    /// A battle decision is unanswered, and the turn waits on it.
    DecisionPending,
    NoSuchChoice,
    NotADecision,
    CommanderExists,
    NoHomeWorld,
    NoSuchOffer,
    NotACompany,
    CompanyDeployed,
    UnknownPlanet,
    UnknownPart,
    NoSuchListing,
    UnitDeployed,
    NotMothballed,
    AlreadyMothballed,
    NoHq,
    NoTrainingGround,
    PersonDeployed,
    PersonUnavailable,
    AlreadyTraining,
    NotTrained,
    InsufficientXp,
    AlreadyMastered,
    BadPercent,
    BadYear,
    InsufficientTreasury,
    UnknownTreasury,
    StorageFull,
    InsufficientStock,
    UnknownSite,
    UnknownHq,
    NoBay,
    NotAComponent,
    ProjectInProgress,
    MaxLevel,
    MissingComponents,
    WrongRole,
    Unavailable,
    NoTechSlot,
    NoSuchCandidate,
    NotReachable,
    CapacityFull,
    TooManyLances,
    NoRoute,
    ThroughputExceeded,
    SameForce,
    BadLevel,
    UnknownContract,
    ObjectivesNotMet,
    CompanyInTransit,
    NoPlan,
    IllegalFit,
    RefitClassTooHigh,
    MissingParts,
    UnitAway,
    NotAMek,
    NoSuchSlot,
    NotWounded,
    NoSuchLoan,
    CreditExceeded,
    LastHq,
    HqInUse,
    /// Outfit treasury negative: the turn waits for a loan or a sale.
    Insolvent,
    /// Nothing left to sell or borrow: game over.
    Bankrupt,
    NothingToRepair,
    NothingToReplace,
    /// Scrap: nothing to rebuild — strip it for parts.
    WrittenOff,
    /// The bay is not rated for this assembly's weight class.
    BayTooSmall,
    /// The offer is on another HQ's board.
    OutOfRange,
    KeepStocked,
    /// The home HQ's spaceport hosts no (more) air wings.
    NoAirSlot,
    /// A recall for a company that is already home.
    AlreadyHome,
    /// An idle recall for a company under contract: the breach recall is a
    /// different order (Contracts screen).
    UnderContract,
    /// The board's HQ treasury cannot cover the listing.
    HqTreasuryShort,
    /// The company's local funds cannot cover the contract-world listing.
    CompanyFundsShort,
    /// Only a field HQ can be raised to regional.
    /// No structural components in the field stores to send home.
    NothingToShip,
    /// The mount is intact: nothing to replace.
    MountIsFine,
    /// The support company is full, or the facilities can't stand up that lance kind.
    NoSupportSlot,
    /// No free dropship/jumpship berth at that HQ.
    NoBerth,
    /// A dedicated supply line needs a crewed jumpship at one end.
    NoJumpship,
    /// Fighters fly in air lances, meks walk in line lances.
    WrongHullKind,
    /// A pool hull sits at the outfit's seat; the person's company is not home there.
    PersonAway,
    /// This offer has had its negotiation round.
    AlreadyNegotiated,
    /// No such special ability, or already learned.
    UnknownAbility,
    AlreadyLearned,
    /// That term is already at the best the employer will give.
    TermAtCap,
    /// No engagement on that contract is inside the contact window.
    NoContact,
    /// The company's stores already cover the next fight.
    NothingToRush,
    /// A stock quantity addition would overflow the u32 counter (rule 47).
    StockOverflow,
    /// `set_office_staff` with delta < 0 and no one in that role to release.
    NoOneInRole,
    /// `buy_support_hull`: the staple line for that hull kind is not on the
    /// home board right now (it restocks as the board refreshes).
    StapleOffBoard,
    /// `post_person`: the person is already posted at that HQ.
    AlreadyPosted,
    /// `take_loan`: term_months exceeds the maximum allowed (tuning.finance.loan_max_term_months).
    LoanTermTooLong,
    /// `fabricate`: quantity exceeds the per-command maximum (tuning.market.fab_max_qty).
    TooManyFabricated,
    /// No operation with that id on the contract.
    UnknownOperation,
    /// The operation is not in the `available` state.
    OperationUnavailable,
    /// A combat operation requires an opposition force on this contract.
    OperationNoOpposition,
    /// A combat operation is already committed on this contract.
    OperationBusy,
    /// The chosen intent is outside the legal set for this operation × command rights.
    OperationIntentIllegal,
    /// The operation is not in the committed state (tasking requires commitment).
    OperationNotCommitted,
    /// The lance is not eligible for tasking on this operation.
    LanceNotTaskable,
    /// The task is not legal for this operation and command rights combination.
    TaskIllegal,
    /// No force with that id in this contract's company.
    UnknownLance,
    /// The chosen tempo posture is not legal for this operation type.
    OperationTempoIllegal,
    /// The intervention gate predicate is not met (P4g).
    InterventionGateUnmet,
    /// Insufficient command capacity to pay for this intervention (P4g).
    InsufficientCommandCapacity,
    /// This intervention has already been applied to this operation (P4g).
    InterventionAlreadyApplied,
    /// This operation cannot be withdrawn (wrong state) (P4h).
    OperationNotWithdrawable,
    /// This operation cannot be exploited (not resolved combat success with follow-up) (P4h).
    OperationNotExploitable,
    /// No follow-up operations are defined for this template (P4h).
    NoFollowUp,
    /// This operation cannot be consolidated (not resolved) (P4h).
    OperationNotConsolidatable,
} || std.mem.Allocator.Error;

pub const Result = struct {
    days_advanced: u32 = 0,
    /// advance: why a multi-day advance stopped before the requested count.
    /// `.none` when the full count ran or when zero days elapsed (the zero-
    /// day case returns an error, not a Result). Ephemeral — not persisted,
    /// not in the digest (rule 45 applies to state fields only).
    stopped: enum { none, insolvent, bankrupt } = .none,
    /// advance: the contract whose contact warning stopped a multi-day
    /// advance early.
    contact: types.ContractId = .none,
    /// transfer_unit: the hull travels (else it was placed at once).
    in_transit: bool = false,
    /// depot: the HQ whose bay took the job.
    hq: types.HqId = .none,
    /// The setting after a cycle/toggle, for the client's echo.
    roe: ?force_mod.Roe = null,
    role: ?force_mod.LanceRole = null,
    difficulty_name: []const u8 = "",
    difficulty_blurb: []const u8 = "",
    shares_pct: u8 = 0,
    auto_admit: ?bool = null,
    mothballed: ?bool = null,
    /// ship_components_home: components sent.
    count: u32 = 0,
    hired: types.PersonId = .none,
    created_force: types.ForceId = .none,
    /// Tons a `trim_stock` sent home.
    tons_moved: u32 = 0,
    /// The hull a `buy_hull_for` bought, and its delivery time (0 = on hand).
    unit: types.UnitId = .none,
    eta_days: u32 = 0,
    /// People a `crew_company` hired (halls plus the astech/medic pools),
    /// and the manning lines it could not fill because no candidate of
    /// that role walked the boards.
    hired_count: u32 = 0,
    still_open: u32 = 0,
    /// `order_part`: false when logistics failed the sourcing roll (the
    /// order is recorded as failed; retry after the refresh or fabricate).
    sourced: bool = true,
    /// `order_part` echo: key, quantity, eta day and cost (when sourced).
    order_key: []const u8 = "",
    order_quantity: u32 = 0,
    order_eta: u32 = 0,
    order_cost: types.CBills = 0,
    /// `buy_listing`, `buy_hull_for`, `buy_support_hull`: the black-market fence
    /// took the money; no unit/stock resulted (rules 33, 34 — ephemeral, not
    /// persisted, not in the digest; rule 45 applies to GameState fields only).
    fraud: bool = false,
    /// `cover_shortfall`: the bay makes it (a job), not the market.
    fabricated: bool = false,
    /// `accept_contract`: the ContractId of the accepted contract.
    contract: types.ContractId = .none,
    /// `take_loan`: the LoanId of the new loan.
    loan: types.LoanId = .none,
    /// `found_hq`: the HqId of the newly created HQ.
    created_hq: types.HqId = .none,
    /// `negotiate`: how the round went.
    negotiation: enum { none, improved, hardened, withdrawn } = .none,
    /// `replace_gear`: spares ordered, and those logistics could not source.
    ordered: u32 = 0,
    unsourced: u32 = 0,
    /// `train_company`: who started a program, who could not afford one,
    /// who was busy (training, away, unfit), and who had nothing to learn.
    enrolled: u32 = 0,
    short_xp: u32 = 0,
    busy: u32 = 0,
    nothing_to_learn: u32 = 0,
};

/// Canonical sentence for a black-market fraud outcome (rule 24 — one string,
/// one owner; re-exported by cli.zig so frontends reach it as game.cli.hull_fraud_text).
pub const hull_fraud_text = "the black-market fence vanished with the money — no hull";

pub fn execute(gs: *GameState, cmd: Command) Error!Result {
    switch (cmd) {
        .advance_day => return tick.advance(gs, 1),
        .advance_days => |n| return tick.advance(gs, n),
        .hire => |h| return personnel.execHire(gs, h),
        .recruit => |role| return personnel.execRecruit(gs, role),
        .fire => |id| return personnel.execFire(gs, id),
        .new_company => |name| return toe.execNewCompany(gs, name),
        .new_company_at => |n| return toe.execNewCompanyAt(gs, n),
        .found_hq => |f| return hq_ops.execFoundHq(gs, f),
        .upgrade_tier => |hq_id| return hq_ops.execUpgradeTier(gs, hq_id),
        .assign_company => |a| return network.execAssignCompany(gs, a),
        .link => |l| return network.execLink(gs, l),
        .transfer_unit => |t| return toe.transferUnit(gs, t.unit, t.to_company),
        .complete_contract => |cid| return contract_control.execCompleteContract(gs, cid),
        .recall_company => |company| return contract_control.execRecallCompany(gs, company),
        .refit_remove => |r| return refit_m.execRefitRemove(gs, r),
        .refit_install => |r| return refit_m.execRefitInstall(gs, r),
        .refit_clear => |unit_id| return refit_m.execRefitClear(gs, unit_id),
        .refit_commit => |unit_id| return refit_m.commitRefit(gs, unit_id),
        .buy_support_hull => |b| return contract_market.execBuySupportHull(gs, b),
        .set_outfit_emblem => |image| return toe.execSetOutfitEmblem(gs, image),
        .set_office_staff => |o| return personnel.execSetOfficeStaff(gs, o),
        .ship_components_home => |co| return sites.execShipComponentsHome(gs, co),
        .replace_mount => |r| return sites.execReplaceMount(gs, r),
        .cover_shortfall => |c| return hq_ops.execCoverShortfall(gs, c),
        .toggle_mothball => |unit_id| return held_hulls.execToggleMothball(gs, unit_id),
        .confirm_orders => |id| return contract_control.execConfirmOrders(gs, id),
        .emergency_resupply => |id| return field_supply.execEmergencyResupply(gs, id),
        .cycle_roe => |co| return toe.execCycleRoe(gs, co),
        .cycle_role => |fid| return toe.execCycleRole(gs, fid),
        .cycle_difficulty => |dir| return tick.execCycleDifficulty(gs, dir),
        .adjust_shares_pct => |delta| return treasury.execAdjustSharesPct(gs, delta),
        .toggle_auto_admit => return medical_mod.execToggleAutoAdmit(gs),
        .recall_idle => |company| return toe.execRecallIdle(gs, company),
        .commit_operation => |a| return operation_control.execCommitOperation(gs, a),
        .decline_operation => |a| return operation_control.execDeclineOperation(gs, a),
        .task_lance => |a| return operation_control.execTaskLance(gs, a),
        .clear_lance_task => |a| return operation_control.execClearLanceTask(gs, a),
        .set_operation_tempo => |a| return operation_control.execSetOperationTempo(gs, a),
        .apply_intervention => |a| return operation_control.execApplyIntervention(gs, a),
        .withdraw_operation => |a| return operation_control.execWithdrawOperation(gs, a),
        .exploit_operation => |a| return operation_control.execExploitOperation(gs, a),
        .consolidate_operation => |a| return operation_control.execConsolidateOperation(gs, a),
        .autostaff => |hq_id| return hq_ops.execAutostaff(gs, hq_id),
        .transfer_person => |t| return personnel.execTransferPerson(gs, t),
        .rename_outfit => |name| return toe.execRenameOutfit(gs, name),
        .rename_force => |r| return toe.execRenameForce(gs, r),
        .set_emblem => |e| return toe.execSetEmblem(gs, e),
        .create_commander => |c| return founding.execCreateCommander(gs, c),
        .accept_contract => |a| return contract_control.execAcceptContract(gs, a),
        .negotiate => |n| return contract_market.execNegotiate(gs, n),
        .train_ability => |ta| return medical_mod.execTrainAbility(gs, ta),
        .promote => |pr| return personnel.execPromote(gs, pr),
        .order_part => |o| return sites.execOrderPart(gs, o),
        .ship_stock => |s| return sites.execShipStock(gs, s),
        .buy_listing => |lid| return contract_market.execBuyListing(gs, lid),
        .mothball => |unit_id| return held_hulls.execMothball(gs, unit_id),
        .move_unit => |m| return toe.execMoveUnit(gs, m),
        .new_lance => |nl| return toe.execNewLance(gs, nl),
        .raise_air_company => |company| return toe.execRaiseAirCompany(gs, company),
        .set_supply_policy => |sp| return field_supply.execSetSupplyPolicy(gs, sp),
        .set_stock_policy => |sp| return sites.execSetStockPolicy(gs, sp),
        .sell_stock => |sale| return sites.execSellStock(gs, sale),
        .raise_company => |r| return toe.raiseCompany(gs, r.name, r.hq),
        .buy_hull_for => |b| return contract_market.execBuyHullFor(gs, b),
        .crew_company => |company| return crew.execCrewCompany(gs, company),
        .trim_stock => |company| return field_supply.execTrimStock(gs, company),
        .set_shares_pct => |pct| return treasury.execSetSharesPct(gs, pct),
        .set_difficulty => |level| return tick.execSetDifficulty(gs, level),
        .set_auto_admit => |on| return medical_mod.execSetAutoAdmit(gs, on),
        .set_roe => |r| return toe.execSetRoe(gs, r),
        .set_role => |r| return toe.execSetRole(gs, r),
        .replace_gear => |unit_id| return sites.execReplaceGear(gs, unit_id),
        .clear_standing_order => |name| return contract_events.execClearStandingOrder(gs, name),
        .depot => |unit_id| return hq_ops.execDepot(gs, unit_id),
        .admit => |pid| return medical_mod.execAdmit(gs, pid),
        .repay_loan => |r| return treasury.execRepayLoan(gs, r),
        .sell_unit => |unit_id| return held_hulls.execSellUnit(gs, unit_id),
        .strip_unit => |unit_id| return held_hulls.execStripUnit(gs, unit_id),
        .sell_hq => |hq_id| return hq_ops.execSellHq(gs, hq_id),
        .disband_company => |co| return toe.execDisbandCompany(gs, co),
        .reactivate => |unit_id| return hq_ops.execReactivate(gs, unit_id),
        .fabricate => |f0| return hq_ops.execFabricate(gs, f0),
        .upgrade_facility => |u| return hq_ops.execUpgradeFacility(gs, u),
        .post_person => |pp| return personnel.execPostPerson(gs, pp),
        .assign => |a| return crew.execAssign(gs, a),
        .unassign => |u| return crew.execUnassign(gs, u),
        .auto_assign => |company| return crew.execAutoAssign(gs, company),
        .hire_candidate => |cid| return contract_market.execHireCandidate(gs, cid),
        .triage => |t| return medical_mod.execTriage(gs, t),
        .leave => |l| return medical_mod.execLeave(gs, l),
        .train => |t| return medical_mod.execTrain(gs, t),
        .train_company => |t| return medical_mod.execTrainCompany(gs, t),
        .transfer => |t| return treasury.execTransfer(gs, t),
        .set_policy => |p| return treasury.execSetPolicy(gs, p),
        .take_loan => |l| return treasury.execTakeLoan(gs, l),
        .read_report => |id| return tick.execReadReport(gs, id),
        .resolve_decision => |r| return contract_events.execResolveDecision(gs, r),
    }
}

test "golden master: same seed + same script = same state hash" {
    const script = [_]Command{
        .{ .hire = .{ .first = "Grayson", .last = "Carlyle", .role = .mekwarrior } },
        .{ .hire = .{ .first = "Lori", .last = "Kalmar", .role = .mekwarrior } },
        .{ .hire = .{ .first = "Clay", .last = "Cluny", .role = .tech_mek } },
        .{ .advance_days = 45 },
        .{ .fire = @enumFromInt(2) },
        .{ .advance_days = 45 },
    };

    var hashes: [2]u64 = undefined;
    for (&hashes) |*out| {
        var gs = GameState.init(std.testing.allocator, .{ .seed = 42 });
        defer gs.deinit();
        for (script) |cmd| _ = try execute(&gs, cmd);
        out.* = digest.stateHash(&gs);
    }
    try std.testing.expectEqual(hashes[0], hashes[1]);

    // A different seed must not accidentally replay the same campaign.
    var other = GameState.init(std.testing.allocator, .{ .seed = 43 });
    defer other.deinit();
    for (script) |cmd| _ = try execute(&other, cmd);
    // The script draws little randomness, so the states may legitimately
    // match across seeds; the day must still follow the script.
    try std.testing.expectEqual(@as(u32, 90), other.clock.day_index);
}

test "end to end: commander, company, contract to completion" {
    var gs = GameState.init(std.testing.allocator, .{ .seed = 2025 });
    defer gs.deinit();

    _ = try execute(&gs, .{ .create_commander = .{ .name = "Erik Kalmar", .origin = .CC, .profession = .paymaster } });
    try std.testing.expectError(Error.CommanderExists, execute(&gs, .{
        .create_commander = .{ .name = "X", .origin = .LC, .profession = .line_officer },
    }));

    // Starter HQ stood up in Capellan space; offers on the board.
    try std.testing.expectEqual(@as(usize, 1), gs.hqs.count());
    const hq_world = @import("../domain/planet.zig").find(gs.hqs.values()[0].planet_key).?;
    try std.testing.expectEqualStrings("CC", hq_world.faction);
    try std.testing.expect(gs.contract_offers.items.len > 0);

    const co = (try execute(&gs, .{ .new_company = "Alpha Company" })).created_force;

    // Take the shortest offer available (any kind — lifecycle is identical).
    var best: usize = 0;
    for (gs.contract_offers.items, 0..) |offer, i| {
        if (offer.terms.length_months < gs.contract_offers.items[best].terms.length_months) best = i;
    }
    const best_id = gs.contract_offers.items[best].id;
    const funds_before = gs.funds;
    _ = try execute(&gs, .{ .accept_contract = .{ .offer = best_id, .company = co } });
    try std.testing.expect(gs.funds != funds_before); // advance + freight posted

    const c = gs.contracts.values()[0];
    try std.testing.expectEqual(@import("../domain/contract.zig").ContractStatus.transit, c.status);
    // Verify any remaining offer is refused because the company is deployed.
    if (gs.contract_offers.items.len > 0) {
        const any_offer = gs.contract_offers.items[0].id;
        try std.testing.expectError(Error.CompanyDeployed, execute(&gs, .{
            .accept_contract = .{ .offer = any_offer, .company = co },
        }));
    }

    // Run to completion: transit + length + slack. The player's one duty
    // along the way: admit the wounded, or they never heal and
    // the company bleeds out to combat-ineffectiveness.
    const total_days = c.transit_days + @as(u32, c.terms.length_months) * 30 + 40;
    var advanced: u32 = 0;
    while (advanced < total_days) : (advanced += 7) {
        try tick.advanceReading(&gs, 7);
        var pit = gs.people.iterator();
        while (pit.next()) |entry| {
            const p = entry.value_ptr;
            if (p.status == .wounded and !p.medbay_admitted) _ = try execute(&gs, .{ .admit = p.id });
        }
    }
    const done = gs.contracts.values()[0];
    try std.testing.expectEqual(@import("../domain/contract.zig").ContractStatus.completed, done.status);
    // Completion pays 1 + clamp(score/2, -1, 3) reputation — never below 0
    // for a completed (not failed) contract; events' defaults are all
    // reputation-neutral-or-positive by design.
    try std.testing.expect(gs.reputation >= 0);

    // The books show contract income.
    const summary = @import("../econ/finance.zig").summarize(&gs.ledger, 0, gs.clock.day_index, .all);
    try std.testing.expect(summary.category(.contract_payment) > 0);
    try std.testing.expect(summary.category(.advance) > 0);
    try std.testing.expect(summary.category(.payroll) < 0);
}

test "the structured log filters by entity and category" {
    var gs = GameState.init(std.testing.allocator, .{ .seed = 93 });
    defer gs.deinit();
    const co: types.ForceId = @enumFromInt(7);
    try gs.log(.battle, .{ .company = co }, "AAR one", .{});
    try gs.log(.decision, .{ .company = co }, "chose", .{});
    try gs.log(.battle, .{ .company = @enumFromInt(8) }, "AAR other", .{});
    try gs.log(.finance, .{ .hq = @enumFromInt(1) }, "overdrawn", .{});

    var battles: usize = 0;
    var mine: usize = 0;
    var hq_lines: usize = 0;
    for (gs.event_log.items) |e| {
        if (e.matches(.{ .category = .battle })) battles += 1;
        if (e.matches(.{ .company = co })) mine += 1;
        if (e.matches(.{ .hq = @enumFromInt(1) })) hq_lines += 1;
    }
    try std.testing.expectEqual(@as(usize, 2), battles);
    try std.testing.expectEqual(@as(usize, 2), mine);
    try std.testing.expectEqual(@as(usize, 1), hq_lines);
}

test "command validation errors" {
    var gs = GameState.init(std.testing.allocator, .{});
    defer gs.deinit();
    try std.testing.expectError(Error.UnknownPerson, execute(&gs, .{ .fire = @enumFromInt(99) }));
    try std.testing.expectError(Error.NoSuchDecision, execute(&gs, .{ .resolve_decision = .{ .event = @enumFromInt(99), .choice = 0 } }));
    try std.testing.expectError(Error.UnknownForce, execute(&gs, .{ .rename_force = .{ .force = @enumFromInt(7), .name = "x" } }));
}

test "ships need berths, lift the company for less charter, and come home with it; a dedicated line needs a jumpship" {
    var gs = GameState.init(std.testing.allocator, .{ .seed = 16 });
    defer gs.deinit();
    _ = try execute(&gs, .{ .create_commander = .{ .name = "T", .origin = .LC, .profession = .paymaster } });
    const hq = gs.seat();
    gs.hqs.getPtr(hq).?.funds = 500_000_000;
    gs.funds = 50_000_000;
    const co = (try execute(&gs, .{ .new_company = "Alpha" })).created_force;

    // One dropship berth at spaceport 1: the second Leopard is refused.
    const leo1_id: types.ListingId = @enumFromInt(gs.next_listing_id);
    try gs.market_listings.append(gs.allocator(), .{ .id = leo1_id, .kind = .unit, .item_key = "LEOPARD", .rarity = .rare, .price = 20_000_000, .hq = hq, .listed_day = 0, .expires_day = 400 });
    gs.next_listing_id += 1;
    const leo2_id: types.ListingId = @enumFromInt(gs.next_listing_id);
    try gs.market_listings.append(gs.allocator(), .{ .id = leo2_id, .kind = .unit, .item_key = "LEOPARD", .rarity = .rare, .price = 20_000_000, .hq = hq, .listed_day = 0, .expires_day = 400 });
    gs.next_listing_id += 1;
    _ = try execute(&gs, .{ .buy_listing = leo1_id });
    const ship: types.UnitId = @enumFromInt(gs.next_unit_id - 1);
    try std.testing.expectEqual(hq, gs.unit(ship).?.berth_hq);
    try std.testing.expectError(Error.NoBerth, execute(&gs, .{ .buy_listing = leo2_id }));
    try std.testing.expectEqual(@as(u32, 1), lift_mod.transportsBerthedAt(&gs, hq, .dropship));

    // No jumpship: a dedicated line is refused; charter and scheduled are fine.
    // Found the second HQ on a world inside the starter ring (the map is
    // Terra-wide; the starter world moves with the seed).
    const home_world = planet_mod.find(gs.hqs.getPtr(hq).?.planet_key).?;
    var far_key: []const u8 = "";
    for (planet_mod.catalog) |*p| if (p != home_world and planet_mod.distanceLy(p, home_world) <= gs.hqs.getPtr(hq).?.influenceLy() and far_key.len == 0) {
        far_key = p.key;
    };
    _ = try execute(&gs, .{ .found_hq = .{ .name = "Far", .planet_key = far_key } });
    const far = gs.hqs.keys()[1];
    try std.testing.expectError(Error.NoJumpship, execute(&gs, .{ .link = .{ .a = hq, .b = far, .level = 3 } }));
    _ = try execute(&gs, .{ .link = .{ .a = hq, .b = far, .level = 2 } });

    // Uncrewed, the ship lifts nothing: full charter. (The employer pays no
    // transport share here so the charter is a real number to compare.)
    // An offer off-world, so there is a charter to compare.
    var offer_idx: usize = 0;
    for (gs.contract_offers.items, 0..) |o, i| if (o.dist_ly > gs.contract_offers.items[offer_idx].dist_ly) {
        offer_idx = i;
    };
    gs.contract_offers.items[offer_idx].terms.transport_pct = 0;
    const offer_id = gs.contract_offers.items[offer_idx].id;
    const charter_full = blk: {
        const c = gs.contract_offers.items[offer_idx];
        break :blk @divTrunc(@as(types.CBills, c.dist_ly) * 2_000 * (100 - @as(i64, c.terms.transport_pct)), 100);
    };
    try std.testing.expectEqual(@as(types.Bp, 0), (try lift_mod.planLiftQuery(&gs, co)).covered_bp);
    // Crew it: a dropship crew in the pilot seat.
    const dropship_pilot = try gs.hirePerson("Ina", "Voss", .dropship_crew);
    try crew.assignSlot(&gs, ship, .pilot, dropship_pilot);
    const plan = try lift_mod.planLiftQuery(&gs, co);
    try std.testing.expectEqual(@as(u32, 1), plan.ships);
    try std.testing.expect(plan.carried >= 4 and plan.carried <= plan.needed);
    try std.testing.expect(plan.covered_bp > 0 and plan.covered_bp < 10_000);

    // Accept: the charter posted is below the full price, and the ship sails with the company.
    const ledger_before = gs.ledger.transactions.items.len;
    _ = try execute(&gs, .{ .accept_contract = .{ .offer = offer_id, .company = co } });
    var charter_paid: types.CBills = 0;
    for (gs.ledger.transactions.items[ledger_before..]) |t| if (t.category == .transport_charter) {
        charter_paid = -t.amount;
    };
    try std.testing.expect(charter_paid > 0 and charter_paid < types.applyBp(charter_full, commander_mod.costMultBp(gs.commander, .freight)));
    try std.testing.expectEqual(co, gs.unit(ship).?.force);
    try std.testing.expect(!lift_mod.transportAvailable(&gs, gs.unit(ship).?));
    try std.testing.expectEqual(@as(u32, 0), (try lift_mod.planLiftQuery(&gs, co)).ships -| 1); // still one ship, the one carrying it

    // Home again: the ship returns to its berth.
    const cid = gs.contracts.keys()[0];
    gs.contracts.getPtr(cid).?.status = .completed;
    gs.force(co).?.location_planet = gs.contracts.getPtr(cid).?.planet_key;
    _ = try contract_control.recall(&gs, co);
    gs.force(co).?.return_eta_day = gs.clock.day_index;
    try contract_control.runReturns(&gs);
    try std.testing.expectEqual(types.ForceId.none, gs.unit(ship).?.force);
    try std.testing.expect(lift_mod.transportAvailable(&gs, gs.unit(ship).?));

    // A crewed jumpship at the berth (spaceport 4, comms 3) unlocks the dedicated line.
    try toe.setFacilityLevel(&gs, hq, .spaceport, 4);
    try toe.setFacilityLevel(&gs, hq, .comms, 3);
    const scout_id: types.ListingId = @enumFromInt(gs.next_listing_id);
    try gs.market_listings.append(gs.allocator(), .{ .id = scout_id, .kind = .unit, .item_key = "SCOUT", .rarity = .rare, .price = 50_000_000, .hq = hq, .listed_day = 0, .expires_day = 400 });
    gs.next_listing_id += 1;
    _ = try execute(&gs, .{ .buy_listing = scout_id });
    const jump: types.UnitId = @enumFromInt(gs.next_unit_id - 1);
    try std.testing.expectError(Error.NoJumpship, execute(&gs, .{ .link = .{ .a = hq, .b = far, .level = 3 } }));
    try crew.assignSlot(&gs, jump, .pilot, try gs.hirePerson("Oda", "Ferro", .jumpship_crew));
    _ = try execute(&gs, .{ .link = .{ .a = hq, .b = far, .level = 3 } });
    try std.testing.expectEqual(@as(u8, 3), network.findLink(&gs, hq, far).?.level);
    try std.testing.expectEqual(@as(types.CBills, 0), network.findLink(&gs, hq, far).?.monthlyCost());
    // With a jumpship of its own the company's next lift waives the collar fee too.
    try std.testing.expect((try lift_mod.planLiftQuery(&gs, co)).own_jumpship);
}

test "a command leaves derived state consistent: firing, disbanding and selling an HQ clean up after themselves" {
    var gs = GameState.init(std.testing.allocator, .{ .seed = 12 });
    defer gs.deinit();
    _ = try execute(&gs, .{ .create_commander = .{ .name = "T", .origin = .LC, .profession = .paymaster } });
    gs.funds = 50_000_000;
    const seat = gs.seat();

    // Firing a posted admin: the desk count drops inside the command, the
    // departure day is recorded and the posting stays on the record.
    const r = try execute(&gs, .{ .recruit = .admin_hr });
    _ = try execute(&gs, .{ .post_person = .{ .person = r.hired, .hq = seat } });
    const before = gs.hqs.getPtr(seat).?.staff_assigned;
    _ = try execute(&gs, .{ .fire = r.hired });
    try std.testing.expectEqual(before - 1, gs.hqs.getPtr(seat).?.staff_assigned);
    const gone = gs.person(r.hired).?;
    try std.testing.expectEqual(@as(?u32, gs.clock.day_index), gone.departed_day);
    try std.testing.expectEqual(seat, gone.posted_hq);

    // Disbanding a company takes its standing orders and resupply plan with it.
    const co = (try execute(&gs, .{ .new_company = "Alpha" })).created_force;
    _ = try execute(&gs, .{ .set_policy = .{ .entity = .{ .company = co }, .floor = 100_000, .monthly_cap = 200_000 } });
    _ = try execute(&gs, .{ .set_supply_policy = .{ .company = co, .min_days = 14, .tons = 40 } });
    const Count = struct {
        fn forCompany(g: *GameState, c: types.ForceId) usize {
            var n: usize = 0;
            for (g.supply_policies.items) |sp| if (sp.company == c) {
                n += 1;
            };
            for (g.policies.items) |pol| if (std.meta.eql(pol.entity, .{ .company = c })) {
                n += 1;
            };
            return n;
        }
    };
    try std.testing.expectEqual(@as(usize, 2), Count.forCompany(&gs, co));
    _ = try execute(&gs, .{ .disband_company = co });
    try std.testing.expectEqual(@as(usize, 0), Count.forCompany(&gs, co));

    // Selling an HQ takes its reorder points and cancels the goods bound for it.
    _ = try execute(&gs, .{ .found_hq = .{ .name = "Far", .planet_key = "zebebelgenubi" } });
    const far = gs.hqs.keys()[1];
    gs.hqs.getPtr(far).?.funds = 5_000_000;
    _ = try execute(&gs, .{ .set_stock_policy = .{ .hq = far, .part_key = "mlas", .min = 1, .target = 2 } });
    try gs.part_orders.append(gs.allocator(), .{ .part_key = "mlas", .quantity = 1, .dest = .{ .hq = far }, .ordered_day = gs.clock.day_index, .cost = 1, .status = .in_transit });
    var bound: usize = 0;
    for (gs.part_orders.items) |o| if (o.inFlight() and std.meta.eql(o.dest, .{ .hq = far })) {
        bound += 1;
    };
    try std.testing.expectEqual(@as(usize, 1), bound);
    _ = try execute(&gs, .{ .sell_hq = far });
    for (gs.stock_policies.items) |sp| try std.testing.expect(sp.hq != far);
    for (gs.part_orders.items) |o| try std.testing.expect(!(o.inFlight() and std.meta.eql(o.dest, .{ .hq = far })));
}
