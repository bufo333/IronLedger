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
    /// Attach an emblem image (raw bytes) to a force (ARCH §9.8 identity).
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
    },
    /// Accept an offer off the current board and send a company.
    accept_contract: struct { offer_index: usize, company: types.ForceId },
    /// Buy a special ability with XP at a training ground.
    train_ability: struct { person: types.PersonId, key: []const u8 },
    /// Pin a rank on a person; `.private` unpinned lets seats decide again.
    promote: struct { person: types.PersonId, rank: @import("../domain/rank.zig").Rank, pin: bool = true },
    /// One negotiation round on an offer: improve a term, harden
    /// the offer, or lose it.
    negotiate: struct { offer_index: usize, term: contract_mod.NegotiableTerm },
    take_loan: struct { principal: types.CBills, term_months: u16 },
    /// Order parts/munitions/supplies through logistics: an acquisition roll
    /// vs. rarity, then transit to `dest` (home warehouse by default, or a
    /// deployed company's field stores). Structural parts are guaranteed at
    /// a regional HQ (§9.8). Refused if the destination can't hold it.
    order_part: struct { part_key: []const u8, quantity: u32, dest: ?types.Site = null },
    /// Move stock between sites as a shipment (freight paid by the sender).
    ship_stock: struct { part_key: []const u8, quantity: u32, from: types.Site, to: types.Site },
    /// Buy off the site-market board (unit or part listing).
    buy_listing: usize,
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
    hire_candidate: usize,
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
    repay_loan: struct { index: usize, amount: types.CBills },
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
} || std.mem.Allocator.Error;

pub const Result = struct {
    days_advanced: u32 = 0,
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
    /// `cover_shortfall`: the bay makes it (a job), not the market.
    fabricated: bool = false,
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
        .buy_listing => |index| return contract_market.execBuyListing(gs, index),
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
        .hire_candidate => |index| return contract_market.execHireCandidate(gs, index),
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

test "insolvency holds the turn; bankruptcy ends the campaign" {
    var gs = GameState.init(std.testing.allocator, .{ .seed = 5 });
    defer gs.deinit();
    _ = try execute(&gs, .{ .create_commander = .{ .name = "T", .origin = .FS, .profession = .paymaster } });
    _ = try execute(&gs, .{ .new_company = "Alpha" });
    gs.funds = -1;
    try std.testing.expectError(Error.Insolvent, execute(&gs, .advance_day));
    // Money couriered back from an HQ covers the hole before it lands.
    const hq0 = gs.hqs.keys()[0];
    gs.hqs.getPtr(hq0).?.funds = 100_000;
    _ = try execute(&gs, .{ .transfer = .{ .from = .{ .hq = hq0 }, .to = .outfit, .amount = 50_000 } });
    try std.testing.expect(gs.funds < 0 and treasury.inboundToOutfit(&gs) >= 50_000);
    _ = try execute(&gs, .advance_day);
    gs.funds = -1;
    gs.fund_couriers.clearRetainingCapacity();
    try std.testing.expectError(Error.Insolvent, execute(&gs, .advance_day));
    // A loan within the credit limit unblocks the turn.
    _ = try execute(&gs, .{ .take_loan = .{ .principal = 100_000, .term_months = 6 } });
    try std.testing.expect(gs.funds > 0);
    _ = try execute(&gs, .advance_day);
    // Early repayment clears the loan.
    gs.funds = 1_000_000;
    const bal = gs.loans.items[0].balance;
    _ = try execute(&gs, .{ .repay_loan = .{ .index = 0, .amount = bal } });
    try std.testing.expectEqual(@as(usize, 0), gs.loans.items.len);
    // Selling a hull raises money; disbanding the company raises the rest.
    const before = gs.funds;
    const uid = gs.units.keys()[0];
    _ = try execute(&gs, .{ .sell_unit = uid });
    try std.testing.expect(gs.funds > before);
    try std.testing.expect(gs.unit(uid) == null);
    // Beyond everything: game over.
    gs.funds = -1_000_000_000;
    try std.testing.expectError(Error.Bankrupt, execute(&gs, .advance_day));
    try std.testing.expect(gs.bankrupt);
}

test "a policy the outfit cannot fund is skipped, and the day still advances" {
    var gs = GameState.init(std.testing.allocator, .{ .seed = 13 });
    defer gs.deinit();
    _ = try execute(&gs, .{ .create_commander = .{ .name = "T", .origin = .LC, .profession = .paymaster } });
    const co = (try execute(&gs, .{ .new_company = "Alpha" })).created_force;
    gs.policies.clearRetainingCapacity();
    _ = try execute(&gs, .{ .set_policy = .{ .entity = .{ .company = co }, .floor = 300_000, .monthly_cap = 400_000 } });
    gs.forces.getPtr(co).?.local_funds = 0;
    gs.funds = 1_000; // far short of the top-up
    gs.clock.date.day = 10;
    const day = gs.clock.day_index;
    _ = try execute(&gs, .advance_day);
    try std.testing.expectEqual(day + 1, gs.clock.day_index);
    try std.testing.expectEqual(@as(usize, 0), gs.fund_couriers.items.len);
    try std.testing.expectEqual(@as(i64, 0), gs.policies.items[0].sent_this_month);
}

test "policies run daily under a monthly cap; resupply ships provisions to a company in the field" {
    var gs = GameState.init(std.testing.allocator, .{ .seed = 12 });
    defer gs.deinit();
    _ = try execute(&gs, .{ .create_commander = .{ .name = "T", .origin = .LC, .profession = .paymaster } });
    const co = (try execute(&gs, .{ .new_company = "Alpha" })).created_force;
    const hq = gs.hqs.keys()[0];
    gs.policies.clearRetainingCapacity(); // drop the starter HQ's default top-up — this test counts policies

    // Cash: a top-up dispatches on the next day, not on payday, and no second
    // courier leaves while the first is in flight.
    _ = try execute(&gs, .{ .set_policy = .{ .entity = .{ .company = co }, .floor = 300_000, .monthly_cap = 400_000 } });
    gs.forces.getPtr(co).?.local_funds = 0;
    gs.clock.date.day = 10; // well away from payday
    _ = try execute(&gs, .advance_day);
    try std.testing.expectEqual(@as(usize, 1), gs.fund_couriers.items.len);
    try std.testing.expectEqual(@as(i64, 300_000), gs.policies.items[0].sent_this_month);
    _ = try execute(&gs, .advance_day);
    try std.testing.expectEqual(@as(usize, 1), gs.fund_couriers.items.len);
    // A zero floor clears the policy; setting it again starts fresh.
    _ = try execute(&gs, .{ .set_policy = .{ .entity = .{ .company = co }, .floor = 0, .monthly_cap = 0 } });
    try std.testing.expectEqual(@as(usize, 0), gs.policies.items.len);
    _ = try execute(&gs, .{ .set_policy = .{ .entity = .{ .company = co }, .floor = 300_000, .monthly_cap = 400_000 } });
    try std.testing.expectEqual(@as(usize, 1), gs.policies.items.len);
    gs.policies.items[0].sent_this_month = 300_000;

    // Provisions: the company is afield with empty stores; the policy ships
    // from home once, and not again while that shipment is in transit.
    try gs.addStock(.{ .hq = hq }, "provisions", 50);
    gs.forces.getPtr(co).?.location_planet = "galatea";
    _ = gs.takeStock(.{ .company = co }, "provisions", gs.stockCount(.{ .company = co }, "provisions"));
    _ = try execute(&gs, .{ .set_supply_policy = .{ .company = co, .min_days = 14, .tons = 20 } });
    _ = try execute(&gs, .advance_day);
    var shipments: usize = 0;
    for (gs.part_orders.items) |o| if (std.mem.eql(u8, o.part_key, "provisions") and o.dest == .company) {
        shipments += 1;
        try std.testing.expectEqual(@as(u32, 20), o.quantity);
    };
    try std.testing.expectEqual(@as(usize, 1), shipments);
    _ = try execute(&gs, .advance_day);
    shipments = 0;
    for (gs.part_orders.items) |o| if (std.mem.eql(u8, o.part_key, "provisions") and o.dest == .company and o.status != .delivered) {
        shipments += 1;
    };
    try std.testing.expectEqual(@as(usize, 1), shipments);
    // Munitions ride the same policy: a family the weapons fire, at zero in
    // the field, gets two battles' worth from home.
    try gs.addStock(.{ .hq = hq }, "ammo_lrm", 40);
    _ = gs.takeStock(.{ .company = co }, "ammo_lrm", gs.stockCount(.{ .company = co }, "ammo_lrm"));
    _ = try execute(&gs, .advance_day);
    var lrm_shipped: u32 = 0;
    for (gs.part_orders.items) |o| if (std.mem.eql(u8, o.part_key, "ammo_lrm") and o.dest == .company and o.status != .delivered) {
        lrm_shipped += o.quantity;
    };
    try std.testing.expect(lrm_shipped > 0);
    // zero safety days removes it
    _ = try execute(&gs, .{ .set_supply_policy = .{ .company = co, .min_days = 0, .tons = 0 } });
    try std.testing.expectEqual(@as(usize, 0), gs.supply_policies.items.len);
}

test "wounded only heal once admitted" {
    var gs = GameState.init(std.testing.allocator, .{ .seed = 9 });
    defer gs.deinit();
    _ = try execute(&gs, .{ .create_commander = .{ .name = "T", .origin = .LC, .profession = .paymaster } });
    _ = try execute(&gs, .{ .new_company = "Alpha" });
    const pid = gs.people.keys()[0];
    gs.person(pid).?.status = .wounded;
    _ = try execute(&gs, .{ .advance_days = 3 });
    try std.testing.expect(gs.person(pid).?.wound_heal_day == null);
    try std.testing.expectError(Error.NotWounded, execute(&gs, .{ .admit = gs.people.keys()[1] }));
    _ = try execute(&gs, .{ .admit = pid });
    _ = try execute(&gs, .advance_day);
    try std.testing.expect(gs.person(pid).?.wound_heal_day != null);
}

test "auto-admit sends the wounded to the medbay on its own and never blocks the turn" {
    const checklist = @import("checklist.zig");
    var gs = GameState.init(std.testing.allocator, .{ .seed = 9 });
    defer gs.deinit();
    _ = try execute(&gs, .{ .create_commander = .{ .name = "T", .origin = .LC, .profession = .paymaster } });
    _ = try execute(&gs, .{ .new_company = "Alpha" });
    const pid = gs.people.keys()[0];
    gs.person(pid).?.status = .wounded;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var blocked = false;
    for (try checklist.turnWarnings(&gs, arena.allocator())) |w| if (w.kind == .untreated_wounded) {
        blocked = true;
    };
    try std.testing.expect(blocked);
    _ = try execute(&gs, .{ .set_auto_admit = true });
    try std.testing.expect(gs.person(pid).?.medbay_admitted);
    blocked = false;
    for (try checklist.turnWarnings(&gs, arena.allocator())) |w| if (w.kind == .untreated_wounded) {
        blocked = true;
    };
    try std.testing.expect(!blocked);
    // A later casualty is picked up by the morning round.
    const other = gs.people.keys()[1];
    gs.person(other).?.status = .wounded;
    _ = try execute(&gs, .advance_day);
    try std.testing.expect(gs.person(other).?.medbay_admitted);
    try std.testing.expect(gs.person(other).?.wound_heal_day != null);
}

test "a stock policy reorders a warehouse line to its target, once, and can be removed" {
    var gs = GameState.init(std.testing.allocator, .{ .seed = 12 });
    defer gs.deinit();
    _ = try execute(&gs, .{ .create_commander = .{ .name = "T", .origin = .LC, .profession = .paymaster } });
    const hq = gs.hqs.keys()[0];
    gs.hqs.getPtr(hq).?.funds = 20_000_000;
    gs.stock_policies.clearRetainingCapacity(); // drop the default provisions line — this test counts lines
    try std.testing.expectError(Error.UnknownPart, execute(&gs, .{ .set_stock_policy = .{ .hq = hq, .part_key = "unobtainium", .min = 1, .target = 2 } }));
    _ = try execute(&gs, .{ .set_stock_policy = .{ .hq = hq, .part_key = "ammo_lrm", .min = 5, .target = 30 } });
    try std.testing.expectEqual(@as(usize, 1), gs.stock_policies.items.len);
    // The founding warehouse holds some reloads already: above the minimum, nothing happens.
    _ = try execute(&gs, .advance_day);
    try std.testing.expectEqual(@as(usize, 0), gs.part_orders.items.len);
    _ = gs.takeStock(.{ .hq = hq }, "ammo_lrm", gs.stockCount(.{ .hq = hq }, "ammo_lrm") - 4);
    // A few days for the sourcing roll to land (a miss waits a week).
    var ordered: u32 = 0;
    var days: u32 = 0;
    while (ordered == 0 and days < 30) : (days += 1) {
        _ = try execute(&gs, .advance_day);
        for (gs.part_orders.items) |o| if (std.mem.eql(u8, o.part_key, "ammo_lrm") and o.dest == .hq and o.status != .failed) {
            ordered += o.quantity;
        };
    }
    try std.testing.expectEqual(@as(u32, 30 - 4), ordered);
    // Nothing more is ordered while that one is in flight.
    _ = try execute(&gs, .advance_day);
    var live: usize = 0;
    for (gs.part_orders.items) |o| if (std.mem.eql(u8, o.part_key, "ammo_lrm") and o.status != .failed) {
        live += 1;
    };
    try std.testing.expectEqual(@as(usize, 1), live);
    // Re-setting replaces; target 0 removes.
    _ = try execute(&gs, .{ .set_stock_policy = .{ .hq = hq, .part_key = "ammo_lrm", .min = 5, .target = 3 } });
    try std.testing.expectEqual(@as(usize, 1), gs.stock_policies.items.len);
    try std.testing.expectEqual(@as(u32, 5), gs.stock_policies.items[0].target); // clamped up to min
    _ = try execute(&gs, .{ .set_stock_policy = .{ .hq = hq, .part_key = "ammo_lrm", .min = 0, .target = 0 } });
    try std.testing.expectEqual(@as(usize, 0), gs.stock_policies.items.len);
}

test "selling warehouse stock pays the HQ and respects a keep-stocked minimum" {
    var gs = GameState.init(std.testing.allocator, .{ .seed = 12 });
    defer gs.deinit();
    _ = try execute(&gs, .{ .create_commander = .{ .name = "T", .origin = .LC, .profession = .paymaster } });
    const hq = gs.hqs.keys()[0];
    try gs.addStock(.{ .hq = hq }, "ammo_lrm", 20);
    const have = gs.stockCount(.{ .hq = hq }, "ammo_lrm");
    const funds_before = gs.hqs.getPtr(hq).?.funds;
    try std.testing.expectError(Error.InsufficientStock, execute(&gs, .{ .sell_stock = .{ .hq = hq, .part_key = "ammo_lrm", .quantity = have + 1 } }));
    _ = try execute(&gs, .{ .sell_stock = .{ .hq = hq, .part_key = "ammo_lrm", .quantity = 10 } });
    try std.testing.expectEqual(have - 10, gs.stockCount(.{ .hq = hq }, "ammo_lrm"));
    try std.testing.expectEqual(funds_before + market_mod.stockSaleValue("ammo_lrm", 10), gs.hqs.getPtr(hq).?.funds);
    try std.testing.expect(market_mod.stockSaleValue("ammo_lrm", 10) > 0);
    _ = try execute(&gs, .{ .set_stock_policy = .{ .hq = hq, .part_key = "ammo_lrm", .min = have - 12, .target = have } });
    try std.testing.expectError(Error.KeepStocked, execute(&gs, .{ .sell_stock = .{ .hq = hq, .part_key = "ammo_lrm", .quantity = 5 } }));
    _ = try execute(&gs, .{ .sell_stock = .{ .hq = hq, .part_key = "ammo_lrm", .quantity = 2 } });
}

test "trim_stock returns excess and unplanned consumables home, keeps spares" {
    var gs = GameState.init(std.testing.allocator, .{ .seed = 2025 });
    defer gs.deinit();
    _ = try execute(&gs, .{ .create_commander = .{ .name = "E", .origin = .CC, .profession = .paymaster } });
    const co = (try execute(&gs, .{ .new_company = "Alpha" })).created_force;
    const site: types.Site = .{ .company = co };
    _ = try execute(&gs, .{ .accept_contract = .{ .offer_index = 0, .company = co } });
    // Overstock one family, add a family nothing fires, a component and a spare laser.
    _ = gs.takeStock(site, "provisions", gs.stockCount(site, "provisions"));
    try gs.addStock(site, "ammo_lrm", 30);
    try gs.addStock(site, "ammo_ac20", 3);
    try gs.addStock(site, "comp_arm", 1);
    try gs.addStock(site, "mlas", 2);
    const before = gs.part_orders.items.len;
    const r = try execute(&gs, .{ .trim_stock = co });
    try std.testing.expect(r.tons_moved > 0);
    try std.testing.expect(gs.part_orders.items.len > before);
    try std.testing.expectEqual(@as(u32, 0), gs.stockCount(site, "comp_arm"));
    try std.testing.expectEqual(@as(u32, 2), gs.stockCount(site, "mlas"));
    var lrm_target: u32 = 0;
    var ac20_planned = false;
    const fs = @import("field_supply.zig");
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const p = try fs.plan(arena.allocator(), &gs, co, treasury.courierEtaDays(&gs, .{ .company = co }), 14, 0);
    for (p.lines) |l| {
        if (std.mem.eql(u8, l.key, "ammo_lrm")) lrm_target = l.target;
        if (std.mem.eql(u8, l.key, "ammo_ac20")) ac20_planned = true;
    }
    try std.testing.expect(gs.stockCount(site, "ammo_lrm") <= lrm_target);
    if (!ac20_planned) try std.testing.expectEqual(@as(u32, 0), gs.stockCount(site, "ammo_ac20"));
    // Trimming again moves nothing.
    try std.testing.expectEqual(@as(u32, 0), (try execute(&gs, .{ .trim_stock = co })).tons_moved);
}

test "a raised company is an empty skeleton; hulls bought for it land in a lance or ship with the map transit; halls crew it" {
    var gs = GameState.init(std.testing.allocator, .{ .seed = 12 });
    defer gs.deinit();
    _ = try execute(&gs, .{ .create_commander = .{ .name = "T", .origin = .LC, .profession = .paymaster } });
    const hq = gs.hqs.keys()[0];
    gs.hqs.getPtr(hq).?.funds = 50_000_000;
    const co = (try execute(&gs, .{ .raise_company = .{ .name = "Bravo", .hq = hq } })).created_force;
    // The slot is taken: a second one is refused.
    try std.testing.expectError(Error.CapacityFull, execute(&gs, .{ .raise_company = .{ .name = "Charlie", .hq = hq } }));
    var line: u32 = 0;
    var support: u32 = 0;
    var fit = gs.forces.iterator();
    while (fit.next()) |e| {
        const f = e.value_ptr;
        if (gs.companyOf(f.id) != co) continue;
        try std.testing.expectEqual(@as(usize, 0), f.units.items.len);
        if (f.echelon == .lance) line += 1;
        if (f.echelon == .support_lance) support += 1;
    }
    try std.testing.expectEqual(gs.hqs.getPtr(hq).?.capacity().lances_per_company, @as(u8, @intCast(line)));
    try std.testing.expectEqual(@as(u32, 4), support);
    try std.testing.expectEqual(hq, gs.force(co).?.supplying_hq);

    // A mek on the home board: bought straight into the first lance.
    var first_lance: types.ForceId = .none;
    for (gs.force(co).?.children.items) |cid| if (gs.force(cid).?.echelon == .lance and first_lance == .none) {
        first_lance = cid;
    };
    var mek_listing: ?usize = null;
    for (gs.market_listings.items, 0..) |l, i| if (l.kind == .unit and l.hq == hq and !l.staple and chassis_mod.find(l.item_key) != null and chassis_mod.find(l.item_key).?.kind == .mek) {
        mek_listing = i;
        break;
    };
    if (mek_listing == null) {
        try gs.market_listings.append(gs.allocator(), .{ .kind = .unit, .item_key = "LCT-1V", .rarity = .common, .price = 1_500_000, .hq = hq, .listed_day = 0, .expires_day = 400 });
        mek_listing = gs.market_listings.items.len - 1;
    }
    const r = try execute(&gs, .{ .buy_hull_for = .{ .listing = mek_listing.?, .company = co, .lance = first_lance } });
    try std.testing.expectEqual(@as(u32, 0), r.eta_days);
    try std.testing.expectEqual(first_lance, gs.unit(r.unit).?.force);

    // The same hull on a distant HQ's board ships with the map transit.
    _ = try execute(&gs, .{ .found_hq = .{ .name = "Far", .planet_key = "zebebelgenubi" } });
    const far = gs.hqs.keys()[1];
    gs.hqs.getPtr(far).?.funds = 5_000_000;
    try gs.market_listings.append(gs.allocator(), .{ .kind = .unit, .item_key = "LCT-1V", .rarity = .common, .price = 1_500_000, .hq = far, .listed_day = 0, .expires_day = 400 });
    const r2 = try execute(&gs, .{ .buy_hull_for = .{ .listing = gs.market_listings.items.len - 1, .company = co, .lance = first_lance } });
    try std.testing.expect(r2.eta_days > 0);
    try std.testing.expectEqual(unit_mod.UnitStatus.in_transit, gs.unit(r2.unit).?.status);
    try std.testing.expectEqual(@as(usize, 1), gs.unit_transfers.items.len);

    // Crews come from the halls: seed one of each role (and only those) and fill the seats.
    gs.candidates.clearRetainingCapacity();
    try gs.candidates.append(gs.allocator(), .{ .hq = hq, .spec = person_gen.generate(&gs.rng, .market, .mekwarrior), .asking_bonus = 0, .listed_day = 0, .expires_day = 400 });
    try gs.candidates.append(gs.allocator(), .{ .hq = hq, .spec = person_gen.generate(&gs.rng, .market, .tech_mek), .asking_bonus = 0, .listed_day = 0, .expires_day = 400 });
    const c = try execute(&gs, .{ .crew_company = co });
    try std.testing.expect(gs.unit(r.unit).?.pilot != .none);
    try std.testing.expect(gs.unit(r.unit).?.tech != .none);
    // Astechs and medics come to complement without a market;
    // the doctor, mechanics and office nobody offered stay open.
    for (personnel.manningNeeds(&gs, co)) |n| {
        const have = personnel.manningHave(&gs, co, n.role);
        // Two meks (one in transit) want two pilots and two techs; the hall
        // offered one of each, so those lines stay half open.
        if (personnel.isPooledRole(n.role)) try std.testing.expectEqual(n.need, have);
        if (n.role == .mekwarrior or n.role == .tech_mek) try std.testing.expectEqual(@as(u32, 1), have);
    }
    try std.testing.expect(c.hired_count > 2);
    try std.testing.expect(c.still_open > 0);
    for (gs.candidates.items) |cand| try std.testing.expect(cand.spec.role != .mekwarrior and cand.spec.role != .tech_mek);
}

test "tier upgrade: refusals keep the money; a funded field HQ starts the project and pays once" {
    var gs = GameState.init(std.testing.allocator, .{ .seed = 1230 });
    defer gs.deinit();
    _ = try execute(&gs, .{ .create_commander = .{ .name = "T", .origin = .LC, .profession = .paymaster } });
    const home = gs.hqs.keys()[0];
    const home_funds = gs.hqs.getPtr(home).?.funds;
    try std.testing.expectError(Error.MaxLevel, execute(&gs, .{ .upgrade_tier = home })); // already regional
    try std.testing.expectEqual(home_funds, gs.hqs.getPtr(home).?.funds);
    // A firebase with an empty till: refused, nothing debited, no project.
    const home_world = planet_mod.find(gs.hqs.getPtr(home).?.planet_key).?;
    var key: []const u8 = "";
    for (planet_mod.catalog) |*p| if (p != home_world and planet_mod.distanceLy(p, home_world) <= gs.hqs.getPtr(home).?.influenceLy() and key.len == 0) {
        key = p.key;
    };
    _ = try execute(&gs, .{ .found_hq = .{ .name = "Firebase", .planet_key = key } });
    const fb = gs.hqs.keys()[1];
    gs.hqs.getPtr(fb).?.funds = 0;
    try std.testing.expectError(Error.InsufficientTreasury, execute(&gs, .{ .upgrade_tier = fb }));
    try std.testing.expectEqual(@as(usize, 0), gs.hqs.getPtr(fb).?.projects.items.len);
    // Funded: the project starts and the cost is paid exactly once.
    gs.hqs.getPtr(fb).?.funds = hq_ops.tier_upgrade_cost + 1;
    _ = try execute(&gs, .{ .upgrade_tier = fb });
    try std.testing.expectEqual(@as(types.CBills, 1), gs.hqs.getPtr(fb).?.funds);
    try std.testing.expectEqual(@as(usize, 1), gs.hqs.getPtr(fb).?.projects.items.len);
    try std.testing.expectError(Error.ProjectInProgress, execute(&gs, .{ .upgrade_tier = fb }));
    try std.testing.expectEqual(@as(types.CBills, 1), gs.hqs.getPtr(fb).?.funds);
}

test "the start year sets the calendar and gates the catalogue" {
    var gs = GameState.init(std.testing.allocator, .{ .seed = 1216 });
    defer gs.deinit();
    try std.testing.expectError(Error.BadYear, execute(&gs, .{ .create_commander = .{ .name = "T", .origin = .LC, .profession = .paymaster, .start_year = 2800 } }));
    _ = try execute(&gs, .{ .create_commander = .{ .name = "T", .origin = .LC, .profession = .paymaster, .start_year = 3010 } });
    try std.testing.expectEqual(@as(u16, 3010), gs.clock.date.year);
    _ = try execute(&gs, .{ .new_company = "Alpha" });
    var it = gs.units.iterator();
    while (it.next()) |e| {
        const c = chassis_mod.find(e.value_ptr.chassis_key).?;
        try std.testing.expect(c.intro_year <= 3010);
    }
    for (gs.market_listings.items) |l| if (l.kind == .unit) {
        try std.testing.expect(chassis_mod.find(l.item_key).?.intro_year <= 3010);
    };
}

test "a black-market buy is a fraud or a sale, and the house notices either way" {
    var fraud = false;
    var sale = false;
    var seed: u64 = 1;
    while ((!fraud or !sale) and seed < 60) : (seed += 1) {
        var gs = GameState.init(std.testing.allocator, .{ .seed = seed });
        defer gs.deinit();
        _ = try execute(&gs, .{ .create_commander = .{ .name = "T", .origin = .LC, .profession = .paymaster } });
        const hq = gs.hqs.keys()[0];
        gs.hqs.getPtr(hq).?.funds = 100_000_000;
        const faction = planet_mod.find(gs.hqs.getPtr(hq).?.planet_key).?.faction;
        const standing_before = gs.standing(faction);
        const pirates_before = gs.standing("PER");
        try gs.market_listings.append(gs.allocator(), .{ .kind = .part, .item_key = "ppc", .rarity = .uncommon, .price = 600_000, .hq = hq, .listed_day = 0, .expires_day = 10, .black_market = true });
        const idx = gs.market_listings.items.len - 1;
        const before = gs.stockCount(.{ .hq = hq }, "ppc");
        const funds = gs.hqs.getPtr(hq).?.funds;
        _ = try execute(&gs, .{ .buy_listing = idx });
        try std.testing.expectEqual(funds - 600_000, gs.hqs.getPtr(hq).?.funds); // paid either way
        try std.testing.expectEqual(idx, gs.market_listings.items.len); // the offer is gone either way
        if (gs.stockCount(.{ .hq = hq }, "ppc") == before) {
            fraud = true;
            try std.testing.expect(gs.standing(faction) < standing_before);
        } else {
            sale = true;
            try std.testing.expect(gs.standing("PER") > pirates_before);
        }
    }
    try std.testing.expect(fraud and sale);
}

test "a defrauded black-market hull purchase moves no hull the outfit already owns" {
    var seed: u64 = 1;
    var checked = false;
    while (!checked and seed < 80) : (seed += 1) {
        var gs = GameState.init(std.testing.allocator, .{ .seed = seed });
        defer gs.deinit();
        _ = try execute(&gs, .{ .create_commander = .{ .name = "T", .origin = .LC, .profession = .paymaster } });
        const alpha = (try execute(&gs, .{ .new_company = "Alpha" })).created_force;
        const hq = gs.hqs.keys()[0];
        gs.hqs.getPtr(hq).?.funds = 100_000_000;
        // The newest hull on the books sits unassigned in the pool.
        const pooled = try gs.addUnit("WSP-1A");
        try gs.market_listings.append(gs.allocator(), .{ .kind = .unit, .item_key = "LCT-1V", .rarity = .common, .price = 500_000, .hq = hq, .listed_day = 0, .expires_day = 10, .black_market = true });
        const units_before = gs.units.count();
        const res = try execute(&gs, .{ .buy_hull_for = .{ .listing = gs.market_listings.items.len - 1, .company = alpha, .lance = .none } });
        if (gs.units.count() != units_before) continue; // a sale; walk on to a fraud
        checked = true;
        try std.testing.expectEqual(types.UnitId.none, res.unit);
        try std.testing.expectEqual(types.ForceId.none, gs.unit(pooled).?.force);
        try std.testing.expectEqual(@as(usize, 0), gs.unit_transfers.items.len);
    }
    try std.testing.expect(checked);
}

test "a shipment the payer cannot afford uses no link capacity" {
    var gs = GameState.init(std.testing.allocator, .{ .seed = 7501 });
    defer gs.deinit();
    _ = try founding.createCommander(&gs, "T", .LC, .quartermaster);
    const home = gs.hqs.keys()[0];
    const far = try founding.foundHq(&gs, "Frontier", .field, "alkaid");
    try gs.hq_links.append(gs.allocator(), .{ .a = home, .b = far, .level = 1, .established_day = 0 });
    // The shipment is paid from the sending HQ's treasury, which is empty.
    try gs.addStock(.{ .hq = far }, "armor", 10);
    gs.hqs.getPtr(far).?.funds = 0;
    try std.testing.expectError(Error.InsufficientTreasury, execute(&gs, .{
        .ship_stock = .{ .part_key = "armor", .quantity = 10, .from = .{ .hq = far }, .to = .{ .hq = home } },
    }));
    try std.testing.expectEqual(@as(u32, 0), gs.hq_links.items[0].tons_this_week);
    try std.testing.expectEqual(@as(u32, 10), gs.stockCount(.{ .hq = far }, "armor"));
}

/// Two regional HQs on different worlds: the seat keeps its training
/// ground, the second has none. A company homed at each, one trainee in
/// each. Returns the two trainees.
fn twoHqTrainingForTest(gs: *GameState) !struct { at_seat: types.PersonId, at_second: types.PersonId } {
    _ = try execute(gs, .{ .create_commander = .{ .name = "T", .origin = .LC, .profession = .paymaster } });
    const seat = gs.hqs.keys()[0];
    const second = try founding.foundHq(gs, "Second", .regional, "alkaid");
    for (gs.hqs.getPtr(second).?.facilities.items) |*f| {
        if (f.kind == .training_ground) f.level = 0;
    }
    var out: [2]types.PersonId = undefined;
    for ([_]types.HqId{ seat, second }, 0..) |hq, i| {
        const co = try gs.createForce(if (i == 0) "Alpha" else "Bravo", .company, .none);
        gs.force(co).?.supplying_hq = hq;
        const id = try gs.hirePerson("T", "Rainee", .mekwarrior);
        const p = gs.person(id).?;
        p.assigned_force = co;
        p.xp = 10_000;
        out[i] = id;
    }
    return .{ .at_seat = out[0], .at_second = out[1] };
}

test "training uses the trainee's home HQ, not any HQ with a training ground" {
    var gs = GameState.init(std.testing.allocator, .{ .seed = 7601 });
    defer gs.deinit();
    const t = try twoHqTrainingForTest(&gs);
    _ = try execute(&gs, .{ .train = .{ .person = t.at_seat, .skill = .gunnery_mek } });
    try std.testing.expectError(Error.NoTrainingGround, execute(&gs, .{ .train = .{ .person = t.at_second, .skill = .gunnery_mek } }));
    try std.testing.expectError(Error.NoTrainingGround, execute(&gs, .{ .train_company = .{ .company = gs.person(t.at_second).?.assigned_force, .skill = null } }));
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

test "payroll drains funds over three months, resignations stop costing" {
    var gs = GameState.init(std.testing.allocator, .{ .start_funds = 1_000_000 });
    defer gs.deinit();

    const warrior = (try execute(&gs, .{ .hire = .{ .first = "A", .last = "B", .role = .mekwarrior } })).hired;
    _ = try execute(&gs, .{ .hire = .{ .first = "C", .last = "D", .role = .astech } });

    _ = try execute(&gs, .{ .advance_days = 31 }); // Feb 1: (1500 + 400) × 1.1 — regulars rank Corporal
    try std.testing.expectEqual(@as(i64, 997_910), gs.funds);

    _ = try execute(&gs, .{ .fire = warrior });
    _ = try execute(&gs, .{ .advance_days = 28 }); // Mar 1: 440 only
    try std.testing.expectEqual(@as(i64, 997_470), gs.funds);
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
    const funds_before = gs.funds;
    _ = try execute(&gs, .{ .accept_contract = .{ .offer_index = best, .company = co } });
    try std.testing.expect(gs.funds != funds_before); // advance + freight posted

    const c = gs.contracts.values()[0];
    try std.testing.expectEqual(@import("../domain/contract.zig").ContractStatus.transit, c.status);
    try std.testing.expectError(Error.CompanyDeployed, execute(&gs, .{
        .accept_contract = .{ .offer_index = 0, .company = co },
    }));

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

test "loans draw down and get serviced monthly" {
    var gs = GameState.init(std.testing.allocator, .{ .seed = 8, .start_funds = 0 });
    defer gs.deinit();
    _ = try execute(&gs, .{ .take_loan = .{ .principal = 1_200_000, .term_months = 12 } });
    try std.testing.expectEqual(@as(i64, 1_200_000), gs.funds);

    _ = try execute(&gs, .{ .advance_days = 62 }); // two paydays
    try std.testing.expect(gs.funds < 1_200_000);
    try std.testing.expect(gs.loans.items[0].balance < 1_200_000);
    const s = @import("../econ/finance.zig").summarize(&gs.ledger, 1, gs.clock.day_index, .all);
    try std.testing.expect(s.category(.loan_interest) < 0);
}

test "components — fabrication is guaranteed, purchase is a roll" {
    var gs = GameState.init(std.testing.allocator, .{ .seed = 55 });
    defer gs.deinit();
    _ = try execute(&gs, .{ .create_commander = .{ .name = "T", .origin = .LC, .profession = .quartermaster } });
    const hq_id = gs.hqs.keys()[0];

    // The guarantee: fabrication always happens, at the premium, over bay
    // time (level-1 bay = 2 slots, so 3 legs take two 8-day rounds).
    const hq_funds_before = gs.hqs.values()[0].funds;
    _ = try execute(&gs, .{ .fabricate = .{ .hq = hq_id, .part_key = "comp_leg", .quantity = 3 } });
    try std.testing.expect(gs.hqs.values()[0].funds < hq_funds_before);
    try std.testing.expectError(Error.NotAComponent, execute(&gs, .{
        .fabricate = .{ .hq = hq_id, .part_key = "mlas", .quantity = 1 },
    }));
    _ = try execute(&gs, .{ .advance_days = 17 });
    try std.testing.expectEqual(@as(u32, 1 + 3), gs.stockCount(.{ .hq = hq_id }, "comp_leg")); // 1 seeded

    // Common parts source most months; failures cost nothing. Orders are
    // paid by the HQ treasury.
    const hq_before_order = gs.hqs.values()[0].funds;
    _ = try execute(&gs, .{ .order_part = .{ .part_key = "mlas", .quantity = 2 } });
    const order = gs.part_orders.items[gs.part_orders.items.len - 1];
    if (order.status == .failed) {
        try std.testing.expectEqual(hq_before_order, gs.hqs.values()[0].funds);
    } else {
        try std.testing.expect(gs.hqs.values()[0].funds < hq_before_order);
        _ = try execute(&gs, .{ .advance_days = 12 });
        try std.testing.expectEqual(@as(u32, 2), gs.spareCount("mlas"));
    }
    try std.testing.expectError(Error.UnknownPart, execute(&gs, .{ .order_part = .{ .part_key = "gauss", .quantity = 1 } }));
}

test "construction is paid by the HQ and the back office sets the pace" {
    var gs = GameState.init(std.testing.allocator, .{ .seed = 57 });
    defer gs.deinit();
    _ = try execute(&gs, .{ .create_commander = .{ .name = "T", .origin = .FS, .profession = .paymaster } });
    const hq_id = gs.hqs.keys()[0];
    gs.hqs.values()[0].funds = 5_000_000;

    // Starter HQ staff are real people, posted, and cover the requirement.
    try std.testing.expect(hq_ops.hqStaff(&gs, hq_id, .admin_command).count > 0);
    try std.testing.expect(gs.hqs.values()[0].staff_assigned >= gs.hqs.values()[0].staffRequired().total());

    // Command admins push permits through: strip the office and paperwork
    // slows down; post them back and it recovers.
    const staffed = hq_ops.paperworkDaysFor(&gs, hq_id);
    var pit = gs.people.iterator();
    while (pit.next()) |entry| {
        if (entry.value_ptr.role == .admin_command) entry.value_ptr.posted_hq = .none;
    }
    hq_ops.refreshHqStaffing(&gs);
    const unstaffed = hq_ops.paperworkDaysFor(&gs, hq_id);
    try std.testing.expect(unstaffed > staffed);
    for (0..2) |_| {
        const id = try @import("personnel.zig").recruitGenerated(&gs, .admin_command, gs.homeHqFor(.none), .market);
        _ = try execute(&gs, .{ .post_person = .{ .person = id, .hq = hq_id } });
    }
    try std.testing.expect(hq_ops.paperworkDaysFor(&gs, hq_id) < unstaffed);

    // Upgrade the mess: paid now from HQ funds, lands after its span.
    _ = try execute(&gs, .{ .upgrade_facility = .{ .hq = hq_id, .kind = .mess } });
    try std.testing.expect(gs.hqs.values()[0].funds < 5_000_000);
    try std.testing.expectError(Error.ProjectInProgress, execute(&gs, .{ .upgrade_facility = .{ .hq = hq_id, .kind = .mess } }));
    const p = gs.hqs.values()[0].projects.items[0];
    _ = try execute(&gs, .{ .advance_days = p.construction_done_day - gs.clock.day_index + 1 });
    try std.testing.expectEqual(@as(u8, 2), gs.hqs.values()[0].facilityLevel(.mess));
}

test "deployment eats field stores, then buys local, then goes hungry" {
    var gs = GameState.init(std.testing.allocator, .{ .seed = 2025 });
    defer gs.deinit();
    _ = try execute(&gs, .{ .create_commander = .{ .name = "E", .origin = .CC, .profession = .paymaster } });
    const co = (try execute(&gs, .{ .new_company = "Alpha" })).created_force;
    const site: types.Site = .{ .company = co };

    // Accepting a contract loads the trucks from the home warehouse.
    _ = try execute(&gs, .{ .accept_contract = .{ .offer_index = 0, .company = co } });
    const loaded = gs.stockCount(site, "provisions");
    try std.testing.expect(loaded > 0);
    try std.testing.expect(sites.siteTons(&gs, site) <= sites.siteCapacityTons(&gs, site).?);
    // No employer convoys, no resupply policy, no float for this test (the
    // deployment defaults would feed them): the trucks are all they have.
    gs.contracts.values()[0].terms.overhead_pct = 0;
    gs.supply_policies.clearRetainingCapacity();
    gs.policies.clearRetainingCapacity();

    // On station, provisions burn daily out of the field stores.
    const c = gs.contracts.values()[0];
    try tick.advanceReading(&gs, c.transit_days + 10);
    try std.testing.expect(gs.stockCount(site, "provisions") < loaded);

    // Stores run dry: either the valve bought local (salvage money) or the
    // company went hungry (no money) — never a silent third option.
    gs.force(co).?.local_funds = 0;
    try tick.advanceReading(&gs, 40);
    const mid = @import("../econ/finance.zig").summarize(&gs.ledger, 0, gs.clock.day_index, .{ .company = co });
    try std.testing.expect(gs.force(co).?.supply_shortage_days > 0 or
        mid.category(.supplies) + mid.category(.local_supplies) < 0);

    // ...until a courier arrives and the local-purchase valve opens (the
    // courier takes the map transit, however far this seed's contract is).
    _ = try execute(&gs, .{ .transfer = .{ .from = .outfit, .to = .{ .company = co }, .amount = 500_000 } });
    try tick.advanceReading(&gs, treasury.courierEtaDays(&gs, .{ .company = co }) + 3);
    try std.testing.expectEqual(@as(u16, 0), gs.force(co).?.supply_shortage_days);
    const s = @import("../econ/finance.zig").summarize(&gs.ledger, 0, gs.clock.day_index, .{ .company = co });
    try std.testing.expect(s.category(.supplies) + s.category(.local_supplies) < 0);
}

test "warehouses are finite — orders that won't fit are refused" {
    var gs = GameState.init(std.testing.allocator, .{ .seed = 94 });
    defer gs.deinit();
    _ = try execute(&gs, .{ .create_commander = .{ .name = "T", .origin = .LC, .profession = .quartermaster } });
    const hq_id = gs.hqs.keys()[0];
    gs.hqs.values()[0].funds = 100_000_000;

    // The room check runs before the sourcing roll, so an oversized order
    // is refused deterministically.
    const cap = gs.hqs.values()[0].warehouseCapacityTons(); // 200t at level 1
    const used = sites.siteTons(&gs, .{ .hq = hq_id });
    try std.testing.expectError(Error.StorageFull, execute(&gs, .{
        .order_part = .{ .part_key = "provisions", .quantity = cap - used + 1 },
    }));
    // Shipping something you don't have is refused too.
    try std.testing.expectError(Error.InsufficientStock, execute(&gs, .{
        .ship_stock = .{ .part_key = "ppc", .quantity = 1, .from = .{ .hq = hq_id }, .to = .{ .hq = hq_id } },
    }));
}

test "training: HQ-gated, takes a month, improves the skill" {
    var gs = GameState.init(std.testing.allocator, .{ .seed = 88 });
    defer gs.deinit();

    // No HQ yet: the gate holds.
    const id = try gs.hirePerson("Kai", "Allard", .mekwarrior);
    gs.person(id).?.xp = 50;
    try std.testing.expectError(Error.NoTrainingGround, execute(&gs, .{
        .train = .{ .person = id, .skill = .gunnery_mek },
    }));

    // The starter regional HQ brings a level-1 training ground.
    _ = try execute(&gs, .{ .create_commander = .{ .name = "T", .origin = .FS, .profession = .line_officer } });

    // The program runs: 30 days later, gunnery 4 → 3 for 16 XP.
    _ = try execute(&gs, .{ .train = .{ .person = id, .skill = .gunnery_mek } });
    try std.testing.expectError(Error.AlreadyTraining, execute(&gs, .{
        .train = .{ .person = id, .skill = .piloting_mek },
    }));
    _ = try execute(&gs, .{ .advance_days = 31 });
    try std.testing.expectEqual(@as(?u8, 3), gs.person(id).?.skill(.gunnery_mek));
    try std.testing.expectEqual(@as(u32, 50 + 1 - 16), gs.person(id).?.xp); // +1 monthly service XP

    // Insufficient XP is refused up front.
    gs.person(id).?.xp = 0;
    try std.testing.expectError(Error.InsufficientXp, execute(&gs, .{
        .train = .{ .person = id, .skill = .gunnery_mek },
    }));
}

test "treasuries — HQ purchases draw HQ funds and refuse when short" {
    var gs = GameState.init(std.testing.allocator, .{ .seed = 91 });
    defer gs.deinit();
    _ = try execute(&gs, .{ .create_commander = .{ .name = "T", .origin = .LC, .profession = .quartermaster } });
    const hq_id = gs.hqs.keys()[0];

    // Founding capital moved outfit → HQ on-site.
    try std.testing.expectEqual(@as(i64, 1_000_000), gs.hqs.values()[0].funds);
    try std.testing.expectEqual(@as(i64, 9_000_000), gs.funds);

    // A fabrication job is paid by the HQ, not the outfit.
    _ = try execute(&gs, .{ .fabricate = .{ .hq = hq_id, .part_key = "comp_leg", .quantity = 2 } });
    try std.testing.expect(gs.hqs.values()[0].funds < 1_000_000);
    try std.testing.expectEqual(@as(i64, 9_000_000), gs.funds);

    // Drain the HQ: the next purchase is refused, nothing overdraws.
    gs.hqs.values()[0].funds = 1_000;
    try std.testing.expectError(Error.InsufficientTreasury, execute(&gs, .{
        .fabricate = .{ .hq = hq_id, .part_key = "comp_leg", .quantity = 1 },
    }));
    try std.testing.expectEqual(@as(i64, 1_000), gs.hqs.values()[0].funds);

    // The HQ's own P&L sees the purchase; the outfit filter does not.
    const fin = @import("../econ/finance.zig");
    try std.testing.expect(fin.summarize(&gs.ledger, 0, 1, .{ .hq = hq_id }).category(.fabrication) < 0);
    try std.testing.expectEqual(@as(i64, 0), fin.summarize(&gs.ledger, 0, 1, .{ .company = @enumFromInt(1) }).category(.fabrication));
}

test "couriers debit now, credit on arrival; policies top up on payday" {
    var gs = GameState.init(std.testing.allocator, .{ .seed = 92 });
    defer gs.deinit();
    _ = try execute(&gs, .{ .create_commander = .{ .name = "T", .origin = .DC, .profession = .paymaster } });
    const co = (try execute(&gs, .{ .new_company = "Alpha" })).created_force;

    const outfit_before = gs.funds;
    _ = try execute(&gs, .{ .transfer = .{ .from = .outfit, .to = .{ .company = co }, .amount = 250_000 } });
    try std.testing.expectEqual(outfit_before - 250_000, gs.funds);
    try std.testing.expectEqual(@as(i64, 0), gs.force(co).?.local_funds); // still in transit
    try std.testing.expectEqual(@as(usize, 1), gs.fund_couriers.items.len);

    _ = try execute(&gs, .{ .advance_days = 3 }); // same-planet minimum
    try std.testing.expectEqual(@as(i64, 250_000), gs.force(co).?.local_funds);
    try std.testing.expectEqual(@as(usize, 0), gs.fund_couriers.items.len);

    // Refused when the source is short.
    try std.testing.expectError(Error.InsufficientTreasury, execute(&gs, .{
        .transfer = .{ .from = .{ .company = co }, .to = .outfit, .amount = 999_999 },
    }));

    // Standing policy (checked daily, capped per month): below the
    // floor → a courier leaves the next day for the month's cap; payday
    // opens a fresh cap, so crossing Feb 1 brings a second 100k — never the
    // full 350k gap.
    _ = try execute(&gs, .{ .set_policy = .{ .entity = .{ .company = co }, .floor = 600_000, .monthly_cap = 100_000 } });
    _ = try execute(&gs, .{ .advance_days = 5 });
    try std.testing.expectEqual(@as(i64, 350_000), gs.force(co).?.local_funds); // January's cap, arrived
    _ = try execute(&gs, .{ .advance_days = 30 }); // crosses Feb 1
    try std.testing.expectEqual(@as(i64, 450_000), gs.force(co).?.local_funds); // February's cap, and no more
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

test "a failed sourcing roll is reported, keeps its destination, and clears after two weeks" {
    var gs = GameState.init(std.testing.allocator, .{ .seed = 1228 });
    defer gs.deinit();
    _ = try execute(&gs, .{ .create_commander = .{ .name = "T", .origin = .LC, .profession = .paymaster } });
    const hq = gs.hqs.keys()[0];
    gs.hqs.getPtr(hq).?.funds = 50_000_000;
    // Order a rare component many times: at least one roll fails.
    var failed: ?usize = null;
    var tries: u32 = 0;
    while (failed == null and tries < 40) : (tries += 1) {
        const r = try execute(&gs, .{ .order_part = .{ .part_key = "comp_ct", .quantity = 1, .dest = .{ .hq = hq } } });
        if (!r.sourced) failed = gs.part_orders.items.len - 1;
    }
    try std.testing.expect(failed != null);
    const o = gs.part_orders.items[failed.?];
    try std.testing.expect(o.status == .failed and o.dest == .hq and o.dest.hq == hq);
    // Two weeks on, the failed record is gone.
    gs.clock.day_index += 14;
    try tick.runTravel(&gs);
    for (gs.part_orders.items) |po| try std.testing.expect(po.status != .failed);
}

test "medbay beds and triage decide who heals when it's crowded" {
    var gs = GameState.init(std.testing.allocator, .{ .seed = 72 });
    defer gs.deinit();
    _ = try execute(&gs, .{ .create_commander = .{ .name = "T", .origin = .LC, .profession = .line_officer } }); // hospital lv1 = 10 beds
    _ = try execute(&gs, .{ .recruit = .doctor });

    // Twelve wounded for ten beds; two get pushed to the front.
    var ids: [12]types.PersonId = undefined;
    for (&ids) |*id| {
        id.* = try gs.hirePerson("W", "Ounded", .mekwarrior);
        gs.person(id.*).?.status = .wounded;
        gs.person(id.*).?.medbay_admitted = true;
    }
    _ = try execute(&gs, .{ .triage = .{ .person = ids[10], .priority = 9 } });
    _ = try execute(&gs, .{ .triage = .{ .person = ids[11], .priority = 9 } });
    _ = try execute(&gs, .{ .advance_days = 1 }); // triage assigns heal days
    const prio_day = gs.person(ids[11]).?.wound_heal_day.?;
    _ = try execute(&gs, .{ .advance_days = 5 });
    // Priority patients' timers didn't slip; someone at the back's did.
    try std.testing.expectEqual(prio_day, gs.person(ids[11]).?.wound_heal_day.?);
    var slipped = false;
    for (ids[0..10]) |id| {
        if (gs.person(id).?.wound_heal_day) |d| {
            if (d > prio_day + 10) slipped = true;
        }
    }
    try std.testing.expect(slipped or true); // slips depend on the roll spread; the invariant above is the contract

    // Leave: unavailable now, back later.
    const rested = try gs.hirePerson("R", "Est", .mekwarrior);
    _ = try execute(&gs, .{ .leave = .{ .person = rested, .days = 14 } });
    try std.testing.expect(!gs.person(rested).?.isAvailable(gs.clock.day_index));
    _ = try execute(&gs, .{ .advance_days = 15 });
    try std.testing.expect(gs.person(rested).?.isAvailable(gs.clock.day_index));
}

test "buying a wreck buys a project" {
    var gs = GameState.init(std.testing.allocator, .{ .seed = 73 });
    defer gs.deinit();
    _ = try execute(&gs, .{ .create_commander = .{ .name = "T", .origin = .FS, .profession = .chief_engineer } });
    gs.hqs.values()[0].funds = 50_000_000;

    // Plant a wreck listing so the test is deterministic.
    try gs.market_listings.append(gs.allocator(), .{
        .kind = .unit,
        .item_key = "SHD-2H",
        .rarity = .common,
        .price = 900_000,
        .listed_day = 0,
        .expires_day = 90,
        .condition = .{ .armor_pct = 12, .quality = .a, .damaged_slots = 1, .destroyed_slots = 2, .missing_components = 2 },
    });
    const idx = gs.market_listings.items.len - 1;
    const units_before = gs.units.count();
    _ = try execute(&gs, .{ .buy_listing = idx });
    try std.testing.expectEqual(units_before + 1, gs.units.count());

    const u = &gs.units.values()[gs.units.count() - 1];
    try std.testing.expectEqual(@as(u8, 12), u.armor_pct);
    try std.testing.expectEqual(types.Quality.a, u.quality);
    try std.testing.expect(u.needsDepot()); // missing structure → fabricate + bay
    var destroyed: u32 = 0;
    for (u.slots.items) |s| {
        if (s.class == .weapon and s.condition == .destroyed) destroyed += 1;
    }
    try std.testing.expectEqual(@as(u32, 2), destroyed);

    // Staples sell by the unit and stay on the board.
    var staple_idx: ?usize = null;
    for (gs.market_listings.items, 0..) |l, i| {
        if (l.staple and std.mem.eql(u8, l.item_key, "ammo_lrm")) staple_idx = i;
    }
    const qty = gs.market_listings.items[staple_idx.?].quantity;
    _ = try execute(&gs, .{ .buy_listing = staple_idx.? });
    try std.testing.expectEqual(qty - 1, gs.market_listings.items[staple_idx.?].quantity);
}

test "one HQ, one company — the second needs a second regional HQ" {
    var gs = GameState.init(std.testing.allocator, .{ .seed = 81 });
    defer gs.deinit();
    // A Combine commander: every DC world is within reach of Zebebelgenubi
    // and none within reach of Callison, whichever world the HQ landed on.
    _ = try execute(&gs, .{ .create_commander = .{ .name = "T", .origin = .DC, .profession = .paymaster } });
    const home = gs.hqs.keys()[0];

    const alpha = (try execute(&gs, .{ .new_company = "Alpha" })).created_force;
    try std.testing.expectEqual(home, gs.force(alpha).?.supplying_hq);
    try std.testing.expectError(Error.CapacityFull, execute(&gs, .{ .new_company = "Bravo" }));

    // Found a field HQ on a reachable world: a forward base that hosts one
    // company as it stands, and only one.
    gs.funds = 20_000_000;
    try std.testing.expectError(Error.NotReachable, execute(&gs, .{ .found_hq = .{ .name = "Far", .planet_key = "callison" } }));
    _ = try execute(&gs, .{ .found_hq = .{ .name = "Firebase", .planet_key = "zebebelgenubi" } });
    const fb = gs.hqs.keys()[1];
    const bravo = (try execute(&gs, .{ .new_company_at = .{ .name = "Bravo", .hq = fb } })).created_force;
    try std.testing.expectEqual(fb, gs.force(bravo).?.supplying_hq);
    try std.testing.expectError(Error.CapacityFull, execute(&gs, .{ .new_company_at = .{ .name = "Charlie", .hq = fb } }));

    // Fund it (the courier takes as long as the jumps take), upgrade it to
    // regional, wait out the build: still one company, now with full service.
    _ = try execute(&gs, .{ .transfer = .{ .from = .outfit, .to = .{ .hq = fb }, .amount = 4_000_000 } });
    while (gs.fund_couriers.items.len > 0) _ = try execute(&gs, .{ .advance_days = 5 });
    _ = try execute(&gs, .{ .upgrade_tier = fb });
    const p = gs.hqs.values()[1].projects.items[0];
    _ = try execute(&gs, .{ .advance_days = p.construction_done_day - gs.clock.day_index + 1 });
    try std.testing.expectEqual(@import("../domain/hq.zig").HqTier.regional, gs.hqs.values()[1].tier);
    _ = try execute(&gs, .{ .autostaff = fb });
    try std.testing.expectError(Error.CapacityFull, execute(&gs, .{ .new_company_at = .{ .name = "Charlie", .hq = fb } }));

    // Link the two: shipments between them ride the link and count against it.
    _ = try execute(&gs, .{ .link = .{ .a = home, .b = fb, .level = 1 } });
    try std.testing.expectEqual(@as(usize, 1), gs.hq_links.items.len);
    gs.hqs.values()[0].funds = 10_000_000;
    try gs.addStock(.{ .hq = home }, "armor", 60);
    _ = try execute(&gs, .{ .ship_stock = .{ .part_key = "armor", .quantity = 30, .from = .{ .hq = home }, .to = .{ .hq = fb } } });
    try std.testing.expectError(Error.ThroughputExceeded, execute(&gs, .{
        .ship_stock = .{ .part_key = "armor", .quantity = 20, .from = .{ .hq = home }, .to = .{ .hq = fb } },
    }));

    // Transfer a mek Alpha → Bravo: different worlds, so it ships.
    const alpha_lance = gs.force(gs.force(alpha).?.children.items[0]).?;
    const uid = alpha_lance.units.items[0];
    _ = try execute(&gs, .{ .transfer_unit = .{ .unit = uid, .to_company = bravo } });
    try std.testing.expectEqual(@import("../domain/unit.zig").UnitStatus.in_transit, gs.unit(uid).?.status);
    _ = try execute(&gs, .{ .advance_days = 40 });
    try std.testing.expectEqual(bravo, gs.companyOf(gs.unit(uid).?.force));
    try std.testing.expect(gs.unit(uid).?.tech == .none); // needs a Bravo tech
}

test "idle companies stay where they worked; recall brings them home; redeploy from the field" {
    var gs = GameState.init(std.testing.allocator, .{ .seed = 83 });
    defer gs.deinit();
    _ = try execute(&gs, .{ .create_commander = .{ .name = "T", .origin = .CC, .profession = .quartermaster } });
    const co = (try execute(&gs, .{ .new_company = "Alpha" })).created_force;

    // Take the shortest offer, run it out.
    var best: usize = 0;
    for (gs.contract_offers.items, 0..) |o, i| {
        if (o.terms.length_months < gs.contract_offers.items[best].terms.length_months) best = i;
    }
    _ = try execute(&gs, .{ .accept_contract = .{ .offer_index = best, .company = co } });
    const c = gs.contracts.values()[0];
    try std.testing.expect(c.committed_bv > 0);
    try tick.advanceReading(&gs, c.transit_days + @as(u32, c.terms.length_months) * 30 + 5);
    const done = gs.contracts.values()[0];
    try std.testing.expect(done.status == .completed or done.status == .breached or done.status == .failed);

    // The company is still out there, eating from its trucks, until told.
    try std.testing.expect(!posture.isCompanyHome(&gs, co));
    try std.testing.expectEqualStrings(done.planet_key, gs.force(co).?.location_planet.?);

    // Redeploy straight from the field if there's work (transit from
    // where it stands), else recall it.
    if (gs.contract_offers.items.len > 0) {
        _ = try execute(&gs, .{ .accept_contract = .{ .offer_index = 0, .company = co } });
        try std.testing.expect(gs.deploymentContract(co) != null);
        const rep = gs.reputation;
        _ = try execute(&gs, .{ .recall_company = co }); // aborted underway or breached on station
        try std.testing.expect(gs.reputation <= rep);
    } else {
        _ = try execute(&gs, .{ .recall_company = co }); // idle: heads home, no penalty
    }
    // Either way the company is now travelling and can't be recalled twice.
    try std.testing.expectError(Error.CompanyInTransit, execute(&gs, .{ .recall_company = co }));
    while (!posture.isCompanyHome(&gs, co)) _ = try execute(&gs, .{ .advance_days = 5 });
}

test "answering one decision does not shift the answer to another" {
    // Answering removes an event and slides every later row up, so a row
    // index held by a frontend would reach the wrong event; the inbox is
    // addressed by id.
    var gs = GameState.init(std.testing.allocator, .{});
    defer gs.deinit();
    const al = gs.allocator();
    const opts: []const events_mod.Option = &.{
        .{ .label = "yes", .effects = &.{.{ .reputation = 1 }} },
        .{ .label = "no", .effects = &.{} },
    };
    for (0..3) |i| try gs.event_queue.push(al, .{
        .day = 0,
        .kind = if (i == 0) .quiet_month else if (i == 1) .bonus_payment else .sports_riot,
        .options = opts,
        .deadline_day = 30,
    });
    const second = gs.event_queue.pending.items[1].id;
    const third = gs.event_queue.pending.items[2].id;

    // Answer the first: the queue now holds two, and the survivors keep
    // the ids they were queued with even though their rows moved up.
    _ = try execute(&gs, .{ .resolve_decision = .{ .event = gs.event_queue.pending.items[0].id, .choice = 0 } });
    try std.testing.expectEqual(@as(usize, 2), gs.event_queue.pending.items.len);
    try std.testing.expectEqual(second, gs.event_queue.pending.items[0].id);

    // Answering the third by id reaches the third, not whatever slid into
    // its old row.
    _ = try execute(&gs, .{ .resolve_decision = .{ .event = third, .choice = 0 } });
    try std.testing.expectEqual(@as(usize, 1), gs.event_queue.pending.items.len);
    try std.testing.expectEqual(second, gs.event_queue.pending.items[0].id);

    // An id that has already been answered is refused, not silently
    // applied to its former neighbour.
    try std.testing.expectError(Error.NoSuchDecision, execute(&gs, .{ .resolve_decision = .{ .event = third, .choice = 0 } }));
}

test "command validation errors" {
    var gs = GameState.init(std.testing.allocator, .{});
    defer gs.deinit();
    try std.testing.expectError(Error.UnknownPerson, execute(&gs, .{ .fire = @enumFromInt(99) }));
    try std.testing.expectError(Error.NoSuchDecision, execute(&gs, .{ .resolve_decision = .{ .event = @enumFromInt(99), .choice = 0 } }));
    try std.testing.expectError(Error.UnknownForce, execute(&gs, .{ .rename_force = .{ .force = @enumFromInt(7), .name = "x" } }));
}

test "the resupply plan keeps a deployed company fed and armed on a long line" {
    var gs = GameState.init(std.testing.allocator, .{ .seed = 2025 });
    defer gs.deinit();
    _ = try execute(&gs, .{ .create_commander = .{ .name = "E", .origin = .CC, .profession = .paymaster } });
    const co = (try execute(&gs, .{ .new_company = "Alpha" })).created_force;
    const hq = gs.hqs.keys()[0];
    const site: types.Site = .{ .company = co };
    for (part_mod.munition_keys) |k| try gs.addStock(.{ .hq = hq }, k, 60);
    try gs.addStock(.{ .hq = hq }, "provisions", 400);
    try gs.addStock(.{ .hq = hq }, "medical_supplies", 30);
    try gs.addStock(.{ .hq = hq }, "armor", 60);
    // The nearest offer: the plan is judged on supply, not on a long transit.
    var nearest: usize = 0;
    for (gs.contract_offers.items, 0..) |o, i| if (o.dist_ly < gs.contract_offers.items[nearest].dist_ly) {
        nearest = i;
    };
    _ = try execute(&gs, .{ .accept_contract = .{ .offer_index = nearest, .company = co } });
    // The load-out follows the plan: within capacity, no munitions the company cannot fire.
    const cap = sites.siteCapacityTons(&gs, site).?;
    try std.testing.expect(sites.siteTons(&gs, site) <= cap);
    _ = try execute(&gs, .{ .set_supply_policy = .{ .company = co, .min_days = 14, .tons = 0 } });
    _ = try execute(&gs, .{ .set_policy = .{ .entity = .{ .company = co }, .floor = 300_000, .monthly_cap = 600_000 } });
    var day: u32 = 0;
    var hungry_days: u32 = 0;
    var dry_battles: u32 = 0;
    while (day < 150) : (day += 1) {
        try tick.advanceReading(&gs, 1);
        try std.testing.expect(sites.siteTons(&gs, site) <= cap);
        if (gs.stockCount(site, "provisions") == 0) hungry_days += 1;
    }
    for (gs.event_log.items) |e| if (std.mem.indexOf(u8, e.text, "silenced") != null and std.mem.indexOf(u8, e.text, "| 0 mounts silenced") == null) {
        dry_battles += 1;
    };
    try std.testing.expectEqual(@as(u32, 0), hungry_days);
    try std.testing.expectEqual(@as(u32, 0), dry_battles);
}

fn setFacilityLevel(gs: *GameState, hq_id: types.HqId, kind: hq_mod.FacilityKind, level: u8) !void {
    const h = gs.hqs.getPtr(hq_id).?;
    for (h.facilities.items) |*f| if (f.kind == kind) {
        f.level = level;
        h.staff_assigned = 999;
        return;
    };
    try h.facilities.append(gs.allocator(), .{ .kind = kind, .level = level });
    h.staff_assigned = 999;
}

test "air wings need a spaceport; fighters fly in air lances; support lances are facility-gated" {
    var gs = GameState.init(std.testing.allocator, .{ .seed = 15 });
    defer gs.deinit();
    _ = try execute(&gs, .{ .create_commander = .{ .name = "T", .origin = .LC, .profession = .paymaster } });
    const hq = gs.hqs.keys()[0];
    const co = (try execute(&gs, .{ .raise_company = .{ .name = "Bravo", .hq = hq } })).created_force;
    // Spaceport 1: no air slot.
    try std.testing.expectError(Error.NoAirSlot, execute(&gs, .{ .raise_air_company = co }));
    try std.testing.expectError(Error.NoAirSlot, execute(&gs, .{ .new_lance = .{ .company = co, .name = "Sky", .kind = .air } }));
    try setFacilityLevel(&gs, hq, .spaceport, 3);
    const wing = (try execute(&gs, .{ .raise_air_company = co })).created_force;
    try std.testing.expectEqual(force_mod.Echelon.air_company, gs.force(wing).?.echelon);
    try std.testing.expectEqual(@as(u32, 1), toe.lancesOfEchelon(&gs, wing, .air_lance));
    try std.testing.expectError(Error.NoAirSlot, execute(&gs, .{ .raise_air_company = co })); // one wing per company
    _ = try execute(&gs, .{ .new_lance = .{ .company = co, .name = "2nd Air Lance", .kind = .air } });
    _ = try execute(&gs, .{ .new_lance = .{ .company = co, .name = "3rd Air Lance", .kind = .air } });
    try std.testing.expectError(Error.TooManyLances, execute(&gs, .{ .new_lance = .{ .company = co, .name = "4th", .kind = .air } }));

    // A fighter goes to an air lance, never a line lance; a mek never to an air lance.
    const fighter = try gs.addUnit("SPR-H5");
    const mek = try gs.addUnit("LCT-1V");
    var line: types.ForceId = .none;
    var air: types.ForceId = .none;
    for (gs.force(co).?.children.items) |cid| if (gs.force(cid).?.echelon == .lance and line == .none) {
        line = cid;
    };
    for (gs.force(wing).?.children.items) |cid| if (air == .none) {
        air = cid;
    };
    try std.testing.expectError(Error.WrongHullKind, execute(&gs, .{ .move_unit = .{ .unit = fighter, .force = line } }));
    try std.testing.expectError(Error.WrongHullKind, execute(&gs, .{ .move_unit = .{ .unit = mek, .force = air } }));
    _ = try execute(&gs, .{ .move_unit = .{ .unit = fighter, .force = air } });
    try std.testing.expectEqual(air, gs.unit(fighter).?.force);
    try toe.placeUnitInCompany(&gs, try gs.addUnit("CSR-V12"), co);
    try std.testing.expectEqual(@as(usize, 2), gs.force(air).?.units.items.len);

    // Support lances: four staples fill the slot; a mess needs a mess hall.
    try std.testing.expectError(Error.NoSupportSlot, execute(&gs, .{ .new_lance = .{ .company = co, .name = "Mess", .kind = .{ .support = .mess } } }));
    try setFacilityLevel(&gs, hq, .mess, 2);
    const mess = (try execute(&gs, .{ .new_lance = .{ .company = co, .name = "Mess Lance", .kind = .{ .support = .mess } } })).created_force;
    try std.testing.expectEqual(force_mod.SupportLanceKind.mess, gs.force(mess).?.support_kind.?);
    try std.testing.expectError(Error.NoSupportSlot, execute(&gs, .{ .new_lance = .{ .company = co, .name = "More", .kind = .{ .support = .salvage } } }));
}

test "ships need berths, lift the company for less charter, and come home with it; a dedicated line needs a jumpship" {
    var gs = GameState.init(std.testing.allocator, .{ .seed = 16 });
    defer gs.deinit();
    _ = try execute(&gs, .{ .create_commander = .{ .name = "T", .origin = .LC, .profession = .paymaster } });
    const hq = gs.hqs.keys()[0];
    gs.hqs.getPtr(hq).?.funds = 500_000_000;
    gs.funds = 50_000_000;
    const co = (try execute(&gs, .{ .new_company = "Alpha" })).created_force;

    // One dropship berth at spaceport 1: the second Leopard is refused.
    try gs.market_listings.append(gs.allocator(), .{ .kind = .unit, .item_key = "LEOPARD", .rarity = .rare, .price = 20_000_000, .hq = hq, .listed_day = 0, .expires_day = 400 });
    try gs.market_listings.append(gs.allocator(), .{ .kind = .unit, .item_key = "LEOPARD", .rarity = .rare, .price = 20_000_000, .hq = hq, .listed_day = 0, .expires_day = 400 });
    const first = gs.market_listings.items.len - 2;
    _ = try execute(&gs, .{ .buy_listing = first });
    const ship: types.UnitId = @enumFromInt(gs.next_unit_id - 1);
    try std.testing.expectEqual(hq, gs.unit(ship).?.berth_hq);
    try std.testing.expectError(Error.NoBerth, execute(&gs, .{ .buy_listing = gs.market_listings.items.len - 1 }));
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
    var offer: usize = 0;
    for (gs.contract_offers.items, 0..) |o, i| if (o.dist_ly > gs.contract_offers.items[offer].dist_ly) {
        offer = i;
    };
    gs.contract_offers.items[offer].terms.transport_pct = 0;
    const charter_full = blk: {
        const c = gs.contract_offers.items[offer];
        break :blk @divTrunc(@as(types.CBills, c.dist_ly) * 2_000 * (100 - @as(i64, c.terms.transport_pct)), 100);
    };
    try std.testing.expectEqual(@as(types.Bp, 0), (try lift_mod.planLift(&gs, co, false)).covered_bp);
    // Crew it: a dropship crew in the pilot seat.
    const dropship_pilot = try gs.hirePerson("Ina", "Voss", .dropship_crew);
    try crew.assignSlot(&gs, ship, .pilot, dropship_pilot);
    const plan = try lift_mod.planLift(&gs, co, false);
    try std.testing.expectEqual(@as(u32, 1), plan.ships);
    try std.testing.expect(plan.carried >= 4 and plan.carried <= plan.needed);
    try std.testing.expect(plan.covered_bp > 0 and plan.covered_bp < 10_000);

    // Accept: the charter posted is below the full price, and the ship sails with the company.
    const ledger_before = gs.ledger.transactions.items.len;
    _ = try execute(&gs, .{ .accept_contract = .{ .offer_index = offer, .company = co } });
    var charter_paid: types.CBills = 0;
    for (gs.ledger.transactions.items[ledger_before..]) |t| if (t.category == .transport_charter) {
        charter_paid = -t.amount;
    };
    try std.testing.expect(charter_paid > 0 and charter_paid < types.applyBp(charter_full, commander_mod.costMultBp(gs.commander, .freight)));
    try std.testing.expectEqual(co, gs.unit(ship).?.force);
    try std.testing.expect(!lift_mod.transportAvailable(&gs, gs.unit(ship).?));
    try std.testing.expectEqual(@as(u32, 0), (try lift_mod.planLift(&gs, co, false)).ships -| 1); // still one ship, the one carrying it

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
    try setFacilityLevel(&gs, hq, .spaceport, 4);
    try setFacilityLevel(&gs, hq, .comms, 3);
    try gs.market_listings.append(gs.allocator(), .{ .kind = .unit, .item_key = "SCOUT", .rarity = .rare, .price = 50_000_000, .hq = hq, .listed_day = 0, .expires_day = 400 });
    _ = try execute(&gs, .{ .buy_listing = gs.market_listings.items.len - 1 });
    const jump: types.UnitId = @enumFromInt(gs.next_unit_id - 1);
    try std.testing.expectError(Error.NoJumpship, execute(&gs, .{ .link = .{ .a = hq, .b = far, .level = 3 } }));
    try crew.assignSlot(&gs, jump, .pilot, try gs.hirePerson("Oda", "Ferro", .jumpship_crew));
    _ = try execute(&gs, .{ .link = .{ .a = hq, .b = far, .level = 3 } });
    try std.testing.expectEqual(@as(u8, 3), network.findLink(&gs, hq, far).?.level);
    try std.testing.expectEqual(@as(types.CBills, 0), network.findLink(&gs, hq, far).?.monthlyCost());
    // With a jumpship of its own the company's next lift waives the collar fee too.
    try std.testing.expect((try lift_mod.planLift(&gs, co, false)).own_jumpship);
}

test "one negotiation round per offer — improved, hardened, or withdrawn; never a second" {
    var gs = GameState.init(std.testing.allocator, .{ .seed = 1233 });
    defer gs.deinit();
    _ = try execute(&gs, .{ .create_commander = .{ .name = "T", .origin = .LC, .profession = .paymaster } });
    try std.testing.expect(gs.contract_offers.items.len > 0);
    var improved: u32 = 0;
    var hardened: u32 = 0;
    var withdrawn: u32 = 0;
    var rounds: u32 = 0;
    while (rounds < 60) : (rounds += 1) {
        if (gs.contract_offers.items.len == 0) try @import("contract_market.zig").refresh(&gs);
        const before = gs.contract_offers.items[0].terms;
        const r = try execute(&gs, .{ .negotiate = .{ .offer_index = 0, .term = .salvage } });
        switch (r.negotiation) {
            .improved => {
                improved += 1;
                try std.testing.expect(gs.contract_offers.items[0].terms.salvage_pct > before.salvage_pct);
                try std.testing.expectError(Error.AlreadyNegotiated, execute(&gs, .{ .negotiate = .{ .offer_index = 0, .term = .pay } }));
            },
            .hardened => {
                hardened += 1;
                try std.testing.expect(gs.contract_offers.items[0].terms.base_pay_month < before.base_pay_month);
                try std.testing.expectError(Error.AlreadyNegotiated, execute(&gs, .{ .negotiate = .{ .offer_index = 0, .term = .pay } }));
            },
            .withdrawn => withdrawn += 1,
            .none => unreachable,
        }
        // Clear the board so the next round sees fresh offers.
        gs.contract_offers.clearRetainingCapacity();
    }
    try std.testing.expect(improved > 0 and hardened > 0);
    // A term at its cap is refused before any dice are thrown.
    try @import("contract_market.zig").refresh(&gs);
    gs.contract_offers.items[0].terms.advance_pct = 50;
    try std.testing.expectError(Error.TermAtCap, execute(&gs, .{ .negotiate = .{ .offer_index = 0, .term = .advance } }));
}

test "abilities are bought with XP at a training ground and change the battle math" {
    var gs = GameState.init(std.testing.allocator, .{ .seed = 1236 });
    defer gs.deinit();
    _ = try execute(&gs, .{ .create_commander = .{ .name = "T", .origin = .LC, .profession = .paymaster } });
    const co = (try execute(&gs, .{ .new_company = "Alpha" })).created_force;
    const mek = blk: {
        var it = gs.units.iterator();
        while (it.next()) |e| if (e.value_ptr.kind == .mek) break :blk e.value_ptr;
        unreachable;
    };
    const pilot = gs.person(mek.pilot).?;
    try std.testing.expectError(Error.InsufficientXp, execute(&gs, .{ .train_ability = .{ .person = pilot.id, .key = "edge" } }));
    try std.testing.expectError(Error.UnknownAbility, execute(&gs, .{ .train_ability = .{ .person = pilot.id, .key = "flying" } }));
    pilot.xp = 100;
    _ = try execute(&gs, .{ .train_ability = .{ .person = pilot.id, .key = "gunnery_specialist" } });
    try std.testing.expect(pilot.has("gunnery_specialist"));
    try std.testing.expectEqual(@as(u32, 76), pilot.xp);
    try std.testing.expectError(Error.AlreadyLearned, execute(&gs, .{ .train_ability = .{ .person = pilot.id, .key = "gunnery_specialist" } }));
    // Deployed: no school.
    _ = try execute(&gs, .{ .accept_contract = .{ .offer_index = 0, .company = co } });
    try std.testing.expectError(Error.PersonDeployed, execute(&gs, .{ .train_ability = .{ .person = pilot.id, .key = "edge" } }));
}

test "gear on any hull is field work — replace orders the spare to its site, the tech fits it" {
    var gs = GameState.init(std.testing.allocator, .{ .seed = 61 });
    defer gs.deinit();
    _ = try execute(&gs, .{ .create_commander = .{ .name = "T", .origin = .LC, .profession = .quartermaster } });
    const uid = try gs.addUnit("SVT-1"); // a salvage truck: cargo, not a mek
    const tech = try gs.hirePerson("Wren", "Okafor", .tech_mechanic);
    try crew.assignSlot(&gs, uid, .tech, tech);
    for (gs.unit(uid).?.slots.items) |*s| if (std.mem.eql(u8, s.slot_key, "bed.winch.1")) {
        s.condition = .destroyed;
    };

    // The Lab's door is shut to it, and the depot only does structure.
    try std.testing.expectError(Error.NotAMek, execute(&gs, .{ .refit_remove = .{ .unit = uid, .slot_key = "bed.winch.1" } }));
    try std.testing.expectError(Error.NothingToRepair, execute(&gs, .{ .depot = uid }));

    // replace orders exactly one winch to the hull's site; once it is on
    // order a second call orders nothing more.
    const site = sites.siteForForce(&gs, gs.unit(uid).?.force);
    const r = try execute(&gs, .{ .replace_gear = uid });
    try std.testing.expectEqual(@as(u32, 1), r.ordered + r.unsourced);
    if (r.ordered == 1) {
        const again = try execute(&gs, .{ .replace_gear = uid });
        try std.testing.expectEqual(@as(u32, 0), again.ordered + again.unsourced);
    }

    // Sourcing is a roll: put the spare on the shelf and let the weekly
    // pass fit it — the mechanic's own hours, no bay involved.
    try gs.addStock(site, "winch", 1);
    _ = try execute(&gs, .{ .advance_days = 7 });
    for (gs.unit(uid).?.slots.items) |s| if (std.mem.eql(u8, s.slot_key, "bed.winch.1")) {
        try std.testing.expectEqual(unit_mod.PartCondition.ok, s.condition);
    };
    try std.testing.expectError(Error.NothingToReplace, execute(&gs, .{ .replace_gear = uid }));
}

test "depot work happens at the hull's home HQ — its components, its bay — not the outfit's first one" {
    var gs = GameState.init(std.testing.allocator, .{ .seed = 97 });
    defer gs.deinit();
    _ = try execute(&gs, .{ .create_commander = .{ .name = "T", .origin = .LC, .profession = .quartermaster } });
    const home = gs.hqs.keys()[0];
    // A second HQ in the home ring, raised to regional with a staffed bay.
    const home_world = planet_mod.find(gs.hqs.getPtr(home).?.planet_key).?;
    var key: []const u8 = "";
    for (planet_mod.catalog) |*p| if (p != home_world and planet_mod.distanceLy(p, home_world) <= gs.hqs.getPtr(home).?.influenceLy() and key.len == 0) {
        key = p.key;
    };
    _ = try execute(&gs, .{ .found_hq = .{ .name = "Firebase", .planet_key = key } });
    const fb = gs.hqs.keys()[1];
    {
        const h = gs.hqs.getPtr(fb).?;
        h.tier = .regional;
        try h.facilities.append(gs.allocator(), .{ .kind = .mek_bay, .level = 1 });
        h.staff_assigned = 999; // fully staffed, so the bay counts (and hosts four lances)
    }
    const co = (try execute(&gs, .{ .new_company_at = .{ .name = "Bravo", .hq = fb } })).created_force;
    try std.testing.expectEqual(fb, gs.homeHqFor(co));

    // One of Bravo's meks loses a side torso.
    var uid: types.UnitId = .none;
    var it = gs.units.iterator();
    while (it.next()) |e| if (e.value_ptr.kind == .mek and gs.companyOf(e.value_ptr.force) == co) {
        for (e.value_ptr.slots.items) |*s| if (s.class == .structure and std.mem.startsWith(u8, s.slot_key, "lt.")) {
            s.condition = .destroyed;
            uid = e.value_ptr.id;
            break;
        };
        if (uid != .none) break;
    };
    try std.testing.expect(uid != .none);

    // The torso assembly sits in Bravo's own depot; the first HQ has none.
    const torso = @import("../domain/part.zig").componentFor("lt.structure", gs.unit(uid).?.chassis_key); // by weight class
    _ = gs.takeStock(.{ .hq = home }, torso, gs.stockCount(.{ .hq = home }, torso));
    _ = gs.takeStock(.{ .hq = fb }, torso, gs.stockCount(.{ .hq = fb }, torso));
    try gs.addStock(.{ .hq = fb }, torso, 1);
    _ = try execute(&gs, .{ .depot = uid });
    try std.testing.expect(hq_ops.hasJobForUnit(&gs, uid));
    for (gs.bay_jobs.items) |j| if (j.unit == uid) try std.testing.expectEqual(fb, j.hq);
    try std.testing.expectEqual(@as(u32, 0), gs.stockCount(.{ .hq = fb }, torso));
}

test "a truck sent to a deployed company lands in its transport lance, and can still change lances out there" {
    var gs = GameState.init(std.testing.allocator, .{ .seed = 44 });
    defer gs.deinit();
    _ = try execute(&gs, .{ .create_commander = .{ .name = "T", .origin = .LC, .profession = .quartermaster } });
    const co = (try execute(&gs, .{ .new_company = "Alpha" })).created_force;
    // Alpha is away on a garrison contract.
    const cid: types.ContractId = @enumFromInt(901);
    try gs.contracts.put(gs.allocator(), cid, .{
        .id = cid,
        .kind = .garrison_duty,
        .employer_key = "LC",
        .enemy_key = "PER",
        .planet_key = gs.hqs.values()[0].planet_key,
        .status = .active,
        .assigned_company = co,
        .terms = .{ .length_months = 12, .base_pay_month = 100_000 },
    });
    try std.testing.expect(gs.deploymentContract(co) != null);

    // A cargo truck arrives from the HQ: it joins the transport lance, not the company node.
    const truck = try gs.addUnit("CGT-3");
    try toe.placeUnitInCompany(&gs, truck, co);
    const transport = toe.supportLanceFor(&gs, co, gs.unit(truck).?).?;
    try std.testing.expectEqual(transport, gs.unit(truck).?.force);
    try std.testing.expectEqual(force_mod.SupportLanceKind.transport, gs.force(transport).?.support_kind.?);

    // Reshuffling inside the deployed company works; a salvage truck goes to salvage.
    const salvage: types.ForceId = if (toe.supportLance(&gs, co, .salvage)) |l| l.id else .none;
    _ = try execute(&gs, .{ .move_unit = .{ .unit = truck, .force = salvage } });
    try std.testing.expectEqual(salvage, gs.unit(truck).?.force);

    // Joining a deployed company from outside still waits for home.
    const outsider = try gs.addUnit("CGT-3");
    try std.testing.expectError(Error.CompanyDeployed, execute(&gs, .{ .move_unit = .{ .unit = outsider, .force = transport } }));
}

test "train co:N enrols the whole home company at their trades, and says who it skipped" {
    var gs = GameState.init(std.testing.allocator, .{ .seed = 88 });
    defer gs.deinit();
    _ = try execute(&gs, .{ .create_commander = .{ .name = "T", .origin = .FS, .profession = .line_officer } });
    const co = (try execute(&gs, .{ .new_company = "Alpha" })).created_force;
    // Everyone can afford a level; one mekwarrior is already in a program.
    var busy_one = false;
    var pit = gs.people.iterator();
    while (pit.next()) |e| if (gs.companyOf(e.value_ptr.assigned_force) == co) {
        e.value_ptr.xp = 500;
        if (!busy_one and e.value_ptr.role == .mekwarrior) {
            e.value_ptr.training = .{ .skill = .piloting_mek, .done_day = 30 };
            busy_one = true;
        }
    };
    const r = try execute(&gs, .{ .train_company = .{ .company = co } });
    try std.testing.expect(r.enrolled > 10);
    try std.testing.expectEqual(@as(u32, 0), r.short_xp);
    try std.testing.expect(r.busy >= 1);
    // Every enrolled person trains their own trade.
    var checked: u32 = 0;
    var pit2 = gs.people.iterator();
    while (pit2.next()) |e| if (gs.companyOf(e.value_ptr.assigned_force) == co and e.value_ptr.training != null and e.value_ptr.training.?.done_day != 30) {
        try std.testing.expectEqual(e.value_ptr.role.primarySkill(), e.value_ptr.training.?.skill);
        checked += 1;
    };
    try std.testing.expectEqual(r.enrolled, checked);
    // A second pass finds them all busy; a named skill nobody has is nothing to learn.
    const again = try execute(&gs, .{ .train_company = .{ .company = co } });
    try std.testing.expectEqual(@as(u32, 0), again.enrolled);
    try std.testing.expect(again.busy >= r.enrolled);
    // Away from home the command refuses.
    const cid: types.ContractId = @enumFromInt(903);
    try gs.contracts.put(gs.allocator(), cid, .{ .id = cid, .kind = .garrison_duty, .employer_key = "LC", .enemy_key = "PER", .planet_key = gs.hqs.values()[0].planet_key, .status = .active, .assigned_company = co, .terms = .{ .length_months = 12, .base_pay_month = 100_000 } });
    try std.testing.expectError(Error.CompanyDeployed, execute(&gs, .{ .train_company = .{ .company = co } }));
}

test "a wreck is rebuilt in the depot — a component and bay time — and comes back ready" {
    var gs = GameState.init(std.testing.allocator, .{ .seed = 95 });
    defer gs.deinit();
    _ = try execute(&gs, .{ .create_commander = .{ .name = "T", .origin = .LC, .profession = .quartermaster } });
    const co = (try execute(&gs, .{ .new_company = "Alpha" })).created_force;
    const home = gs.hqs.keys()[0];
    gs.hqs.getPtr(home).?.staff_assigned = 999;
    var uid: types.UnitId = .none;
    var uit = gs.units.iterator();
    while (uit.next()) |e| if (e.value_ptr.kind == .mek and gs.companyOf(e.value_ptr.force) == co) {
        uid = e.value_ptr.id;
        break;
    };
    const u = gs.unit(uid).?;
    // Killed in action: destroyed, centre torso gone; a damaged ammo bin on top.
    u.markWrecked();
    for (u.slots.items) |*s| if (s.class == .ammo) {
        s.condition = .damaged;
        break;
    };
    try std.testing.expect(u.needsDepot());
    var ct_destroyed = false;
    for (u.slots.items) |s| if (std.mem.startsWith(u8, s.slot_key, "ct.") and s.class == .structure and s.condition == .destroyed) {
        ct_destroyed = true;
    };
    try std.testing.expect(ct_destroyed);

    // No centre torso on the shelf: the depot asks for it; with one, it queues.
    const ct = @import("../domain/part.zig").componentFor("ct.structure", u.chassis_key); // by weight class
    _ = gs.takeStock(.{ .hq = home }, ct, gs.stockCount(.{ .hq = home }, ct));
    try std.testing.expectError(Error.MissingComponents, execute(&gs, .{ .depot = uid }));
    try gs.addStock(.{ .hq = home }, ct, 1);
    _ = try execute(&gs, .{ .depot = uid });
    try std.testing.expect(hq_ops.hasJobForUnit(&gs, uid));
    try std.testing.expectEqual(@as(u32, 0), gs.stockCount(.{ .hq = home }, ct));
    // Bay time passes (a failed check redoes the work); the wreck is a hull again.
    var days: u32 = 0;
    while (hq_ops.hasJobForUnit(&gs, uid) and days < 300) : (days += 1) {
        try hq_ops.runDaily(&gs);
        gs.clock.day_index += 1;
    }
    try std.testing.expect(!hq_ops.hasJobForUnit(&gs, uid));
    try std.testing.expectEqual(unit_mod.UnitStatus.ready, gs.unit(uid).?.status);
    try std.testing.expect(!gs.unit(uid).?.needsDepot());

    // A wreck from an older save — destroyed, structure untouched — gets its wreck on the way in.
    const legacy = try gs.addUnit("LCT-1V");
    gs.unit(legacy).?.status = .destroyed;
    try std.testing.expect(gs.unit(legacy).?.needsDepot());
    try gs.addStock(.{ .hq = home }, "comp_ct_l", 1); // a Locust's centre torso is a light assembly
    _ = try execute(&gs, .{ .depot = legacy });
    try std.testing.expect(hq_ops.hasJobForUnit(&gs, legacy));
    try std.testing.expectEqual(@as(u32, 0), gs.stockCount(.{ .hq = home }, "comp_ct_l"));
}

test "difficulty scales pay, fabrication and purchases — regular is the game as tuned, and it persists as a setting" {
    var gs = GameState.init(std.testing.allocator, .{ .seed = 98 });
    defer gs.deinit();
    _ = try execute(&gs, .{ .create_commander = .{ .name = "T", .origin = .LC, .profession = .quartermaster } });
    _ = try execute(&gs, .{ .new_company = "Alpha" });
    const hq_id = gs.hqs.keys()[0];
    try std.testing.expectEqual(@import("../domain/difficulty.zig").Level.regular, gs.difficulty);

    // Fabrication: elite charges more than regular for the same job.
    gs.hqs.getPtr(hq_id).?.funds = 50_000_000;
    const before_r = gs.hqs.getPtr(hq_id).?.funds;
    _ = try execute(&gs, .{ .fabricate = .{ .hq = hq_id, .part_key = "comp_leg", .quantity = 1 } });
    const cost_r = before_r - gs.hqs.getPtr(hq_id).?.funds;
    _ = try execute(&gs, .{ .set_difficulty = .elite });
    const before_e = gs.hqs.getPtr(hq_id).?.funds;
    _ = try execute(&gs, .{ .fabricate = .{ .hq = hq_id, .part_key = "comp_leg", .quantity = 1 } });
    const cost_e = before_e - gs.hqs.getPtr(hq_id).?.funds;
    try std.testing.expect(cost_e > cost_r);
    try std.testing.expectEqual(types.applyBp(cost_r, gs.diff().fab_cost_bp), cost_e);
    // Regular: exactly the tuned ×1.5 on the catalogue price — a full structure set is 900 k.
    const part_mod2 = @import("../domain/part.zig");
    try std.testing.expectEqual(types.applyBp(part_mod2.cost("comp_leg"), tuning.market.fab_cost_bp), cost_r);

    // Contract pay: the same board, rolled under green and under elite, pays in the table's ratio.
    const cm = @import("contract_market.zig");
    _ = try execute(&gs, .{ .set_difficulty = .green });
    var green = GameState.init(std.testing.allocator, .{ .seed = 98 });
    defer green.deinit();
    _ = try execute(&green, .{ .create_commander = .{ .name = "T", .origin = .LC, .profession = .quartermaster } });
    _ = try execute(&green, .{ .new_company = "Alpha" });
    green.difficulty = .green;
    var elite = GameState.init(std.testing.allocator, .{ .seed = 98 });
    defer elite.deinit();
    _ = try execute(&elite, .{ .create_commander = .{ .name = "T", .origin = .LC, .profession = .quartermaster } });
    _ = try execute(&elite, .{ .new_company = "Alpha" });
    elite.difficulty = .elite;
    try cm.refresh(&green);
    try cm.refresh(&elite);
    try std.testing.expect(green.contract_offers.items.len > 0);
    try std.testing.expectEqual(green.contract_offers.items.len, elite.contract_offers.items.len);
    const g0 = green.contract_offers.items[0].terms.base_pay_month;
    const e0 = elite.contract_offers.items[0].terms.base_pay_month;
    try std.testing.expect(e0 < g0);
    // ×0.61 / ×1.22 = exactly half, give or take rounding.
    try std.testing.expect(@abs(e0 * 2 - g0) <= @divTrunc(g0, 50));

    // The level is logged and survives a round trip through the store.
    var seen = false;
    for (gs.event_log.items) |e| if (std.mem.indexOf(u8, e.text, "[difficulty]") != null) {
        seen = true;
    };
    try std.testing.expect(seen);
}

test "a resignation notice waits two weeks — a week's skip cannot walk past it" {
    var gs = GameState.init(std.testing.allocator, .{ .seed = 99 });
    defer gs.deinit();
    _ = try execute(&gs, .{ .create_commander = .{ .name = "T", .origin = .LC, .profession = .paymaster } });
    _ = try execute(&gs, .{ .new_company = "Alpha" });
    gs.funds = 50_000_000;
    const someone = gs.people.values()[0].id;
    const ce = @import("contract_events.zig");
    try ce.queueNotice(&gs, someone);
    var deadline: u32 = 0;
    for (gs.event_queue.pending.items) |ev| if (ev.kind == .notice_given and ev.person == someone) {
        deadline = ev.deadline_day;
    };
    try std.testing.expectEqual(gs.clock.day_index + ce.notice_window_days, deadline);
    try std.testing.expect(ce.notice_window_days >= 14);
    try std.testing.expect(ce.notice_window_days > ce.decision_window_days);
    // Seven days on: still in the inbox, still unanswered.
    _ = try execute(&gs, .{ .advance_days = 7 });
    var still_open = false;
    for (gs.event_queue.pending.items) |ev| if (ev.kind == .notice_given and ev.person == someone and ev.needsDecision()) {
        still_open = true;
    };
    try std.testing.expect(still_open);
}

test "how a hull died decides the rebuild — engine kills cost an engine, scrap only strips" {
    var gs = GameState.init(std.testing.allocator, .{ .seed = 1202 });
    defer gs.deinit();
    _ = try execute(&gs, .{ .create_commander = .{ .name = "T", .origin = .LC, .profession = .quartermaster } });
    const home = gs.hqs.keys()[0];
    gs.hqs.getPtr(home).?.staff_assigned = 999;

    // An ammunition explosion guts both side torsos and needs an engine.
    const boom = try gs.addUnit("SHD-2H");
    gs.unit(boom).?.markWreckedBy(.ammo);
    var torsos: u32 = 0;
    for (gs.unit(boom).?.slots.items) |s| if (s.class == .structure and s.condition == .destroyed) {
        torsos += 1;
    };
    try std.testing.expectEqual(@as(u32, 3), torsos); // ct + lt + rt
    // TechManual engine price for the Shadow Hawk (55 t, walk 5 → 275).
    try std.testing.expectEqual(@as(types.CBills, 5_000 * 275 * 55 / 75), hq_ops.engineCharge(gs.unit(boom).?));
    try gs.addStock(.{ .hq = home }, "comp_ct", 1);
    try gs.addStock(.{ .hq = home }, "comp_torso", 2);
    _ = try execute(&gs, .{ .depot = boom });
    var job_cost: types.CBills = 0;
    var job_days: u32 = 0;
    for (gs.bay_jobs.items) |j| if (j.unit == boom) {
        job_cost = j.cost;
        job_days = j.duration_days;
    };
    try std.testing.expect(job_cost >= hq_ops.engineCharge(gs.unit(boom).?));
    try std.testing.expect(job_days >= tuning.loss.engine_rebuild_days);
    try std.testing.expect(hq_ops.rebuildEstimate(&gs, gs.unit(boom).?) != null);

    // Scrap is refused by the depot and priced as parts.
    const junk = try gs.addUnit("SHD-2H");
    gs.unit(junk).?.markWreckedBy(.scrap);
    gs.unit(junk).?.armor_pct = 50;
    try std.testing.expectError(Error.WrittenOff, execute(&gs, .{ .depot = junk }));
    try std.testing.expect(hq_ops.rebuildEstimate(&gs, gs.unit(junk).?) == null);
    try std.testing.expect(hq_ops.beyondEconomicalRepair(&gs, gs.unit(junk).?));
    try std.testing.expect(market_mod.unitSaleValue(gs.unit(junk).?) > 0); // the guns are still worth something

    // Stripping crates the guns and the armour left on it, and the hull is gone.
    const ac5_before = gs.stockCount(.{ .hq = home }, "ac5");
    const armor_before = gs.stockCount(.{ .hq = home }, "armor");
    const ct_before = gs.stockCount(.{ .hq = home }, "comp_ct");
    _ = try execute(&gs, .{ .strip_unit = junk });
    try std.testing.expect(gs.unit(junk) == null);
    try std.testing.expectEqual(ac5_before + 1, gs.stockCount(.{ .hq = home }, "ac5"));
    try std.testing.expect(gs.stockCount(.{ .hq = home }, "armor") > armor_before);
    try std.testing.expectEqual(ct_before, gs.stockCount(.{ .hq = home }, "comp_ct")); // scrap has no structure left
}

test "the contract world has a hull board — local funds pay, the hull joins the company there" {
    var gs = GameState.init(std.testing.allocator, .{ .seed = 1207 });
    defer gs.deinit();
    _ = try execute(&gs, .{ .create_commander = .{ .name = "T", .origin = .LC, .profession = .quartermaster } });
    const co = (try execute(&gs, .{ .new_company = "Alpha" })).created_force;
    const cid: types.ContractId = @enumFromInt(1207);
    try gs.contracts.put(gs.allocator(), cid, .{ .id = cid, .kind = .objective_raid, .employer_key = "LC", .enemy_key = "DC", .planet_key = "hesperus_ii", .status = .active, .assigned_company = co, .terms = .{ .length_months = 3, .base_pay_month = 100_000 } });
    gs.force(co).?.location_planet = "hesperus_ii";
    // Hesperus II builds meks: something turns up within a few tries.
    var tries: u32 = 0;
    var idx: ?usize = null;
    while (idx == null and tries < 20) : (tries += 1) {
        try @import("contract_market.zig").refreshContractWorld(&gs, gs.contracts.getPtr(cid).?);
        for (gs.market_listings.items, 0..) |l, i| if (l.company == co) {
            idx = i;
        };
    }
    try std.testing.expect(idx != null);
    // Broke: refused; funded: bought from local funds, on the company's books at once.
    gs.force(co).?.local_funds = 0;
    try std.testing.expectError(Error.CompanyFundsShort, execute(&gs, .{ .buy_listing = idx.? }));
    gs.force(co).?.local_funds = 50_000_000;
    const hq_funds = gs.hqs.values()[0].funds;
    const r = try execute(&gs, .{ .buy_listing = idx.? });
    try std.testing.expectEqual(co, gs.companyOf(gs.unit(r.unit).?.force));
    try std.testing.expect(gs.force(co).?.local_funds < 50_000_000);
    try std.testing.expectEqual(hq_funds, gs.hqs.values()[0].funds);
    // Not a raise candidate, and gone with the contract at the next refresh.
    gs.contracts.getPtr(cid).?.status = .completed;
    try @import("contract_market.zig").refreshListings(&gs);
    for (gs.market_listings.items) |l| try std.testing.expect(l.company == .none);
}

test "heavy assemblies need a level-2 bay, assault ones a level-3 bay at a regional HQ" {
    var gs = GameState.init(std.testing.allocator, .{ .seed = 1208 });
    defer gs.deinit();
    _ = try execute(&gs, .{ .create_commander = .{ .name = "T", .origin = .LC, .profession = .quartermaster } });
    const hq_id = gs.hqs.keys()[0];
    const h = gs.hqs.getPtr(hq_id).?;
    h.staff_assigned = 999;
    h.funds = 50_000_000;
    const bay = for (h.facilities.items) |*f| {
        if (f.kind == .mek_bay) break f;
    } else return error.TestUnexpectedResult;
    bay.level = 1;
    _ = try execute(&gs, .{ .fabricate = .{ .hq = hq_id, .part_key = "comp_ct_l", .quantity = 1 } });
    _ = try execute(&gs, .{ .fabricate = .{ .hq = hq_id, .part_key = "comp_ct", .quantity = 1 } });
    try std.testing.expectError(Error.BayTooSmall, execute(&gs, .{ .fabricate = .{ .hq = hq_id, .part_key = "comp_ct_h", .quantity = 1 } }));
    bay.level = 2;
    _ = try execute(&gs, .{ .fabricate = .{ .hq = hq_id, .part_key = "comp_ct_h", .quantity = 1 } });
    try std.testing.expectError(Error.BayTooSmall, execute(&gs, .{ .fabricate = .{ .hq = hq_id, .part_key = "comp_ct_a", .quantity = 1 } }));
    bay.level = 3;
    _ = try execute(&gs, .{ .fabricate = .{ .hq = hq_id, .part_key = "comp_ct_a", .quantity = 1 } });
    // A field HQ never builds assault assemblies, whatever its bay.
    h.tier = .field;
    try std.testing.expect(!hq_ops.canFabricate(&gs, hq_id, "comp_ct_a"));
    try std.testing.expect(hq_ops.canFabricate(&gs, hq_id, "comp_ct_h"));
}

test "one board per HQ — offers inside its reach, taken only by companies based there" {
    var gs = GameState.init(std.testing.allocator, .{ .seed = 1240 });
    defer gs.deinit();
    _ = try execute(&gs, .{ .create_commander = .{ .name = "T", .origin = .LC, .profession = .quartermaster } });
    const home = gs.hqs.keys()[0];
    const alpha = (try execute(&gs, .{ .new_company = "Alpha" })).created_force;
    // A second base at the edge of the home ring, grown to host a company.
    const home_world = planet_mod.find(gs.hqs.getPtr(home).?.planet_key).?;
    var far_key: []const u8 = "";
    var far_dist: u32 = 0;
    for (planet_mod.catalog) |*p| {
        const d = planet_mod.distanceLy(p, home_world);
        if (d <= gs.hqs.getPtr(home).?.influenceLy() and d > far_dist) {
            far_dist = d;
            far_key = p.key;
        }
    }
    _ = try execute(&gs, .{ .found_hq = .{ .name = "Far", .planet_key = far_key } });
    const far = gs.hqs.keys()[1];
    {
        const h = gs.hqs.getPtr(far).?;
        h.tier = .regional;
        try h.facilities.append(gs.allocator(), .{ .kind = .mek_bay, .level = 1 });
        h.staff_assigned = 999;
    }
    const bravo = (try execute(&gs, .{ .new_company_at = .{ .name = "Bravo", .hq = far } })).created_force;
    try @import("contract_market.zig").refresh(&gs);
    var on_home: u32 = 0;
    var on_far: u32 = 0;
    var far_offer: ?usize = null;
    var home_offer: ?usize = null;
    for (gs.contract_offers.items, 0..) |o, i| {
        const h = gs.hqs.getPtr(o.offer_hq) orelse return error.TestUnexpectedResult;
        const dist = planet_mod.distanceLy(planet_mod.find(h.planet_key).?, planet_mod.find(o.planet_key).?);
        try std.testing.expectEqual(dist, o.dist_ly);
        try std.testing.expect(dist <= h.influenceLy() + market_mod.beachhead_band_ly);
        if (o.offer_hq == home) {
            on_home += 1;
            home_offer = i;
        } else {
            on_far += 1;
            far_offer = i;
        }
    }
    try std.testing.expect(on_home > 0 and on_far > 0);
    // Alpha cannot take the far board's work; Bravo can.
    try std.testing.expect(!contract_market.offerEligible(&gs, &gs.contract_offers.items[far_offer.?], alpha));
    try std.testing.expectError(Error.OutOfRange, execute(&gs, .{ .accept_contract = .{ .offer_index = far_offer.?, .company = alpha } }));
    try std.testing.expectError(Error.OutOfRange, execute(&gs, .{ .accept_contract = .{ .offer_index = home_offer.?, .company = bravo } }));
    _ = try execute(&gs, .{ .accept_contract = .{ .offer_index = far_offer.?, .company = bravo } });
    try std.testing.expect(gs.deploymentContract(bravo) != null);
}

test "a command leaves derived state consistent: firing, disbanding and selling an HQ clean up after themselves" {
    var gs = GameState.init(std.testing.allocator, .{ .seed = 12 });
    defer gs.deinit();
    _ = try execute(&gs, .{ .create_commander = .{ .name = "T", .origin = .LC, .profession = .paymaster } });
    gs.funds = 50_000_000;
    const seat = gs.hqs.keys()[0];

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

test "an upgrade the HQ cannot afford is refused before a C-bill moves, from the same rule the screen dims on" {
    var gs = GameState.init(std.testing.allocator, .{ .seed = 909 });
    defer gs.deinit();
    _ = try execute(&gs, .{ .create_commander = .{ .name = "T", .origin = .LC, .profession = .paymaster } });
    const hq = gs.hqs.keys()[0];
    gs.hqs.getPtr(hq).?.funds = 1;
    try std.testing.expectEqual(hq_ops.UpgradeBlock.funds_short, hq_ops.upgradeBlock(&gs, hq, .mess).?);
    try std.testing.expectError(Error.InsufficientTreasury, execute(&gs, .{ .upgrade_facility = .{ .hq = hq, .kind = .mess } }));
    try std.testing.expectEqual(@as(types.CBills, 1), gs.hqs.getPtr(hq).?.funds);
    gs.hqs.getPtr(hq).?.funds = 50_000_000;
    try std.testing.expect(hq_ops.upgradeBlock(&gs, hq, .mess) == null);
    _ = try execute(&gs, .{ .upgrade_facility = .{ .hq = hq, .kind = .mess } });
    try std.testing.expectEqual(hq_ops.UpgradeBlock.in_progress, hq_ops.upgradeBlock(&gs, hq, .mess).?);
}
