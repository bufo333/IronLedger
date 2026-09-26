//! GameState: the one big tree the simulation systems operate on (ARCH §4).
//! Owned by an arena; pure and deterministic — no I/O, no wall clock.
//! MekHQ counterpart: `Campaign`, decomposed: state lives here, behavior
//! lives in the system modules (tick.zig, commands.zig, ...).

const std = @import("std");
const tuning = @import("../domain/tuning.zig").t;
const types = @import("../domain/types.zig");
const person_mod = @import("../domain/person.zig");
const unit_mod = @import("../domain/unit.zig");
const chassis_mod = @import("../domain/chassis.zig");
const force_mod = @import("../domain/force.zig");
const hq_mod = @import("../domain/hq.zig");
const contract_mod = @import("../domain/contract.zig");
const clock_mod = @import("clock.zig");
const rng_mod = @import("rng.zig");
const events_mod = @import("events.zig");
const after_action_mod = @import("after_action.zig");
const difficulty_mod = @import("../domain/difficulty.zig");
const finance_mod = @import("../econ/finance.zig");
const person_gen = @import("../gen/person_gen.zig");
const commander_mod = @import("../domain/commander.zig");
const planet_mod = @import("../domain/planet.zig");
const part_mod = @import("../domain/part.zig");
const market_mod = @import("../econ/market.zig");
const meklab = @import("../domain/meklab.zig");

pub const Config = struct {
    seed: u64 = 3025,
    start_funds: types.CBills = 10_000_000,
    start_date: clock_mod.Date = clock_mod.Date.campaign_default,
};

/// Where money lives (ARCH §11): the outfit's central treasury,
/// an HQ's funds, or a deployed company's operating fund. Spending resolves
/// where the spender stands — the treasury cannot teleport.
pub const Treasury = union(enum) {
    outfit,
    hq: types.HqId,
    company: types.ForceId,

    /// Ledger/log tags, so per-entity books stay filterable.
    pub fn tags(self: Treasury) LogCtx {
        return switch (self) {
            .outfit => .{},
            .hq => |id| .{ .hq = id },
            .company => |id| .{ .company = id },
        };
    }

    /// The treasury that pays for a site's logistics.
    pub fn ofSite(site: types.Site) Treasury {
        return switch (site) {
            .outfit => .outfit,
            .hq => |id| .{ .hq = id },
            .company => |id| .{ .company = id },
        };
    }
};

/// Money in transit between treasuries (courier aboard scheduled transport).
pub const FundCourier = struct {
    to: Treasury,
    amount: types.CBills,
    sent_day: u32,
    eta_day: u32,
};

/// "Keep this entity topped up to `floor`, moving at most `monthly_cap`" —
/// executed automatically on payday via the same delayed couriers.
pub const StandingPolicy = struct {
    entity: Treasury,
    floor: types.CBills,
    monthly_cap: types.CBills,
    /// Dispatched so far this month (policies are checked daily, the cap
    /// is per month; reset on payday).
    sent_this_month: types.CBills = 0,
};

/// "Keep this company's field stores above `min_days` of provisions":
/// when they drop under, `tons` are shipped from its home warehouse over
/// the supply link. One inbound shipment at a time.
pub const SupplyPolicy = struct {
    company: types.ForceId,
    /// Safety days of provisions to hold past the line's transit.
    min_days: u16,
    /// Cap on one shipment in tons (0 = the plan decides).
    tons: u32,
    /// Munition target in battles' worth per family; 0 = derive from the
    /// supply line: 1 + ceil(transit/15) battles as the floor, floor + 2 as the target.
    ammo_battles: u8 = 0,
};

/// "Keep this warehouse stocked": when an HQ's count of `part_key` drops
/// under `min`, enough is ordered (components: fabricated when the HQ has a
/// bay) to bring it back to `target`. Checked daily; one order per line in
/// flight, and a failed sourcing roll is not retried for a week.
pub const StockPolicy = struct {
    hq: types.HqId,
    part_key: []const u8,
    min: u32,
    target: u32,
};

/// Campaign counters.
pub const Stats = struct {
    battles_won: u32 = 0,
    battles_drawn: u32 = 0,
    battles_lost: u32 = 0,
    hulls_lost: u32 = 0,
    hulls_salvaged: u32 = 0,
    people_kia: u32 = 0,
    enemy_bv_destroyed: u64 = 0,

    /// Nothing counted yet: a new campaign, or a save without counter rows
    /// (the loader recounts those from the log).
    pub fn isEmpty(self: Stats) bool {
        return self.battles_won + self.battles_drawn + self.battles_lost + self.hulls_salvaged == 0;
    }
};

pub const RatingSnapshot = struct { year: i32, score: i32 };

pub const LogCategory = enum {
    battle,
    decision,
    delivery,
    contract,
    medical,
    training,
    rotation,
    finance,
    construction,
    market,
    misc,
};

pub const LogCtx = struct {
    company: types.ForceId = .none,
    hq: types.HqId = .none,
    contract: types.ContractId = .none,
};

/// Structured campaign log entry: every entry tagged so any entity's
/// history is a filter, not an archaeology dig.
pub const LogEntry = struct {
    day: u32,
    category: LogCategory,
    company: types.ForceId = .none,
    hq: types.HqId = .none,
    contract: types.ContractId = .none,
    text: []const u8,

    pub fn matches(self: *const LogEntry, filter: LogFilter) bool {
        return switch (filter) {
            .all => true,
            .category => |c| self.category == c,
            .company => |id| self.company == id,
            .hq => |id| self.hq == id,
            .contract => |id| self.contract == id,
        };
    }
};

pub const LogFilter = union(enum) {
    all,
    category: LogCategory,
    company: types.ForceId,
    hq: types.HqId,
    contract: types.ContractId,
};

/// Mek bay work: jobs hold a bay slot for a span of days; they
/// wait in queue when the bays are full.
pub const BayJobKind = enum { depot_repair, reactivation, fabrication, refit };

pub const BayJob = struct {
    hq: types.HqId,
    kind: BayJobKind,
    unit: types.UnitId = .none,
    item_key: []const u8 = "", // component being fabricated
    duration_days: u32,
    queued_day: u32,
    started_day: ?u32 = null,
    done_day: ?u32 = null,
    cost: types.CBills = 0, // labor posted to the HQ at completion
};

/// A hiring-hall candidate: the generated person, held for
/// the player to hire (with a signing bonus) before they move on.
pub const Candidate = struct {
    hq: types.HqId,
    spec: person_gen.GeneratedPerson,
    asking_bonus: types.CBills,
    listed_day: u32,
    expires_day: u32,
};

pub const UnitTransfer = struct {
    unit: types.UnitId,
    to_company: types.ForceId,
    eta_day: u32,
};

pub const FactionCooling = struct {
    faction: []const u8,
    until_day: u32,
};

/// A MekLab refit plan: edits staged against a hull, validated
/// on demand, committed into a bay job.
pub const RefitPlan = struct {
    unit: types.UnitId,
    ops: std.ArrayListUnmanaged(meklab.RefitOp) = .empty,
    committed: bool = false,
};

/// One decision kind's history: last day it fired, the last answer, and
/// how many times running that same answer was given.
pub const EventMemory = struct { last_day: u32 = 0, last_choice: u8 = 0, streak: u8 = 0 };

pub const GameState = struct {
    arena: std.heap.ArenaAllocator,
    rng: rng_mod.Rng,
    clock: clock_mod.Clock,
    funds: types.CBills,
    reputation: i32 = 0,
    /// Player-set identity (ARCH §9.8); companies carry their own in Force.
    outfit_name: []const u8 = "Provisional Mercenary Command",
    /// The player character (character creation): origin decides where the
    /// outfit stands up; profession grants one 2% edge (commander.zig).
    commander: ?commander_mod.Commander = null,
    /// Row id in the save store's campaign registry; 0 = never saved.
    campaign_id: i64 = 0,
    /// Set when the treasury went negative beyond what loans and sales
    /// could cover: game over. Persisted; advancing refuses.
    bankrupt: bool = false,
    /// The medbay admits the wounded itself each morning instead of waiting for the commander's signature (an untreated-wounded
    /// warning never blocks the turn while this is on).
    auto_admit: bool = false,
    /// Share of contract income paid out to shareholders at completion
    /// (AtB shares); the owner sets it with `shares <pct>`.
    share_profit_bp: types.Bp = @import("../domain/tuning.zig").t.person.share_profit_default_bp,
    ledger: finance_mod.Ledger = .{},
    event_queue: events_mod.EventQueue = .{},

    people: std.AutoArrayHashMapUnmanaged(types.PersonId, person_mod.Person) = .empty,
    units: std.AutoArrayHashMapUnmanaged(types.UnitId, unit_mod.Unit) = .empty,
    forces: std.AutoArrayHashMapUnmanaged(types.ForceId, force_mod.Force) = .empty,
    hqs: std.AutoArrayHashMapUnmanaged(types.HqId, hq_mod.Hq) = .empty,
    contracts: std.AutoArrayHashMapUnmanaged(types.ContractId, contract_mod.Contract) = .empty,
    /// Current contract market offers (replaced wholesale each refresh).
    contract_offers: std.ArrayListUnmanaged(contract_mod.Contract) = .empty,
    /// Site market board at the HQ (replaced each monthly refresh).
    market_listings: std.ArrayListUnmanaged(market_mod.Listing) = .empty,
    loans: std.ArrayListUnmanaged(finance_mod.Loan) = .empty,
    /// The outfit depot's stock (the fallback site before any HQ exists),
    /// keyed by catalog part_key.
    spare_parts: std.StringArrayHashMapUnmanaged(u32) = .empty,
    part_orders: std.ArrayListUnmanaged(part_mod.AcquisitionOrder) = .empty,
    /// Structured campaign log — newest last.
    event_log: std.ArrayListUnmanaged(LogEntry) = .empty,
    /// Stamped onto each resolved engagement, so an AAR's lines
    /// can be gathered by battle rather than by reading their prefix.
    next_battle_id: u32 = 1,
    /// Recent engagements as records; the journal owns its own
    /// retention, as `event_queue` owns the inbox's.
    battle_reports: after_action_mod.Journal = .{},
    /// Hulls the enemy dragged off a field we lost: off the books
    /// but not struck off, so a recovery raid has something to win back.
    held_hulls: std.ArrayListUnmanaged(unit_mod.HeldHull) = .empty,
    /// Money in transit between treasuries.
    fund_couriers: std.ArrayListUnmanaged(FundCourier) = .empty,
    /// Standing top-up policies, checked daily under a monthly cap.
    policies: std.ArrayListUnmanaged(StandingPolicy) = .empty,
    /// Automatic provisions resupply for deployed companies.
    supply_policies: std.ArrayListUnmanaged(SupplyPolicy) = .empty,
    stock_policies: std.ArrayListUnmanaged(StockPolicy) = .empty,
    /// Mek bay queues across all HQs.
    bay_jobs: std.ArrayListUnmanaged(BayJob) = .empty,
    /// Hiring-hall boards, churned daily.
    candidates: std.ArrayListUnmanaged(Candidate) = .empty,
    /// Supply links between HQs.
    hq_links: std.ArrayListUnmanaged(@import("network.zig").HqLink) = .empty,
    /// Units in transit between companies.
    unit_transfers: std.ArrayListUnmanaged(UnitTransfer) = .empty,
    /// Employer factions that remember a breach: thinner,
    /// cheaper offers from them until the day passes.
    faction_cooling: std.ArrayListUnmanaged(FactionCooling) = .empty,
    /// Standing with each house, −100…100; absent = 0.
    faction_standing: std.StringArrayHashMapUnmanaged(i32) = .empty,
    /// Difficulty: scales the economy and the opposition; regular
    /// is the game as tuned. Chosen in Settings, persisted per campaign.
    difficulty: difficulty_mod.Level = .regular,
    /// Event memory: when each decision kind last fired and
    /// how the player has been answering it — cooldowns and standing orders
    /// (sim/contract_events.zig).
    event_memory: std.AutoArrayHashMapUnmanaged(events_mod.EventKind, EventMemory) = .empty,
    /// Campaign counters for the summary screen: what the log
    /// remembers in aggregate. Persisted as meta ints.
    stats: Stats = .{},
    /// The Dragoons rating on every New Year's Day.
    rating_history: std.ArrayListUnmanaged(RatingSnapshot) = .empty,
    /// MekLab refit plans, staged and committed.
    refit_plans: std.ArrayListUnmanaged(RefitPlan) = .empty,

    next_person_id: u32 = 1,
    next_unit_id: u32 = 1,
    next_force_id: u32 = 1,
    next_hq_id: u32 = 1,
    next_contract_id: u32 = 1,

    pub fn init(gpa: std.mem.Allocator, config: Config) GameState {
        return .{
            .arena = std.heap.ArenaAllocator.init(gpa),
            .rng = rng_mod.Rng.init(config.seed),
            .clock = .{ .date = config.start_date },
            .funds = config.start_funds,
        };
    }

    pub fn deinit(self: *GameState) void {
        self.arena.deinit();
    }

    /// All campaign-lifetime allocations come from here.
    /// The difficulty row in force.
    pub fn diff(self: *const GameState) *const difficulty_mod.Row {
        return difficulty_mod.get(self.difficulty);
    }

    /// Scratch that is freed before the caller returns (a per-call arena,
    /// a temporary map): the campaign arena's backing allocator, so the
    /// memory really comes back. Anything that outlives the call uses
    /// `allocator()`.
    pub fn scratch(self: *GameState) std.mem.Allocator {
        return self.arena.child_allocator;
    }

    pub fn allocator(self: *GameState) std.mem.Allocator {
        return self.arena.allocator();
    }

    // ---------------------------------------------------------------- money

    /// Post to the outfit's central treasury (the common case).
    pub fn postTransaction(self: *GameState, txn: finance_mod.Transaction) !void {
        try self.postTreasury(.outfit, txn);
    }

    /// The only way money moves: ledger entry + the named treasury's balance,
    /// in lockstep. Balances MAY go negative (obligations don't wait);
    /// purchases that should refuse instead go through `treasury.debit`.
    pub fn postTreasury(self: *GameState, treasury: Treasury, txn: finance_mod.Transaction) !void {
        try self.ledger.post(self.allocator(), txn);
        switch (treasury) {
            .outfit => self.funds += txn.amount,
            .hq => |id| if (self.hqs.getPtr(id)) |h| {
                h.funds += txn.amount;
            },
            .company => |id| if (self.forces.getPtr(id)) |f| {
                f.local_funds += txn.amount;
            },
        }
    }

    pub fn treasuryBalance(self: *GameState, treasury: Treasury) types.CBills {
        return switch (treasury) {
            .outfit => self.funds,
            .hq => |id| if (self.hqs.getPtr(id)) |h| h.funds else 0,
            .company => |id| if (self.forces.getPtr(id)) |f| f.local_funds else 0,
        };
    }

    // ---------------------------------------------------------------- people

    /// Hire with default skills for the role at Regular experience.
    pub fn hirePerson(self: *GameState, first: []const u8, last: []const u8, role: person_mod.Role) !types.PersonId {
        const id: types.PersonId = @enumFromInt(self.next_person_id);
        self.next_person_id += 1;

        var p: person_mod.Person = .{
            .id = id,
            .first_name = try self.allocator().dupe(u8, first),
            .last_name = try self.allocator().dupe(u8, last),
            .role = role,
            .recruited_day = self.clock.day_index,
        };
        const alloc = self.allocator();
        switch (role) {
            .mekwarrior => {
                try p.skills.put(alloc, .gunnery_mek, 4);
                try p.skills.put(alloc, .piloting_mek, 5);
            },
            .vehicle_crew => {
                try p.skills.put(alloc, .gunnery_vee, 4);
                try p.skills.put(alloc, .driving_vee, 5);
            },
            .aero_pilot => {
                try p.skills.put(alloc, .gunnery_aero, 4);
                try p.skills.put(alloc, .piloting_aero, 5);
            },
            .tech_mek, .tech_ba => try p.skills.put(alloc, .tech_mek, 4),
            .tech_mechanic => try p.skills.put(alloc, .tech_mechanic, 4),
            .tech_aero => try p.skills.put(alloc, .tech_aero, 4),
            .astech => try p.skills.put(alloc, .astech, 4),
            .doctor => try p.skills.put(alloc, .doctor, 4),
            .medic => try p.skills.put(alloc, .medtech, 4),
            .admin_command, .admin_logistics, .admin_transport, .admin_hr, .admin_finance => try p.skills.put(alloc, .admin, 4),
            .ba_trooper, .infantry => try p.skills.put(alloc, .small_arms, 4),
            .dropship_crew, .jumpship_crew => {},
        }
        try self.people.put(alloc, id, p);
        return id;
    }

    pub fn person(self: *GameState, id: types.PersonId) ?*person_mod.Person {
        return self.people.getPtr(id);
    }

    // --------------------------------------------- character creation & HQ

    pub const CreateCommanderError = error{ CommanderExists, NoHomeWorld } || std.mem.Allocator.Error;

    /// Character creation: the commander's origin picks the starter world
    /// (weighted-random in their faction's space) and stands up the starter
    /// regional HQ there with modest level-1 facilities.
    pub fn createCommander(
        self: *GameState,
        name: []const u8,
        origin: commander_mod.Faction,
        profession: commander_mod.Profession,
    ) CreateCommanderError!types.HqId {
        if (self.commander != null) return error.CommanderExists;
        const world = planet_mod.weightedPickByFaction(&self.rng, .generation, origin.key()) orelse return error.NoHomeWorld;

        self.commander = .{
            .name = try self.allocator().dupe(u8, name),
            .origin = origin,
            .profession = profession,
        };

        const id: types.HqId = @enumFromInt(self.next_hq_id);
        self.next_hq_id += 1;
        var hq: hq_mod.Hq = .{
            .id = id,
            .name = try std.fmt.allocPrint(self.allocator(), "{s} Regional HQ", .{world.name}),
            .tier = .regional,
            .planet_key = world.key,
            .monthly_upkeep = hq_mod.HqTier.regional.monthlyUpkeep(),
        };
        const starter_facilities = [_]hq_mod.FacilityKind{ .mek_bay, .warehouse, .hospital, .mess, .comms, .spaceport, .hiring_hall, .training_ground };
        for (starter_facilities) |kind| {
            try hq.facilities.append(self.allocator(), .{ .kind = kind, .level = 1 });
        }
        const req = hq.staffRequired();
        try self.hqs.put(self.allocator(), id, hq);

        // The back office is people: recruit the starter HQ's
        // staff to requirement and post them. Their payroll is the tail.
        const staff_plan = [_]struct { person_mod.Role, u32 }{
            .{ .admin_command, req.admin },                           .{ .admin_logistics, req.logistics / 2 },
            .{ .admin_transport, req.logistics - req.logistics / 2 }, .{ .admin_hr, req.hr },
            .{ .admin_finance, req.finance },
        };
        for (staff_plan) |entry| {
            for (0..entry[1]) |_| {
                const pid = try @import("personnel.zig").recruitGenerated(self, entry[0], id, .generation);
                self.person(pid).?.posted_hq = id;
            }
        }
        @import("hq_ops.zig").refreshHqStaffing(self);

        // Founding capital: the HQ opens with its own operating treasury,
        // handed over on-site (no courier).
        @import("treasury.zig").transferFunds(self, .outfit, .{ .hq = id }, tuning.hq.founding_funds, 0) catch |err| switch (err) {
            // An outfit that cannot cover the founding capital opens the HQ
            // with an empty treasury.
            error.InsufficientTreasury => {},
            error.OutOfMemory => return error.OutOfMemory,
        };

        // Standing defaults the player can clear, so a hands-off outfit keeps
        // its HQ solvent and fed: the outfit tops the HQ up on payday, and
        // the warehouse keeps provisions stocked.
        try self.policies.append(self.allocator(), .{ .entity = .{ .hq = id }, .floor = tuning.finance.hq_policy_floor, .monthly_cap = tuning.finance.hq_policy_cap });
        try self.stock_policies.append(self.allocator(), .{ .hq = id, .part_key = "provisions", .min = tuning.generation.provisions_keep_min, .target = tuning.generation.provisions_keep_target });

        // A modestly stocked warehouse to start.
        const site: types.Site = .{ .hq = id };
        const g = tuning.generation;
        try self.addStock(site, "provisions", g.starter_provisions);
        try self.addStock(site, "medical_supplies", g.starter_medical);
        try self.addStock(site, "armor", g.starter_armor);
        for (part_mod.component_keys) |key| try self.addStock(site, key, g.starter_components_each);
        for (part_mod.munition_keys) |key| try self.addStock(site, key, g.starter_munitions_each);
        return id;
    }

    // ------------------------------------- the HQ network

    pub const FoundError = error{ UnknownPlanet, NotReachable } || std.mem.Allocator.Error;

    /// Stand up an HQ on a world. Field HQs open with a bay, a warehouse
    /// and a mess; regional ones add comms, a spaceport, a hospital and a
    /// hiring hall. Staffing is the player's problem from day one.
    pub fn foundHq(self: *GameState, name: []const u8, tier: hq_mod.HqTier, planet_key: []const u8) FoundError!types.HqId {
        const hq = try self.prepareHq(name, tier, planet_key);
        try self.hqs.ensureUnusedCapacity(self.allocator(), 1);
        return self.commitHq(hq);
    }

    /// Room for `n` more ledger entries, so the next `n` postings cannot
    /// fail.
    pub fn reserveLedger(self: *GameState, n: usize) !void {
        try self.ledger.transactions.ensureUnusedCapacity(self.allocator(), n);
    }

    /// Put a prepared HQ on the books under the next id. Cannot fail once
    /// `hqs` has room for it.
    pub fn commitHq(self: *GameState, prepared: hq_mod.Hq) types.HqId {
        var hq = prepared;
        hq.id = @enumFromInt(self.next_hq_id);
        self.next_hq_id += 1;
        self.hqs.putAssumeCapacity(hq.id, hq);
        return hq.id;
    }

    /// A new HQ with every allocation done but no id and nothing on the
    /// books; `commitHq` registers it.
    pub fn prepareHq(self: *GameState, name: []const u8, tier: hq_mod.HqTier, planet_key: []const u8) FoundError!hq_mod.Hq {
        const world = planet_mod.find(planet_key) orelse return error.UnknownPlanet;
        var hq: hq_mod.Hq = .{
            .id = .none,
            .name = try self.allocator().dupe(u8, name),
            .tier = tier,
            .planet_key = world.key,
            .monthly_upkeep = tier.monthlyUpkeep(),
        };
        const base = [_]hq_mod.FacilityKind{ .mek_bay, .warehouse, .mess };
        for (base) |kind| try hq.facilities.append(self.allocator(), .{ .kind = kind, .level = 1 });
        if (tier != .field) {
            const more = [_]hq_mod.FacilityKind{ .comms, .spaceport, .hospital, .hiring_hall, .training_ground };
            for (more) |kind| try hq.facilities.append(self.allocator(), .{ .kind = kind, .level = 1 });
        }
        return hq;
    }

    /// The HQ that supplies a force: its company's assignment, else the
    /// first HQ (the outfit's seat).
    pub fn homeHqFor(self: *GameState, force_id: types.ForceId) types.HqId {
        const co = self.companyOf(force_id);
        if (self.forces.getPtr(co)) |f| {
            if (f.supplying_hq != .none and self.hqs.getPtr(f.supplying_hq) != null) return f.supplying_hq;
        }
        return if (self.hqs.count() > 0) self.hqs.keys()[0] else .none;
    }

    /// The HQ a person lives at: the one they are posted to, else their
    /// company's home HQ. Training and weekly rest read this.
    pub fn homeHqOf(self: *GameState, p: *const person_mod.Person) types.HqId {
        if (p.posted_hq != .none and self.hqs.getPtr(p.posted_hq) != null) return p.posted_hq;
        return self.homeHqFor(p.assigned_force);
    }

    /// The HQ whose training ground a person trains at: their home HQ,
    /// when it has one (`Hq.supportsTraining`).
    pub fn trainingHqFor(self: *GameState, p: *const person_mod.Person) ?types.HqId {
        const id = self.homeHqOf(p);
        const hq = self.hqs.getPtr(id) orelse return null;
        return if (hq.supportsTraining()) id else null;
    }

    /// Transports of one kind holding a berth at an HQ.
    pub fn transportsBerthedAt(self: *GameState, hq_id: types.HqId, kind: unit_mod.UnitKind) u32 {
        var n: u32 = 0;
        var it = self.units.iterator();
        while (it.next()) |entry| {
            const u = entry.value_ptr;
            if (u.kind == kind and u.berth_hq == hq_id and u.status != .destroyed) n += 1;
        }
        return n;
    }

    /// A ship is fit to sail when it is berthed, ready, crewed and not
    /// already carrying a company (its `force` is set for the tour).
    pub fn transportAvailable(self: *GameState, u: *const unit_mod.Unit) bool {
        if (!u.kind.isTransport() or u.status != .ready or u.force != .none) return false;
        const crew = self.person(u.pilot) orelse return false;
        return crew.isAvailable(self.clock.day_index);
    }

    pub const Lift = struct {
        mek: u32 = 0,
        asf: u32 = 0,
        vehicle: u32 = 0,
        cargo_tons: u32 = 0,
        dropships: u32 = 0,
        jumpship_collars: u32 = 0,
    };

    /// What the crewed, idle ships berthed at an HQ can lift.
    pub fn availableLift(self: *GameState, hq_id: types.HqId) Lift {
        var lift: Lift = .{};
        var it = self.units.iterator();
        while (it.next()) |entry| {
            const u = entry.value_ptr;
            if (u.berth_hq != hq_id or !self.transportAvailable(u)) continue;
            const design = chassis_mod.find(u.chassis_key) orelse continue;
            switch (u.kind) {
                .dropship => {
                    lift.mek += design.mek_bays;
                    lift.asf += design.asf_bays;
                    lift.vehicle += design.vehicle_bays;
                    lift.cargo_tons += design.cargo_tons;
                    lift.dropships += 1;
                },
                .jumpship => lift.jumpship_collars += design.collars,
                else => {},
            }
        }
        return lift;
    }

    /// A crewed jumpship berthed at either end of a link (the dedicated
    /// line of a level-3 supply link, GAMEPLAY "requires owning one").
    pub fn ownsCrewedJumpshipAt(self: *GameState, a: types.HqId, b: types.HqId) bool {
        var it = self.units.iterator();
        while (it.next()) |entry| {
            const u = entry.value_ptr;
            if (u.kind != .jumpship or (u.berth_hq != a and u.berth_hq != b)) continue;
            if (u.status == .destroyed) continue;
            const crew = self.person(u.pilot) orelse continue;
            if (crew.isAvailable(self.clock.day_index)) return true;
        }
        return false;
    }

    /// Commander cost multiplier for a category (neutral without a commander).
    pub fn commanderMultBp(self: *const GameState, kind: commander_mod.BonusKind) types.Bp {
        const c = self.commander orelse return 10_000;
        return c.costMultBp(kind);
    }

    /// Append a tagged, formatted entry (with the campaign date) to the log.
    pub fn log(self: *GameState, category: LogCategory, ctx: LogCtx, comptime fmt: []const u8, args: anytype) !void {
        var date_buf: [10]u8 = undefined;
        const line = try std.fmt.allocPrint(
            self.allocator(),
            "{s} " ++ fmt,
            .{self.clock.date.text(&date_buf)} ++ args,
        );
        try self.event_log.append(self.allocator(), .{
            .day = self.clock.day_index,
            .category = category,
            .company = ctx.company,
            .hq = ctx.hq,
            .contract = ctx.contract,
            .text = line,
        });
    }

    // ------------------------------------------- physical stock
    // Stock lives at sites: the outfit's fallback depot (pre-HQ), each HQ's
    // warehouse (capped by warehouse level), each deployed company's field
    // stores (capped by its logistics trucks). Pallets have tonnage.

    pub fn stockMap(self: *GameState, site: types.Site) ?*std.StringArrayHashMapUnmanaged(u32) {
        return switch (site) {
            .outfit => &self.spare_parts,
            .hq => |id| if (self.hqs.getPtr(id)) |h| &h.stock else null,
            .company => |id| if (self.forces.getPtr(id)) |f| &f.stock else null,
        };
    }

    /// The outfit's seat: first HQ, or the outfit depot before any exists.
    pub fn defaultSite(self: *GameState) types.Site {
        return if (self.hqs.count() > 0) .{ .hq = self.hqs.keys()[0] } else .outfit;
    }

    /// A force's home warehouse: its supplying HQ, else the seat.
    pub fn homeSiteFor(self: *GameState, force_id: types.ForceId) types.Site {
        const hq = self.homeHqFor(force_id);
        return if (hq != .none) .{ .hq = hq } else .outfit;
    }

    /// Where a company stands (ARCH §9.7): the one cascade every screen,
    /// warning and refusal reads. Contract first (en route, then on
    /// station), then the road home, then a world it idles on, else home.
    pub const CompanyPosture = union(enum) {
        home,
        en_route: *contract_mod.Contract,
        deployed: *contract_mod.Contract,
        returning: u32, // arrival day
        idle_afield: []const u8, // planet key
    };

    pub fn companyPosture(self: *GameState, company: types.ForceId) CompanyPosture {
        if (self.deploymentContract(company)) |c| return if (c.status == .transit) .{ .en_route = c } else .{ .deployed = c };
        const f = self.forces.getPtr(company) orelse return .home;
        if (f.return_eta_day) |eta| return .{ .returning = eta };
        if (f.location_planet) |p| return .{ .idle_afield = p };
        return .home;
    }

    /// Is the company physically at its home HQ (not deployed, not idling
    /// on a contract world, not travelling)?
    pub fn isCompanyHome(self: *GameState, company: types.ForceId) bool {
        return self.companyPosture(company) == .home;
    }

    /// Out on a contract (en route or on station). Not the opposite of
    /// home: a company returning or idling afield is neither.
    pub fn isCompanyDeployed(self: *GameState, company: types.ForceId) bool {
        return self.deploymentContract(company) != null;
    }

    /// Ready to act today: the hull can take the field and its crew is fit
    /// for duty. Support modifiers, MASH beds, the battle line and
    /// fieldable strength all count hulls by this test.
    pub fn unitOperational(self: *GameState, u: *const unit_mod.Unit) bool {
        if (!u.canFight()) return false;
        const crew = self.person(u.pilot) orelse return false;
        return crew.isAvailable(self.clock.day_index);
    }

    /// At least one of the force's own hulls is operational.
    pub fn forceOperational(self: *GameState, f: *const force_mod.Force) bool {
        for (f.units.items) |uid| {
            const u = self.unit(uid) orelse continue;
            if (self.unitOperational(u)) return true;
        }
        return false;
    }

    /// Does the outfit hold a prisoner of this house (a trade is possible)?
    pub fn holdsPrisonerOf(self: *GameState, faction: []const u8) bool {
        var it = self.people.iterator();
        while (it.next()) |e| if (e.value_ptr.status == .pow and std.mem.eql(u8, e.value_ptr.faction, faction)) return true;
        return false;
    }

    /// Contracts the outfit has taken on a world (offers excepted).
    pub fn contractsWorkedAt(self: *GameState, planet_key: []const u8) u32 {
        var n: u32 = 0;
        for (self.contracts.values()) |c| if (std.mem.eql(u8, c.planet_key, planet_key) and c.status != .offer) {
            n += 1;
        };
        return n;
    }

    /// A crewed dropship in the company's own hangar: it lifts and escorts
    /// the company on the way in.
    pub fn hasCrewedDropship(self: *GameState, company: types.ForceId) bool {
        var it = self.units.iterator();
        while (it.next()) |e| {
            const u = e.value_ptr;
            if (u.kind == .dropship and u.force == company and u.pilot != .none) return true;
        }
        return false;
    }

    pub fn standing(self: *GameState, faction: []const u8) i32 {
        return self.faction_standing.get(faction) orelse 0;
    }

    /// Move a house's standing by `delta`, clamped to ±100; logged by the caller.
    pub fn adjustStanding(self: *GameState, faction: []const u8, delta: i32) !i32 {
        const now = std.math.clamp(self.standing(faction) + delta, -100, 100);
        const g = try self.faction_standing.getOrPut(self.allocator(), faction);
        if (!g.found_existing) g.key_ptr.* = try self.allocator().dupe(u8, faction);
        g.value_ptr.* = now;
        return now;
    }

    /// Is this employer faction still cooling after a breach?
    pub fn factionCooling(self: *GameState, faction: []const u8) bool {
        for (self.faction_cooling.items) |fc| {
            if (std.mem.eql(u8, fc.faction, faction) and self.clock.day_index < fc.until_day) return true;
        }
        return false;
    }

    pub fn addStock(self: *GameState, site: types.Site, key: []const u8, qty: u32) !void {
        const map = self.stockMap(site) orelse return;
        const entry = try map.getOrPut(self.allocator(), key);
        if (!entry.found_existing) entry.value_ptr.* = 0;
        entry.value_ptr.* += qty;
    }

    /// Take from a site's stock; false if not enough on hand.
    pub fn takeStock(self: *GameState, site: types.Site, key: []const u8, qty: u32) bool {
        const map = self.stockMap(site) orelse return false;
        const current = map.getPtr(key) orelse return false;
        if (current.* < qty) return false;
        current.* -= qty;
        return true;
    }

    pub fn stockCount(self: *GameState, site: types.Site, key: []const u8) u32 {
        const map = self.stockMap(site) orelse return 0;
        return map.get(key) orelse 0;
    }

    // Convenience wrappers on the seat's stock (`defaultSite`).
    pub fn addSpare(self: *GameState, part_key: []const u8, qty: u32) !void {
        try self.addStock(self.defaultSite(), part_key, qty);
    }
    pub fn takeSpare(self: *GameState, part_key: []const u8, qty: u32) bool {
        return self.takeStock(self.defaultSite(), part_key, qty);
    }
    pub fn spareCount(self: *GameState, part_key: []const u8) u32 {
        return self.stockCount(self.defaultSite(), part_key);
    }

    // ----------------------------------------------------- deployment info

    /// The company a force belongs to (itself, an ancestor, or .none).
    pub fn companyOf(self: *GameState, force_id: types.ForceId) types.ForceId {
        var f = force_id;
        while (f != .none) {
            const node = self.forces.getPtr(f) orelse return .none;
            if (node.echelon == .company) return f;
            f = node.parent;
        }
        return .none;
    }

    /// The contract a company is currently out on (transit or active).
    pub fn deploymentContract(self: *GameState, company_id: types.ForceId) ?*contract_mod.Contract {
        if (company_id == .none) return null;
        var it = self.contracts.iterator();
        while (it.next()) |entry| {
            const c = entry.value_ptr;
            if (c.assigned_company == company_id and c.isRunning()) return c;
        }
        return null;
    }

    // ------------------------------------------------------ units & forces

    pub const AddUnitError = error{UnknownChassis} || std.mem.Allocator.Error;

    /// Instantiate a unit from the chassis catalog: structure slots for all
    /// eight mek locations plus the design's loadout slots — so battle
    /// damage and repair tiers (ARCH §9.7) have real targets from day one.
    pub fn addUnit(self: *GameState, chassis_key: []const u8) AddUnitError!types.UnitId {
        const design = chassis_mod.find(chassis_key) orelse return error.UnknownChassis;
        const id: types.UnitId = @enumFromInt(self.next_unit_id);
        self.next_unit_id += 1;

        var u: unit_mod.Unit = .{
            .id = id,
            .chassis_key = design.key, // catalog memory is static
            .kind = design.kind,
            .acquired_day = self.clock.day_index,
            .purchase_price = design.cost,
        };
        const alloc = self.allocator();
        if (design.kind == .mek) {
            const locations = [_][]const u8{ "hd", "ct", "lt", "rt", "la", "ra", "ll", "rl" };
            for (locations) |loc| {
                try u.slots.append(alloc, .{
                    .slot_key = try std.fmt.allocPrint(alloc, "{s}.{s}", .{ loc, part_mod.structure_key }),
                    .part_key = part_mod.structure_key,
                    .class = .structure,
                });
            }
        } else {
            try u.slots.append(alloc, .{
                .slot_key = "chassis.structure",
                .part_key = part_mod.structure_key,
                .class = .structure,
            });
        }
        for (design.loadout) |l| {
            try u.slots.append(alloc, .{ .slot_key = l.slot, .part_key = l.part, .class = l.class });
        }
        try self.units.put(alloc, id, u);
        return id;
    }

    pub fn unit(self: *GameState, id: types.UnitId) ?*unit_mod.Unit {
        return self.units.getPtr(id);
    }

    /// Make a freshly bought hull match its listing's condition: armor, quality, broken weapons, and missing structure —
    /// the project the player just bought.
    pub fn applyHullCondition(self: *GameState, unit_id: types.UnitId, cond: market_mod.HullCondition) void {
        const u = self.unit(unit_id) orelse return;
        u.armor_pct = cond.armor_pct;
        u.quality = cond.quality;
        const r = self.rng.random(.market);
        var to_damage = cond.damaged_slots;
        var to_destroy = cond.destroyed_slots;
        var to_strip = cond.missing_components;
        // Walk slots in a rolled order so different wrecks break differently.
        var start = r.uintLessThan(usize, @max(1, u.slots.items.len));
        for (0..u.slots.items.len) |_| {
            const slot = &u.slots.items[start % u.slots.items.len];
            start += 1;
            if (slot.class == .structure) {
                if (to_strip > 0 and !std.mem.startsWith(u8, slot.slot_key, "hd.")) {
                    slot.condition = .missing;
                    to_strip -= 1;
                }
            } else if (slot.class == .weapon) {
                if (to_destroy > 0) {
                    slot.condition = .destroyed;
                    to_destroy -= 1;
                } else if (to_damage > 0) {
                    slot.condition = .damaged;
                    to_damage -= 1;
                }
            }
        }
        if (u.needsDepot()) u.status = .damaged;
    }

    pub fn createForce(self: *GameState, name: []const u8, echelon: force_mod.Echelon, parent: types.ForceId) !types.ForceId {
        const id: types.ForceId = @enumFromInt(self.next_force_id);
        self.next_force_id += 1;
        try self.forces.put(self.allocator(), id, .{
            .id = id,
            .parent = parent,
            .name = try self.allocator().dupe(u8, name),
            .echelon = echelon,
        });
        if (self.force(parent)) |p| try p.children.append(self.allocator(), id);
        return id;
    }

    pub fn force(self: *GameState, id: types.ForceId) ?*force_mod.Force {
        return self.forces.getPtr(id);
    }

    // ------------------------------------------- the MekLab

    pub fn refitPlanFor(self: *GameState, unit_id: types.UnitId) ?*RefitPlan {
        for (self.refit_plans.items) |*p| {
            if (p.unit == unit_id) return p;
        }
        return null;
    }

    pub fn refitPlanOrCreate(self: *GameState, unit_id: types.UnitId) !*RefitPlan {
        if (self.refitPlanFor(unit_id)) |p| return p;
        try self.refit_plans.append(self.allocator(), .{ .unit = unit_id });
        return &self.refit_plans.items[self.refit_plans.items.len - 1];
    }

    /// The rules' verdict on putting `part_key` at `loc` on top of the
    /// hull's current plan (the Lab's location picker and the commit share it).
    pub fn tryInstall(self: *GameState, alloc: std.mem.Allocator, unit_id: types.UnitId, loc: meklab.Location, part_key: []const u8) !meklab.Report {
        const u = self.unit(unit_id) orelse return error.UnknownUnit;
        const design = @import("../domain/chassis.zig").find(u.chassis_key) orelse return error.UnknownChassis;
        const base = try self.labItems(unit_id, alloc);
        var items = try alloc.alloc(meklab.Item, base.len + 1);
        @memcpy(items[0..base.len], base);
        items[base.len] = .{ .location = loc, .part_key = part_key };
        return meklab.validate(design, items, alloc);
    }

    /// The hull's mounted items with a plan's edits applied (what the lab
    /// validates). `alloc` owns the result.
    pub fn labItems(self: *GameState, unit_id: types.UnitId, alloc: std.mem.Allocator) ![]meklab.Item {
        const u = self.unit(unit_id) orelse return &.{};
        var out: std.ArrayListUnmanaged(meklab.Item) = .empty;
        const plan = self.refitPlanFor(unit_id);
        for (u.slots.items) |s| {
            if (s.class == .structure) continue;
            if (plan) |p| {
                var removed = false;
                for (p.ops.items) |op| {
                    if (op == .remove and std.mem.eql(u8, op.remove, s.slot_key)) removed = true;
                }
                if (removed) continue;
            }
            const loc = meklab.parseLocation(s.slot_key) orelse continue;
            try out.append(alloc, .{ .location = loc, .part_key = s.part_key });
        }
        if (plan) |p| {
            for (p.ops.items) |op| {
                if (op == .install) try out.append(alloc, op.install);
            }
        }
        return out.toOwnedSlice(alloc);
    }

    /// Apply a committed plan to the hull: removed mounts come off (and
    /// return to the site's stock), installs become new slots.
    pub fn applyRefit(self: *GameState, plan: *const RefitPlan, site: types.Site) !void {
        const u = self.unit(plan.unit) orelse return;
        const alloc = self.allocator();
        for (plan.ops.items) |op| {
            switch (op) {
                .remove => |slot_key| {
                    for (u.slots.items, 0..) |s, i| {
                        if (std.mem.eql(u8, s.slot_key, slot_key)) {
                            if (s.condition == .ok) try self.addStock(site, s.part_key, 1);
                            _ = u.slots.orderedRemove(i);
                            break;
                        }
                    }
                },
                .install => |it| {
                    const def = part_mod.find(it.part_key) orelse continue;
                    var n: u32 = 1;
                    for (u.slots.items) |s| {
                        if (std.mem.startsWith(u8, s.slot_key, @tagName(it.location)) and std.mem.indexOf(u8, s.slot_key, def.key) != null) n += 1;
                    }
                    try u.slots.append(alloc, .{
                        .slot_key = try std.fmt.allocPrint(alloc, "{s}.{s}.{d}", .{ @tagName(it.location), def.key, n }),
                        .part_key = def.key,
                        .class = switch (def.mount) {
                            .ammo => .ammo,
                            .equipment => .equipment,
                            else => .weapon,
                        },
                    });
                },
            }
        }
    }

    /// The hull a pilot currently sits in.
    pub fn pilotSeat(self: *GameState, person_id: types.PersonId) types.UnitId {
        var it = self.units.iterator();
        while (it.next()) |entry| {
            if (entry.value_ptr.pilot == person_id) return entry.value_ptr.id;
        }
        return .none;
    }

    /// The next engagement's id; never reused within a campaign.
    pub fn nextBattleId(self: *GameState) types.BattleId {
        const id: types.BattleId = @enumFromInt(self.next_battle_id);
        self.next_battle_id += 1;
        return id;
    }

    /// Raise the battle counter past every battle a report, a held hull or
    /// a pending decision names, so a new engagement cannot reuse an id
    /// that is still referenced.
    pub fn resumeBattleIds(self: *GameState) void {
        var max: u32 = 0;
        for (self.battle_reports.kept.items) |r| max = @max(max, @intFromEnum(r.id));
        for (self.held_hulls.items) |h| max = @max(max, @intFromEnum(h.battle));
        for (self.event_queue.pending.items) |ev| max = @max(max, @intFromEnum(ev.battle));
        self.next_battle_id = @max(self.next_battle_id, max + 1);
    }

    /// Strike a hull from the books: seats open, bay work and refit plans
    /// for it vanish, its force forgets it.
    pub fn removeUnit(self: *GameState, unit_id: types.UnitId) void {
        self.detachUnit(unit_id);
        _ = self.units.orderedRemove(unit_id);
    }

    /// The enemy dragged this hull off a field we lost: it leaves
    /// the books exactly as `removeUnit` would — no bill, no bay, no
    /// lance, invisible to every walker over `units` — but the hull
    /// itself is kept in `held_hulls`, because a recovery raid can win it
    /// back. The crew slots are cleared: our
    /// people are not in it any more, whatever became of them.
    pub fn holdUnit(self: *GameState, unit_id: types.UnitId, by: []const u8, battle: types.BattleId) !void {
        self.detachUnit(unit_id);
        var entry = self.units.fetchOrderedRemove(unit_id) orelse return;
        const from_force = entry.value.force;
        entry.value.force = .none;
        entry.value.pilot = .none;
        entry.value.tech = .none;
        try self.held_hulls.append(self.allocator(), .{
            .unit = entry.value,
            .by = by,
            .day = self.clock.day_index,
            .battle = battle,
            .from_force = from_force,
        });
    }

    /// Won back: the hull comes off the limbo list and onto the
    /// books, back in the lance it was taken from if that lance still
    /// exists. It comes back as it left — a wreck for the depot, not a
    /// runner. Returns false if nobody holds that hull.
    pub fn releaseHull(self: *GameState, unit_id: types.UnitId) !bool {
        const i = blk: {
            for (self.held_hulls.items, 0..) |h, n| if (h.unit.id == unit_id) break :blk n;
            return false;
        };
        var held = self.held_hulls.orderedRemove(i);
        if (self.forces.getPtr(held.from_force)) |f| {
            held.unit.force = held.from_force;
            try f.units.append(self.allocator(), unit_id);
        }
        try self.units.put(self.allocator(), unit_id, held.unit);
        return true;
    }

    /// The hull the enemy holds under this id, if they hold it.
    pub fn heldHull(self: *const GameState, unit_id: types.UnitId) ?*const unit_mod.HeldHull {
        for (self.held_hulls.items) |*h| if (h.unit.id == unit_id) return h;
        return null;
    }

    /// Everything that points at a hull lets go of it. Shared by striking
    /// one off and by losing one to the enemy, so the two can never drift.
    fn detachUnit(self: *GameState, unit_id: types.UnitId) void {
        if (self.forces.getPtr(if (self.unit(unit_id)) |u| u.force else .none)) |f| {
            for (f.units.items, 0..) |id, i| if (id == unit_id) {
                _ = f.units.orderedRemove(i);
                break;
            };
        }
        var i: usize = 0;
        while (i < self.bay_jobs.items.len) {
            if (self.bay_jobs.items[i].unit == unit_id) _ = self.bay_jobs.orderedRemove(i) else i += 1;
        }
        i = 0;
        while (i < self.refit_plans.items.len) {
            if (self.refit_plans.items[i].unit == unit_id) _ = self.refit_plans.orderedRemove(i) else i += 1;
        }
        i = 0;
        while (i < self.unit_transfers.items.len) {
            if (self.unit_transfers.items[i].unit == unit_id) _ = self.unit_transfers.orderedRemove(i) else i += 1;
        }
    }

    // ------------------------------------------------------- golden master

    /// What happens to a field across a save (rule 45). Persisted: saved and
    /// restored exactly. Derived: rebuilt on load from persisted owners.
    /// Session: lives only while the campaign is open and cannot change an
    /// outcome. Scratch: never outlives the operation that fills it.
    pub const Persistence = enum { persisted, derived, session, scratch };

    /// Every `GameState` field and its persistence class: a field missing
    /// here, or a name that is no field, is a compile error. The golden
    /// master hashes the persisted and derived ones. Values derived inside a
    /// persisted owner (an HQ's staffing counts) are rebuilt by the loader,
    /// and the round-trip digest proves they come back the same.
    pub const field_persistence = [_]struct { []const u8, Persistence }{
        .{ "arena", .session }, // the memory the campaign lives in
        .{ "campaign_id", .session }, // the save store's row, not the campaign
        .{ "rng", .persisted },
        .{ "clock", .persisted },
        .{ "funds", .persisted },
        .{ "reputation", .persisted },
        .{ "outfit_name", .persisted },
        .{ "commander", .persisted },
        .{ "bankrupt", .persisted },
        .{ "auto_admit", .persisted },
        .{ "share_profit_bp", .persisted },
        .{ "ledger", .persisted },
        .{ "event_queue", .persisted },
        .{ "people", .persisted },
        .{ "units", .persisted },
        .{ "forces", .persisted },
        .{ "hqs", .persisted },
        .{ "contracts", .persisted },
        .{ "contract_offers", .persisted },
        .{ "market_listings", .persisted },
        .{ "loans", .persisted },
        .{ "spare_parts", .persisted },
        .{ "part_orders", .persisted },
        .{ "event_log", .persisted },
        .{ "next_battle_id", .persisted },
        .{ "battle_reports", .persisted },
        .{ "held_hulls", .persisted },
        .{ "fund_couriers", .persisted },
        .{ "policies", .persisted },
        .{ "supply_policies", .persisted },
        .{ "stock_policies", .persisted },
        .{ "bay_jobs", .persisted },
        .{ "candidates", .persisted },
        .{ "hq_links", .persisted },
        .{ "unit_transfers", .persisted },
        .{ "faction_cooling", .persisted },
        .{ "faction_standing", .persisted },
        .{ "difficulty", .persisted },
        .{ "event_memory", .persisted },
        .{ "stats", .persisted },
        .{ "rating_history", .persisted },
        .{ "refit_plans", .persisted },
        .{ "next_person_id", .persisted },
        .{ "next_unit_id", .persisted },
        .{ "next_force_id", .persisted },
        .{ "next_hq_id", .persisted },
        .{ "next_contract_id", .persisted },
    };

    pub fn persistenceOf(comptime name: []const u8) Persistence {
        inline for (field_persistence) |entry| if (comptime std.mem.eql(u8, entry[0], name)) return entry[1];
        @compileError("GameState." ++ name ++ " has no persistence class in field_persistence");
    }

    comptime {
        @setEvalBranchQuota(20_000);
        for (@typeInfo(GameState).@"struct".fields) |f| _ = persistenceOf(f.name);
        for (field_persistence) |entry| if (!@hasField(GameState, entry[0])) @compileError("field_persistence names no field: " ++ entry[0]);
    }
};

test "hiring assigns role-appropriate regular skills" {
    var gs = GameState.init(std.testing.allocator, .{});
    defer gs.deinit();

    const id = try gs.hirePerson("Grayson", "Carlyle", .mekwarrior);
    const p = gs.person(id).?;
    try std.testing.expectEqual(@as(?u8, 4), p.skill(.gunnery_mek));
    try std.testing.expectEqual(types.ExperienceLevel.regular, p.experience());
    try std.testing.expectEqual(@as(types.CBills, 1_500), p.monthlySalary());
}

test "postTransaction keeps funds and ledger in lockstep" {
    var gs = GameState.init(std.testing.allocator, .{ .start_funds = 1_000_000 });
    defer gs.deinit();

    try gs.postTransaction(.{ .day = 0, .amount = -300_000, .category = .unit_purchase });
    try std.testing.expectEqual(@as(types.CBills, 700_000), gs.funds);
    try std.testing.expectEqual(@as(types.CBills, -300_000), gs.ledger.balance());
}

test "company posture is one cascade: contract, then the road home, then a world, else home" {
    var gs = GameState.init(std.testing.allocator, .{ .seed = 5 });
    defer gs.deinit();
    _ = try gs.createCommander("T", .LC, .line_officer);
    _ = try @import("starter_company.zig").generateInto(&gs, "Alpha");
    var co: types.ForceId = .none;
    var it = gs.forces.iterator();
    while (it.next()) |e| if (e.value_ptr.echelon == .company) {
        co = e.value_ptr.id;
    };
    try std.testing.expect(gs.companyPosture(co) == .home);
    try std.testing.expect(gs.isCompanyHome(co) and !gs.isCompanyDeployed(co));
    const f = gs.forces.getPtr(co).?;
    f.location_planet = "galatea";
    try std.testing.expect(gs.companyPosture(co) == .idle_afield);
    try std.testing.expect(!gs.isCompanyHome(co) and !gs.isCompanyDeployed(co));
    f.return_eta_day = 40;
    try std.testing.expect(gs.companyPosture(co) == .returning);
    try std.testing.expectEqual(@as(u32, 40), gs.companyPosture(co).returning);
}
