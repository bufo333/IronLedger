//! GameState: the one big tree the simulation systems operate on (ARCH §4).
//! Owned by an arena; pure and deterministic — no I/O, no wall clock.
//! Mirrors MekHQ's `Campaign` object, decomposed: state lives here, behavior
//! lives in the system modules (tick.zig, commands.zig, ...).

const std = @import("std");
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

/// Where money lives (Stage 9A, ARCH §11): the outfit's central treasury,
/// an HQ's funds, or a deployed company's operating fund. Spending resolves
/// where the spender stands — the treasury cannot teleport.
pub const Treasury = union(enum) {
    outfit,
    hq: types.HqId,
    company: types.ForceId,
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
};

/// Structured campaign log (Stage 9A): every entry tagged so any entity's
/// history is a filter, not an archaeology dig.
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

/// Mek bay work (Stage 9C): jobs hold a bay slot for a span of days; they
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

pub const StaffSummary = struct { count: u32 = 0, best_skill: u8 = 7 };

/// A hiring-hall candidate (Stage 9C.2): the generated person, held for
/// the player to hire (with a signing bonus) before they move on.
pub const Candidate = struct {
    hq: types.HqId,
    spec: person_gen.GeneratedPerson,
    asking_bonus: types.CBills,
    listed_day: u32,
    expires_day: u32,
};

pub const Slot = enum { pilot, tech };

pub const UnitTransfer = struct {
    unit: types.UnitId,
    to_company: types.ForceId,
    eta_day: u32,
};

pub const FactionCooling = struct {
    faction: []const u8,
    until_day: u32,
};

/// A MekLab refit plan (Stage 10): edits staged against a hull, validated
/// on demand, committed into a bay job.
pub const RefitPlan = struct {
    unit: types.UnitId,
    ops: std.ArrayListUnmanaged(meklab.RefitOp) = .empty,
    committed: bool = false,
};

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
    /// Row id in the save store's campaign registry (Stage 11); 0 = never saved.
    campaign_id: i64 = 0,
    /// Set when the treasury went negative beyond what loans and sales
    /// could cover: game over (Stage 12). Persisted; advancing refuses.
    bankrupt: bool = false,
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
    /// Outfit spare-parts pool, keyed by catalog part_key. (Per-HQ/company
    /// inventories arrive with Stage 9's supply network.)
    spare_parts: std.StringArrayHashMapUnmanaged(u32) = .empty,
    part_orders: std.ArrayListUnmanaged(part_mod.AcquisitionOrder) = .empty,
    /// Structured campaign log — newest last (Stage 9A).
    event_log: std.ArrayListUnmanaged(LogEntry) = .empty,
    /// Money in transit between treasuries.
    fund_couriers: std.ArrayListUnmanaged(FundCourier) = .empty,
    /// Standing top-up policies, executed on payday.
    policies: std.ArrayListUnmanaged(StandingPolicy) = .empty,
    /// Mek bay queues across all HQs (Stage 9C).
    bay_jobs: std.ArrayListUnmanaged(BayJob) = .empty,
    /// Hiring-hall boards (Stage 9C.2), churned daily.
    candidates: std.ArrayListUnmanaged(Candidate) = .empty,
    /// Supply links between HQs (Stage 9D).
    hq_links: std.ArrayListUnmanaged(@import("network.zig").HqLink) = .empty,
    /// Units in transit between companies (Stage 9D transfers).
    unit_transfers: std.ArrayListUnmanaged(UnitTransfer) = .empty,
    /// Employer factions that remember a breach (Stage 9E): thinner,
    /// cheaper offers from them until the day passes.
    faction_cooling: std.ArrayListUnmanaged(FactionCooling) = .empty,
    /// MekLab refit plans, staged and committed (Stage 10).
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
    /// purchases that should refuse instead call `debitOrRefuse` first.
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

    /// Ledger/log tags for a treasury, so per-entity books stay filterable.
    pub fn treasuryTags(treasury: Treasury) LogCtx {
        return switch (treasury) {
            .outfit => .{},
            .hq => |id| .{ .hq = id },
            .company => |id| .{ .company = id },
        };
    }

    pub const TransferError = error{InsufficientTreasury} || std.mem.Allocator.Error;

    /// Move money between treasuries. Source is debited immediately (refused
    /// if short); the credit travels by courier for `eta_days` (0 = instant,
    /// e.g. founding capital handed over on-site).
    pub fn transferFunds(self: *GameState, from: Treasury, to: Treasury, amount: types.CBills, eta_days: u32) TransferError!void {
        if (amount <= 0 or self.treasuryBalance(from) < amount) return error.InsufficientTreasury;
        const from_tags = treasuryTags(from);
        try self.postTreasury(from, .{
            .day = self.clock.day_index,
            .amount = -amount,
            .category = .fund_transfer,
            .company = from_tags.company,
            .hq = from_tags.hq,
            .note = "funds dispatched",
        });
        if (eta_days == 0) {
            try self.creditTreasury(to, amount);
        } else {
            try self.fund_couriers.append(self.allocator(), .{
                .to = to,
                .amount = amount,
                .sent_day = self.clock.day_index,
                .eta_day = self.clock.day_index + eta_days,
            });
        }
    }

    pub fn creditTreasury(self: *GameState, to: Treasury, amount: types.CBills) !void {
        const tags = treasuryTags(to);
        try self.postTreasury(to, .{
            .day = self.clock.day_index,
            .amount = amount,
            .category = .fund_transfer,
            .company = tags.company,
            .hq = tags.hq,
            .note = "funds received",
        });
    }

    // ---------------------------------------------------------------- people

    /// Hire with default skills for the role at Regular experience.
    /// (Stage 2: markets offer generated candidates instead.)
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

    /// Recruit a randomly generated person (AtB-style: experience on 2d6,
    /// skills from the band, names from the tables). Stage 4+: candidates
    /// come through the personnel market with signing bonuses instead.
    pub fn recruitGenerated(self: *GameState, role: person_mod.Role) !types.PersonId {
        const spec = person_gen.generateWithBonus(&self.rng, role, self.recruitBonus());
        return self.hireFromSpec(spec);
    }

    /// Put a generated person on the books (recruiting, or hiring a
    /// hall candidate).
    pub fn hireFromSpec(self: *GameState, spec: person_gen.GeneratedPerson) !types.PersonId {
        const role = spec.role;
        const id = try self.hirePerson(spec.first, spec.last, role);
        const p = self.person(id).?;
        if (spec.callsign) |c| p.callsign = try self.allocator().dupe(u8, c);

        // Overwrite the hire defaults with the generated experience band.
        const alloc = self.allocator();
        switch (role) {
            .mekwarrior => {
                try p.skills.put(alloc, .gunnery_mek, spec.primary_skill);
                try p.skills.put(alloc, .piloting_mek, spec.secondary_skill);
            },
            .vehicle_crew => {
                try p.skills.put(alloc, .gunnery_vee, spec.primary_skill);
                try p.skills.put(alloc, .driving_vee, spec.secondary_skill);
            },
            .aero_pilot => {
                try p.skills.put(alloc, .gunnery_aero, spec.primary_skill);
                try p.skills.put(alloc, .piloting_aero, spec.secondary_skill);
            },
            .ba_trooper, .infantry => try p.skills.put(alloc, .small_arms, spec.primary_skill),
            .tech_mek, .tech_ba => try p.skills.put(alloc, .tech_mek, spec.primary_skill),
            .tech_mechanic => try p.skills.put(alloc, .tech_mechanic, spec.primary_skill),
            .tech_aero => try p.skills.put(alloc, .tech_aero, spec.primary_skill),
            .astech => try p.skills.put(alloc, .astech, spec.primary_skill),
            .doctor => try p.skills.put(alloc, .doctor, spec.primary_skill),
            .medic => try p.skills.put(alloc, .medtech, spec.primary_skill),
            .admin_command, .admin_logistics, .admin_transport, .admin_hr, .admin_finance => try p.skills.put(alloc, .admin, spec.primary_skill),
            .dropship_crew, .jumpship_crew => {},
        }
        return id;
    }

    /// Post a person to an HQ's staff (off any force).
    pub fn postToHq(self: *GameState, person_id: types.PersonId, hq_id: types.HqId) !void {
        const p = self.person(person_id) orelse return error.UnknownPerson;
        if (self.hqs.getPtr(hq_id) == null) return error.UnknownHq;
        p.posted_hq = hq_id;
        p.assigned_force = .none;
        self.refreshHqStaffing();
    }

    // --------------------------------------------- character creation & HQ

    pub const CreateCommanderError = error{ CommanderExists, NoHomeWorld } || std.mem.Allocator.Error;

    /// Character creation: the commander's origin picks the starter world
    /// (weighted-random in their faction's space) and stands up the starter
    /// regional HQ there with modest level-1 facilities. Staffing is
    /// paper-satisfied until Stage 9 posts real people to HQs.
    pub fn createCommander(
        self: *GameState,
        name: []const u8,
        origin: commander_mod.Faction,
        profession: commander_mod.Profession,
    ) CreateCommanderError!types.HqId {
        if (self.commander != null) return error.CommanderExists;
        const world = planet_mod.weightedPickByFaction(&self.rng, origin.key()) orelse return error.NoHomeWorld;

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
            .monthly_upkeep = 25_000, // // TUNE
        };
        const starter_facilities = [_]hq_mod.FacilityKind{ .mek_bay, .warehouse, .hospital, .mess, .comms, .spaceport, .hiring_hall, .training_ground };
        for (starter_facilities) |kind| {
            try hq.facilities.append(self.allocator(), .{ .kind = kind, .level = 1 });
        }
        const req = hq.staffRequired();
        try self.hqs.put(self.allocator(), id, hq);

        // The back office is people (Stage 9C): recruit the starter HQ's
        // staff to requirement and post them. Their payroll is the tail.
        const staff_plan = [_]struct { person_mod.Role, u32 }{
            .{ .admin_command, req.admin }, .{ .admin_logistics, req.logistics / 2 },
            .{ .admin_transport, req.logistics - req.logistics / 2 },
            .{ .admin_hr, req.hr },         .{ .admin_finance, req.finance },
        };
        for (staff_plan) |entry| {
            for (0..entry[1]) |_| {
                const pid = try self.recruitGenerated(entry[0]);
                self.person(pid).?.posted_hq = id;
            }
        }
        self.refreshHqStaffing();

        // Founding capital: the HQ opens with its own operating treasury,
        // handed over on-site (no courier). // TUNE
        self.transferFunds(.outfit, .{ .hq = id }, 1_000_000, 0) catch {};

        // A modestly stocked warehouse to start (Stage 9B). // TUNE
        const site: types.Site = .{ .hq = id };
        try self.addStock(site, "provisions", 60);
        try self.addStock(site, "medical_supplies", 10);
        try self.addStock(site, "armor", 20);
        for (part_mod.component_keys) |key| try self.addStock(site, key, 1);
        for (part_mod.munition_keys) |key| try self.addStock(site, key, 12);
        return id;
    }

    // ----------------------------------------- the back office (Stage 9C)

    /// Posted admins of one role at an HQ: how many, and the best of them.
    pub fn hqStaff(self: *GameState, hq_id: types.HqId, role: person_mod.Role) StaffSummary {
        var s: StaffSummary = .{};
        var it = self.people.iterator();
        while (it.next()) |entry| {
            const p = entry.value_ptr;
            if (p.status != .active or p.posted_hq != hq_id or p.role != role) continue;
            s.count += 1;
            s.best_skill = @min(s.best_skill, p.skill(.admin) orelse 7);
        }
        return s;
    }

    /// Recompute every HQ's `staff_assigned` from real postings.
    pub fn refreshHqStaffing(self: *GameState) void {
        var hit = self.hqs.iterator();
        while (hit.next()) |entry| entry.value_ptr.staff_assigned = 0;
        var it = self.people.iterator();
        while (it.next()) |entry| {
            const p = entry.value_ptr;
            if (p.status != .active or p.posted_hq == .none) continue;
            if (self.hqs.getPtr(p.posted_hq)) |h| h.staff_assigned += 1;
        }
    }

    /// Recruit and post admins until an HQ meets its staffing requirement
    /// (the convenience path; the hiring hall is the considered one).
    /// Returns how many were hired.
    pub fn staffHqToRequirement(self: *GameState, hq_id: types.HqId) !u32 {
        const hq = self.hqs.getPtr(hq_id) orelse return error.UnknownHq;
        const req = hq.staffRequired();
        var hired: u32 = 0;
        const plan = [_]struct { person_mod.Role, u32 }{
            .{ .admin_command, req.admin },
            .{ .admin_logistics, req.logistics / 2 },
            .{ .admin_transport, req.logistics - req.logistics / 2 },
            .{ .admin_hr, req.hr },
            .{ .admin_finance, req.finance },
        };
        for (plan) |entry| {
            const have = self.hqStaff(hq_id, entry[0]).count;
            var n: u32 = entry[1] -| have;
            while (n > 0) : (n -= 1) {
                const pid = try self.recruitGenerated(entry[0]);
                self.person(pid).?.posted_hq = hq_id;
                hired += 1;
            }
        }
        self.refreshHqStaffing();
        return hired;
    }

    /// Recruit-quality bonus on the 2d6 experience roll: the hiring hall and
    /// a staffed HR office find better people. // TUNE
    pub fn recruitBonus(self: *GameState) i32 {
        if (self.hqs.count() == 0) return 0;
        const hq = &self.hqs.values()[0];
        var bonus: i32 = hq.effectiveFacilityLevel(.hiring_hall);
        if (self.hqStaff(hq.id, .admin_hr).count >= 2) bonus += 1;
        return @min(bonus, 3);
    }

    // ------------------------------------- the HQ network (Stage 9D)

    pub const FoundError = error{ UnknownPlanet, NotReachable } || std.mem.Allocator.Error;

    /// Stand up an HQ on a world. Field HQs open with a bay, a warehouse
    /// and a mess; regional ones add comms, a spaceport, a hospital and a
    /// hiring hall. Staffing is the player's problem from day one.
    pub fn foundHq(self: *GameState, name: []const u8, tier: hq_mod.HqTier, planet_key: []const u8) FoundError!types.HqId {
        const world = planet_mod.find(planet_key) orelse return error.UnknownPlanet;
        const id: types.HqId = @enumFromInt(self.next_hq_id);
        self.next_hq_id += 1;
        var hq: hq_mod.Hq = .{
            .id = id,
            .name = try self.allocator().dupe(u8, name),
            .tier = tier,
            .planet_key = world.key,
            .monthly_upkeep = switch (tier) {
                .field => 10_000,
                .regional => 25_000,
                .brigade => 60_000,
            }, // TUNE
        };
        const base = [_]hq_mod.FacilityKind{ .mek_bay, .warehouse, .mess };
        for (base) |kind| try hq.facilities.append(self.allocator(), .{ .kind = kind, .level = 1 });
        if (tier != .field) {
            const more = [_]hq_mod.FacilityKind{ .comms, .spaceport, .hospital, .hiring_hall, .training_ground };
            for (more) |kind| try hq.facilities.append(self.allocator(), .{ .kind = kind, .level = 1 });
        }
        try self.hqs.put(self.allocator(), id, hq);
        return id;
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

    /// Combat companies currently assigned to an HQ.
    pub fn companiesAtHq(self: *GameState, hq_id: types.HqId) u32 {
        var n: u32 = 0;
        var it = self.forces.iterator();
        while (it.next()) |entry| {
            const f = entry.value_ptr;
            if (f.echelon == .company and f.supplying_hq == hq_id) n += 1;
        }
        return n;
    }

    /// Combat (mek/air) lances under a company.
    pub fn combatLancesOf(self: *GameState, company: types.ForceId) u32 {
        const f = self.forces.getPtr(company) orelse return 0;
        var n: u32 = 0;
        for (f.children.items) |cid| {
            const c = self.forces.getPtr(cid) orelse continue;
            if (c.echelon == .lance or c.echelon == .air_lance) n += 1;
        }
        return n;
    }

    pub const AssignHqError = error{ UnknownForce, UnknownHq, NotACompany, CapacityFull, TooManyLances };

    /// Assign a company to an HQ, enforcing the HQ's capacity slots
    /// (ARCH §9.3): companies per HQ and lances per company.
    pub fn assignCompanyToHq(self: *GameState, company: types.ForceId, hq_id: types.HqId) AssignHqError!void {
        const f = self.forces.getPtr(company) orelse return error.UnknownForce;
        if (f.echelon != .company) return error.NotACompany;
        const hq = self.hqs.getPtr(hq_id) orelse return error.UnknownHq;
        const cap = hq.capacity();
        const already = self.companiesAtHq(hq_id) - @intFromBool(f.supplying_hq == hq_id);
        if (already >= cap.combat_companies) return error.CapacityFull;
        if (self.combatLancesOf(company) > cap.lances_per_company) return error.TooManyLances;
        f.supplying_hq = hq_id;
    }

    /// Commander cost multiplier for a category (neutral without a commander).
    pub fn commanderMultBp(self: *const GameState, kind: commander_mod.BonusKind) types.Bp {
        const c = self.commander orelse return 10_000;
        return c.costMultBp(kind);
    }

    /// Monthly payroll for everyone assigned under one company's subtree.
    pub fn companyMonthlyPayroll(self: *GameState, company_id: types.ForceId) types.CBills {
        var total: types.CBills = 0;
        var it = self.people.iterator();
        while (it.next()) |entry| {
            const p = entry.value_ptr;
            if (p.status != .active and p.status != .wounded) continue;
            var f = p.assigned_force;
            while (f != .none) {
                if (f == company_id) {
                    total += p.monthlySalary();
                    break;
                }
                f = (self.forces.getPtr(f) orelse break).parent;
            }
        }
        return total;
    }

    /// Append a tagged, formatted entry (with the campaign date) to the log.
    pub fn log(self: *GameState, category: LogCategory, ctx: LogCtx, comptime fmt: []const u8, args: anytype) !void {
        const d = self.clock.date;
        const line = try std.fmt.allocPrint(
            self.allocator(),
            "{d}-{d:0>2}-{d:0>2} " ++ fmt,
            .{ d.year, d.month, d.day } ++ args,
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

    // ------------------------------------------- physical stock (Stage 9B)
    // Stock lives at sites: the outfit's fallback depot (pre-HQ), each HQ's
    // warehouse (capped by warehouse level), each deployed company's field
    // stores (capped by its logistics trucks). Pallets have tonnage.

    fn stockMap(self: *GameState, site: types.Site) ?*std.StringArrayHashMapUnmanaged(u32) {
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

    /// A force's home warehouse: its supplying HQ (Stage 9D), else the seat.
    pub fn homeSiteFor(self: *GameState, force_id: types.ForceId) types.Site {
        const hq = self.homeHqFor(force_id);
        return if (hq != .none) .{ .hq = hq } else .outfit;
    }

    /// Is the company physically at its home HQ (not deployed, not idling
    /// on a contract world, not travelling)?
    pub fn isCompanyHome(self: *GameState, company: types.ForceId) bool {
        const f = self.forces.getPtr(company) orelse return true;
        return f.location_planet == null and f.return_eta_day == null and self.deploymentContract(company) == null;
    }

    /// Where a force draws supplies from: its own field stores while away
    /// from home, its home warehouse otherwise.
    pub fn siteForForce(self: *GameState, force_id: types.ForceId) types.Site {
        const co = self.companyOf(force_id);
        if (co != .none and !self.isCompanyHome(co)) return .{ .company = co };
        return self.homeSiteFor(force_id);
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

    /// Tonnage currently stored at a site.
    pub fn siteTons(self: *GameState, site: types.Site) u32 {
        const map = self.stockMap(site) orelse return 0;
        var total: u32 = 0;
        var it = map.iterator();
        while (it.next()) |entry| total += entry.value_ptr.* * part_mod.tons(entry.key_ptr.*);
        return total;
    }

    /// Storage capacity (null = unlimited outfit depot). A company's cap is
    /// its logistics trucks: 20t per cargo truck, 5t per salvage truck. // TUNE
    pub fn siteCapacityTons(self: *GameState, site: types.Site) ?u32 {
        switch (site) {
            .outfit => return null,
            .hq => |id| return if (self.hqs.getPtr(id)) |h| h.warehouseCapacityTons() else 0,
            .company => |id| {
                var cap: u32 = 0;
                var it = self.units.iterator();
                while (it.next()) |entry| {
                    const u = entry.value_ptr;
                    if (u.status == .destroyed or self.companyOf(u.force) != id) continue;
                    if (std.mem.eql(u8, u.chassis_key, "CGT-3")) cap += 20;
                    if (std.mem.eql(u8, u.chassis_key, "SVT-1")) cap += 5;
                }
                return cap;
            },
        }
    }

    pub fn siteFreeTons(self: *GameState, site: types.Site) u32 {
        const cap = self.siteCapacityTons(site) orelse return std.math.maxInt(u32);
        return cap -| self.siteTons(site);
    }

    /// Move stock between sites on the spot (co-located handover). Returns
    /// the quantity actually moved (bounded by source stock and destination
    /// space).
    pub fn moveStock(self: *GameState, from: types.Site, to: types.Site, key: []const u8, qty: u32) !u32 {
        const have = self.stockCount(from, key);
        const per = part_mod.tons(key);
        const fits = if (per == 0) qty else self.siteFreeTons(to) / per;
        const n = @min(qty, @min(have, fits));
        if (n == 0) return 0;
        _ = self.takeStock(from, key, n);
        try self.addStock(to, key, n);
        return n;
    }

    /// Kit out a company from the home warehouse before it ships: a month
    /// of provisions, medical, ammo for its weapons, armor and structure —
    /// as far as its trucks can carry. // TUNE
    pub fn loadOutCompany(self: *GameState, company_id: types.ForceId) !void {
        const home = self.homeSiteFor(company_id);
        const dest: types.Site = .{ .company = company_id };
        const heads = self.companyHeadcount(company_id);
        const provisions = std.math.divCeil(u32, heads * 30, part_mod.provisions_person_days_per_ton) catch 0;
        _ = try self.moveStock(home, dest, "provisions", provisions);
        _ = try self.moveStock(home, dest, "medical_supplies", 4);
        for (part_mod.munition_keys) |key| _ = try self.moveStock(home, dest, key, 10);
        _ = try self.moveStock(home, dest, "armor", 10);
    }

    /// The treasury that pays for a site's logistics.
    pub fn siteTreasury(site: types.Site) Treasury {
        return switch (site) {
            .outfit => .outfit,
            .hq => |id| .{ .hq = id },
            .company => |id| .{ .company = id },
        };
    }

    // Convenience wrappers on the home warehouse (tests, Stage 5 callers).
    pub fn addSpare(self: *GameState, part_key: []const u8, qty: u32) !void {
        try self.addStock(self.defaultSite(), part_key, qty);
    }
    pub fn takeSpare(self: *GameState, part_key: []const u8, qty: u32) bool {
        return self.takeStock(self.defaultSite(), part_key, qty);
    }
    pub fn spareCount(self: *GameState, part_key: []const u8) u32 {
        return self.stockCount(self.defaultSite(), part_key);
    }

    /// Courier days to reach a treasury from the outfit's seat (first HQ).
    /// Same-planet handoffs still take a minimum 3 days of paperwork. // TUNE
    pub fn courierEtaDays(self: *GameState, to: Treasury) u32 {
        const home_key: []const u8 = if (self.hqs.count() > 0) self.hqs.values()[0].planet_key else return 3;
        const dest_key: []const u8 = switch (to) {
            .outfit => home_key,
            .hq => |id| if (self.hqs.getPtr(id)) |h| h.planet_key else home_key,
            .company => |id| blk: {
                if (self.deploymentContract(id)) |c| break :blk c.planet_key;
                if (self.hqs.getPtr(self.homeHqFor(id))) |h| break :blk h.planet_key;
                break :blk home_key;
            },
        };
        const home = planet_mod.find(home_key) orelse return 3;
        const dest = planet_mod.find(dest_key) orelse return 3;
        if (home == dest) return 3;
        return @max(3, @import("../econ/logistics.zig").transitDays(planet_mod.jumpsBetween(home, dest)));
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
            if (c.assigned_company == company_id and (c.status == .transit or c.status == .active))
                return c;
        }
        return null;
    }

    /// Head count assigned under one company's subtree (active + wounded).
    pub fn companyHeadcount(self: *GameState, company_id: types.ForceId) u32 {
        var n: u32 = 0;
        var it = self.people.iterator();
        while (it.next()) |entry| {
            const p = entry.value_ptr;
            if (p.status != .active and p.status != .wounded) continue;
            var f = p.assigned_force;
            while (f != .none) {
                if (f == company_id) {
                    n += 1;
                    break;
                }
                f = (self.forces.getPtr(f) orelse break).parent;
            }
        }
        return n;
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
                    .slot_key = try std.fmt.allocPrint(alloc, "{s}.structure", .{loc}),
                    .part_key = "structure",
                    .class = .structure,
                });
            }
        } else {
            try u.slots.append(alloc, .{
                .slot_key = "chassis.structure",
                .part_key = "structure",
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

    /// Make a freshly bought hull match its listing's condition (Stage
    /// 9C.3): armor, quality, broken weapons, and missing structure —
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

    pub const AssignError = error{ UnknownUnit, UnknownPerson, UnknownForce } || std.mem.Allocator.Error;

    /// Put a unit in a lance and a pilot in the unit, keeping all three
    /// views (unit.force, force.units, person.assigned_force) consistent.
    pub fn assignUnit(self: *GameState, unit_id: types.UnitId, force_id: types.ForceId, pilot_id: types.PersonId) AssignError!void {
        const u = self.unit(unit_id) orelse return error.UnknownUnit;
        const f = self.force(force_id) orelse return error.UnknownForce;
        u.force = force_id;
        try f.units.append(self.allocator(), unit_id);
        if (pilot_id != .none) {
            const p = self.person(pilot_id) orelse return error.UnknownPerson;
            u.pilot = pilot_id;
            p.assigned_force = force_id;
        }
    }

    // --------------------------------------- assignments (Stage 9C.2)

    pub const AssignSlotError = error{ UnknownUnit, UnknownPerson, WrongRole, Unavailable, NoTechSlot };

    /// Put a person in a hull's pilot or tech slot. A pilot leaves any
    /// previous hull; a tech may cover several hulls (hours permitting —
    /// the maintenance pass enforces the budget, not this).
    pub fn assignSlot(self: *GameState, unit_id: types.UnitId, slot: Slot, person_id: types.PersonId) AssignSlotError!void {
        const u = self.unit(unit_id) orelse return error.UnknownUnit;
        const p = self.person(person_id) orelse return error.UnknownPerson;
        if (!p.isAvailable(self.clock.day_index)) return error.Unavailable;
        switch (slot) {
            .pilot => {
                if (p.role != unit_mod.crewRoleFor(u.kind)) return error.WrongRole;
                // One seat per pilot.
                var it = self.units.iterator();
                while (it.next()) |entry| {
                    if (entry.value_ptr.pilot == person_id) entry.value_ptr.pilot = .none;
                }
                u.pilot = person_id;
                p.assigned_force = u.force;
            },
            .tech => {
                const need = unit_mod.techRoleFor(u.kind) orelse return error.NoTechSlot;
                if (p.role != need) return error.WrongRole;
                u.tech = person_id;
                if (p.assigned_force == .none) p.assigned_force = self.companyOf(u.force);
            },
        }
    }

    pub fn unassignSlot(self: *GameState, unit_id: types.UnitId, slot: Slot) error{UnknownUnit}!void {
        const u = self.unit(unit_id) orelse return error.UnknownUnit;
        switch (slot) {
            .pilot => u.pilot = .none,
            .tech => u.tech = .none,
        }
    }

    /// Weekly hours a tech already carries across assigned hulls.
    pub fn techLoadHours(self: *GameState, tech_id: types.PersonId) u32 {
        var hours: u32 = 0;
        var it = self.units.iterator();
        while (it.next()) |entry| {
            const u = entry.value_ptr;
            if (u.tech != tech_id or u.status == .destroyed or u.status == .mothballed) continue;
            const tonnage: u8 = if (chassis_mod.find(u.chassis_key)) |d| d.tonnage else 50;
            hours += unit_mod.maintenanceHours(u.kind, tonnage);
        }
        return hours;
    }

    /// Effective hours a tech can spend this week: the budget, scaled by the
    /// astech team available in their company (6 per tech = full rate,
    /// none = half). // TUNE
    pub fn techHoursAvailable(self: *GameState, tech: *const person_mod.Person) u32 {
        const company = self.companyOf(tech.assigned_force);
        var techs: u32 = 0;
        var astechs: u32 = 0;
        var it = self.people.iterator();
        while (it.next()) |entry| {
            const p = entry.value_ptr;
            if (!p.isAvailable(self.clock.day_index) or self.companyOf(p.assigned_force) != company) continue;
            if (p.role == .astech) astechs += 1;
            if (p.role == .tech_mek or p.role == .tech_mechanic or p.role == .tech_aero or p.role == .tech_ba) techs += 1;
        }
        const team_bp: types.Bp = if (techs == 0) 10_000 else 5_000 + @min(5_000, @divTrunc(@as(types.Bp, astechs) * 5_000, 6 * @as(types.Bp, techs)));
        return @intCast(types.applyBp(@as(types.CBills, tech.weekly_hours), team_bp));
    }

    /// A free tech of the right role in the same company (or any, if
    /// `company` is .none) with hours to spare.
    pub fn findFreeTech(self: *GameState, role: person_mod.Role, company: types.ForceId, hours_needed: u32) ?types.PersonId {
        var best: ?types.PersonId = null;
        var best_spare: u32 = 0;
        var it = self.people.iterator();
        while (it.next()) |entry| {
            const p = entry.value_ptr;
            if (p.role != role or !p.isAvailable(self.clock.day_index) or p.posted_hq != .none) continue;
            if (company != .none and self.companyOf(p.assigned_force) != company) continue;
            const avail = self.techHoursAvailable(p);
            const load = self.techLoadHours(p.id);
            if (avail < load + hours_needed) continue;
            const spare = avail - load;
            if (best == null or spare > best_spare) {
                best = p.id;
                best_spare = spare;
            }
        }
        return best;
    }

    /// Fill every open pilot/tech slot in a company from its own people
    /// (and the unassigned pool). Returns how many slots remain open.
    pub fn autoAssign(self: *GameState, company: types.ForceId) !u32 {
        var open: u32 = 0;
        var uit = self.units.iterator();
        while (uit.next()) |entry| {
            const u = entry.value_ptr;
            if (self.companyOf(u.force) != company or u.status == .destroyed or u.status == .mothballed) continue;

            if (u.pilot == .none or !(self.person(u.pilot) orelse continue).isAvailable(self.clock.day_index)) {
                const role = unit_mod.crewRoleFor(u.kind);
                var pit = self.people.iterator();
                var found = false;
                while (pit.next()) |pe| {
                    const p = pe.value_ptr;
                    if (p.role != role or !p.isAvailable(self.clock.day_index) or p.posted_hq != .none) continue;
                    if (self.companyOf(p.assigned_force) != company and p.assigned_force != .none) continue;
                    if (self.pilotSeat(p.id) != .none) continue;
                    self.assignSlot(u.id, .pilot, p.id) catch continue;
                    found = true;
                    break;
                }
                if (!found) open += 1;
            }
            if (unit_mod.techRoleFor(u.kind)) |role| {
                if (u.tech == .none or !(self.person(u.tech) orelse continue).isAvailable(self.clock.day_index)) {
                    const tonnage: u8 = if (chassis_mod.find(u.chassis_key)) |d| d.tonnage else 50;
                    const hours = unit_mod.maintenanceHours(u.kind, tonnage);
                    if (self.findFreeTech(role, company, hours) orelse self.findFreeTech(role, .none, hours)) |tid| {
                        self.assignSlot(u.id, .tech, tid) catch {
                            open += 1;
                            continue;
                        };
                    } else open += 1;
                }
            }
        }
        return open;
    }

    // ------------------------------------------- the MekLab (Stage 10)

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

    /// Move a hull into a company: the first lance with a seat free, else
    /// the company's own pool. The pilot rides along; the old tech stays
    /// behind (transfers cost coverage until reassigned).
    pub fn placeUnitInCompany(self: *GameState, unit_id: types.UnitId, company: types.ForceId) !void {
        const u = self.unit(unit_id) orelse return error.UnknownUnit;
        // Leave the old force's roster.
        if (self.forces.getPtr(u.force)) |old| {
            for (old.units.items, 0..) |id, i| {
                if (id == unit_id) {
                    _ = old.units.orderedRemove(i);
                    break;
                }
            }
        }
        var dest = company;
        if (self.forces.getPtr(company)) |co| {
            for (co.children.items) |cid| {
                const lance = self.forces.getPtr(cid) orelse continue;
                if (lance.echelon == .lance and lance.units.items.len < force_mod.lance_size) {
                    dest = cid;
                    break;
                }
            }
        }
        u.force = dest;
        u.status = if (u.status == .in_transit) .ready else u.status;
        u.tech = .none;
        if (self.forces.getPtr(dest)) |d| try d.units.append(self.allocator(), unit_id);
        if (self.person(u.pilot)) |p| p.assigned_force = dest;
    }

    /// The hull a pilot currently sits in.
    pub fn pilotSeat(self: *GameState, person_id: types.PersonId) types.UnitId {
        var it = self.units.iterator();
        while (it.next()) |entry| {
            if (entry.value_ptr.pilot == person_id) return entry.value_ptr.id;
        }
        return .none;
    }

    /// Sum of monthly salaries for everyone on active status, after the
    /// paymaster's discount if the commander has one.
    pub fn monthlyPayroll(self: *GameState) types.CBills {
        var total: types.CBills = 0;
        var it = self.people.iterator();
        while (it.next()) |entry| {
            const p = entry.value_ptr;
            if (p.status == .active or p.status == .wounded) total += p.monthlySalary();
        }
        return types.applyBp(total, self.commanderMultBp(.payroll));
    }

    // ------------------------------------------------------- liquidation

    /// What a hull fetches on a forced sale: half its value, scaled by
    /// condition (Stage 12). // TUNE
    pub fn unitSaleValue(self: *GameState, u: *const unit_mod.Unit) types.CBills {
        _ = self;
        if (u.status == .destroyed) return 0;
        const base: types.CBills = if (u.purchase_price > 0) u.purchase_price else if (chassis_mod.find(u.chassis_key)) |c| c.cost else 0;
        return @divTrunc(base * @as(types.CBills, u.conditionPct()), 200);
    }

    /// What an HQ's facilities fetch: 40% of what they cost to build. // TUNE
    pub fn hqSaleValue(self: *GameState, h: *const hq_mod.Hq) types.CBills {
        _ = self;
        var total: types.CBills = 0;
        for (h.facilities.items) |f| {
            var lvl: u8 = 1;
            while (lvl <= f.level) : (lvl += 1) total += hq_mod.upgradeCost(f.kind, lvl);
        }
        return @divTrunc(total * 40, 100);
    }

    /// Everything the outfit could raise by selling hulls and all HQs but
    /// the first.
    pub fn liquidationValue(self: *GameState) types.CBills {
        var total: types.CBills = 0;
        var uit = self.units.iterator();
        while (uit.next()) |e| total += self.unitSaleValue(e.value_ptr);
        var first = true;
        var hit = self.hqs.iterator();
        while (hit.next()) |e| {
            if (first) {
                first = false;
                continue;
            }
            total += self.hqSaleValue(e.value_ptr);
        }
        return total;
    }

    /// Lenders extend half the liquidation value plus a floor. // TUNE
    pub fn creditLimit(self: *GameState) types.CBills {
        return @divTrunc(self.liquidationValue(), 2) + 2_000_000;
    }

    pub fn creditRemaining(self: *GameState) types.CBills {
        var owed: types.CBills = 0;
        for (self.loans.items) |l| owed += l.balance;
        return @max(0, self.creditLimit() - owed);
    }

    /// Strike a hull from the books: seats open, bay work and refit plans
    /// for it vanish, its force forgets it.
    pub fn removeUnit(self: *GameState, unit_id: types.UnitId) void {
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
        _ = self.units.orderedRemove(unit_id);
    }

    // ------------------------------------------------------- golden master

    /// Deterministic digest of gameplay-relevant state. Two runs with the
    /// same seed and command script must produce the same hash — the
    /// regression harness every stage builds on (ARCH §13).
    pub fn hash(self: *GameState) u64 {
        var h = std.hash.Wyhash.init(0x42544d43); // "BTMC"
        h.update(std.mem.asBytes(&self.clock.day_index));
        h.update(std.mem.asBytes(&self.funds));
        h.update(std.mem.asBytes(&self.reputation));
        const txn_count: u64 = self.ledger.transactions.items.len;
        h.update(std.mem.asBytes(&txn_count));

        var it = self.people.iterator();
        while (it.next()) |entry| {
            const p = entry.value_ptr;
            h.update(std.mem.asBytes(&p.id));
            h.update(p.first_name);
            h.update(p.last_name);
            h.update(std.mem.asBytes(&p.role));
            h.update(std.mem.asBytes(&p.status));
            h.update(std.mem.asBytes(&p.xp));
            h.update(std.mem.asBytes(&p.fatigue));
            h.update(std.mem.asBytes(&p.morale));
        }
        var uit = self.units.iterator();
        while (uit.next()) |entry| {
            const u = entry.value_ptr;
            h.update(std.mem.asBytes(&u.id));
            h.update(u.chassis_key);
            h.update(std.mem.asBytes(&u.status));
            h.update(std.mem.asBytes(&u.quality));
            h.update(std.mem.asBytes(&u.armor_pct));
            h.update(std.mem.asBytes(&u.force));
            h.update(std.mem.asBytes(&u.pilot));
        }
        var fit = self.forces.iterator();
        while (fit.next()) |entry| {
            const f = entry.value_ptr;
            h.update(std.mem.asBytes(&f.id));
            h.update(f.name);
            h.update(std.mem.asBytes(&f.echelon));
            const unit_count: u64 = f.units.items.len;
            h.update(std.mem.asBytes(&unit_count));
        }
        var cit = self.contracts.iterator();
        while (cit.next()) |entry| {
            const c = entry.value_ptr;
            h.update(std.mem.asBytes(&c.id));
            h.update(std.mem.asBytes(&c.kind));
            h.update(std.mem.asBytes(&c.status));
            h.update(c.planet_key);
        }
        for (self.contract_offers.items) |offer| {
            h.update(std.mem.asBytes(&offer.kind));
            h.update(offer.planet_key);
            h.update(std.mem.asBytes(&offer.terms.base_pay_month));
        }
        var hit = self.hqs.iterator();
        while (hit.next()) |entry| {
            h.update(std.mem.asBytes(&entry.value_ptr.id));
            h.update(entry.value_ptr.planet_key);
        }
        if (self.commander) |c| {
            h.update(c.name);
            h.update(std.mem.asBytes(&c.origin));
            h.update(std.mem.asBytes(&c.profession));
        }
        const loan_count: u64 = self.loans.items.len;
        h.update(std.mem.asBytes(&loan_count));
        var hqfit = self.hqs.iterator();
        while (hqfit.next()) |entry| h.update(std.mem.asBytes(&entry.value_ptr.funds));
        var lfit = self.forces.iterator();
        while (lfit.next()) |entry| h.update(std.mem.asBytes(&entry.value_ptr.local_funds));
        const courier_count: u64 = self.fund_couriers.items.len;
        h.update(std.mem.asBytes(&courier_count));
        const job_count: u64 = self.bay_jobs.items.len;
        h.update(std.mem.asBytes(&job_count));
        const link_count: u64 = self.hq_links.items.len;
        h.update(std.mem.asBytes(&link_count));
        const plan_count: u64 = self.refit_plans.items.len;
        h.update(std.mem.asBytes(&plan_count));
        var spare_total: u64 = 0;
        for (self.spare_parts.values()) |v| spare_total += v;
        var shit = self.hqs.iterator();
        while (shit.next()) |entry| for (entry.value_ptr.stock.values()) |v| {
            spare_total += v;
        };
        var sfit = self.forces.iterator();
        while (sfit.next()) |entry| for (entry.value_ptr.stock.values()) |v| {
            spare_total += v;
        };
        h.update(std.mem.asBytes(&spare_total));
        const order_count: u64 = self.part_orders.items.len;
        h.update(std.mem.asBytes(&order_count));
        const listing_count: u64 = self.market_listings.items.len;
        h.update(std.mem.asBytes(&listing_count));
        return h.final();
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
