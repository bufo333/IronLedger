//! GameState: the one big tree the simulation systems operate on (ARCH §4).
//! Owned by an arena; pure and deterministic — no I/O, no wall clock.
//! Mirrors MekHQ's `Campaign` object, decomposed: state lives here, behavior
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
    /// Dispatched so far this month (Stage 12: policies are checked daily,
    /// the cap is per month; reset on payday).
    sent_this_month: types.CBills = 0,
};

/// "Keep this company's field stores above `min_days` of provisions":
/// when they drop under, `tons` are shipped from its home warehouse over
/// the supply link (Stage 12). One inbound shipment at a time.
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
/// flight, and a failed sourcing roll is not retried for a week (Stage 12).
pub const StockPolicy = struct {
    hq: types.HqId,
    part_key: []const u8,
    min: u32,
    target: u32,
};

/// Structured campaign log (Stage 9A): every entry tagged so any entity's
/// history is a filter, not an archaeology dig.
/// Campaign counters (12C.8).
pub const Stats = struct {
    battles_won: u32 = 0,
    battles_drawn: u32 = 0,
    battles_lost: u32 = 0,
    hulls_lost: u32 = 0,
    hulls_salvaged: u32 = 0,
    people_kia: u32 = 0,
    enemy_bv_destroyed: u64 = 0,
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

/// `any` (12.26): whichever seat the person's role fits — pilot roles
/// take the crew seat, tech roles the tech slot.
pub const Slot = enum { pilot, tech, any };

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
    /// Row id in the save store's campaign registry (Stage 11); 0 = never saved.
    campaign_id: i64 = 0,
    /// Set when the treasury went negative beyond what loans and sales
    /// could cover: game over (Stage 12). Persisted; advancing refuses.
    bankrupt: bool = false,
    /// Stage 12: the medbay admits the wounded itself each morning instead
    /// of waiting for the commander's signature (an untreated-wounded
    /// warning never blocks the turn while this is on).
    auto_admit: bool = false,
    /// Share of contract income paid out to shareholders at completion
    /// (12C.3, AtB shares); the owner sets it with `shares <pct>`.
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
    /// Outfit spare-parts pool, keyed by catalog part_key. (Per-HQ/company
    /// inventories arrive with Stage 9's supply network.)
    spare_parts: std.StringArrayHashMapUnmanaged(u32) = .empty,
    part_orders: std.ArrayListUnmanaged(part_mod.AcquisitionOrder) = .empty,
    /// Structured campaign log — newest last (Stage 9A).
    event_log: std.ArrayListUnmanaged(LogEntry) = .empty,
    /// Money in transit between treasuries.
    fund_couriers: std.ArrayListUnmanaged(FundCourier) = .empty,
    /// Standing top-up policies, checked daily under a monthly cap.
    policies: std.ArrayListUnmanaged(StandingPolicy) = .empty,
    /// Automatic provisions resupply for deployed companies.
    supply_policies: std.ArrayListUnmanaged(SupplyPolicy) = .empty,
    stock_policies: std.ArrayListUnmanaged(StockPolicy) = .empty,
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
    /// Standing with each house (Stage 12.21), −100…100; absent = 0.
    faction_standing: std.StringArrayHashMapUnmanaged(i32) = .empty,
    /// Event memory (play feedback): when each decision kind last fired and
    /// how the player has been answering it — cooldowns and standing orders
    /// (sim/contract_events.zig).
    event_memory: std.AutoArrayHashMapUnmanaged(events_mod.EventKind, EventMemory) = .empty,
    /// Campaign counters for the summary screen (12C.8): what the log
    /// remembers in aggregate. Persisted as meta ints.
    stats: Stats = .{},
    /// The Dragoons rating on every New Year's Day (12C.8).
    rating_history: std.ArrayListUnmanaged(RatingSnapshot) = .empty,
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

    /// The summary's counters (12C.8) only started counting when they were
    /// added; a campaign saved before that has a log full of battles and
    /// zeros in the book. Rebuild the counters from the AAR lines the log
    /// has kept all along: the header names the outcome, the losses line
    /// counts hulls destroyed and KIA and enemy BV, salvage lines name
    /// each wreck hauled home.
    pub fn rebuildStatsFromLog(self: *GameState) void {
        var st: Stats = .{};
        for (self.event_log.items) |e| {
            // Lines carry a date prefix: "3025-02-15 [AAR] …".
            if (e.category != .battle or std.mem.indexOf(u8, e.text, "[AAR]") == null) continue;
            if (std.mem.indexOf(u8, e.text, " — power ") != null) {
                // "[AAR] kind vs enemy …: outcome — power a vs b"
                const head = e.text[0..std.mem.indexOf(u8, e.text, " — power ").?];
                const colon = std.mem.lastIndexOfScalar(u8, head, ':') orelse continue;
                const outcome = std.mem.trim(u8, head[colon + 1 ..], " ");
                if (std.mem.eql(u8, outcome, "decisive_victory") or std.mem.eql(u8, outcome, "victory")) st.battles_won += 1 //
                else if (std.mem.eql(u8, outcome, "draw")) st.battles_drawn += 1 //
                else if (std.mem.eql(u8, outcome, "defeat") or std.mem.eql(u8, outcome, "rout")) st.battles_lost += 1;
                continue;
            }
            if (std.mem.indexOf(u8, e.text, "losses: ")) |i| {
                // "losses: H hit / D destroyed, W wounded, K KIA | enemy losses B BV"
                var it = std.mem.tokenizeAny(u8, e.text[i + "losses: ".len ..], " /,|");
                var nums: [8]u64 = @splat(0);
                var n: usize = 0;
                while (it.next()) |tok| {
                    if (n >= nums.len) break;
                    if (std.fmt.parseInt(u64, tok, 10)) |v| {
                        nums[n] = v;
                        n += 1;
                    } else |_| {}
                }
                // order: hit, destroyed, wounded, KIA, enemy BV
                if (n >= 5) {
                    st.hulls_lost += @intCast(nums[1]);
                    st.people_kia += @intCast(nums[3]);
                    st.enemy_bv_destroyed += nums[4];
                }
                continue;
            }
            if (std.mem.indexOf(u8, e.text, "salvage: ") != null) {
                var rest = e.text;
                while (std.mem.indexOf(u8, rest, "wreck #")) |k| {
                    st.hulls_salvaged += 1;
                    rest = rest[k + "wreck #".len ..];
                }
            }
        }
        self.stats = st;
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
        p.born_day = @as(i32, @intCast(self.clock.day_index)) - @as(i32, spec.age) * 365;

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
            .monthly_upkeep = hq_mod.HqTier.regional.monthlyUpkeep(),
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
            .{ .admin_command, req.admin },                           .{ .admin_logistics, req.logistics / 2 },
            .{ .admin_transport, req.logistics - req.logistics / 2 }, .{ .admin_hr, req.hr },
            .{ .admin_finance, req.finance },
        };
        for (staff_plan) |entry| {
            for (0..entry[1]) |_| {
                const pid = try self.recruitGenerated(entry[0]);
                self.person(pid).?.posted_hq = id;
            }
        }
        self.refreshHqStaffing();

        // Founding capital: the HQ opens with its own operating treasury,
        // handed over on-site (no courier).
        self.transferFunds(.outfit, .{ .hq = id }, tuning.hq.founding_funds, 0) catch {};

        // Standing defaults the player can clear (Stage 12.19 play-tuning:
        // a hands-off year ran the HQ treasury negative on depot repairs and
        // the warehouse out of food): the outfit tops the HQ up on payday,
        // and the warehouse keeps provisions stocked.
        try self.policies.append(self.allocator(), .{ .entity = .{ .hq = id }, .floor = tuning.finance.hq_policy_floor, .monthly_cap = tuning.finance.hq_policy_cap });
        try self.stock_policies.append(self.allocator(), .{ .hq = id, .part_key = "provisions", .min = tuning.generation.provisions_keep_min, .target = tuning.generation.provisions_keep_target });

        // A modestly stocked warehouse to start (Stage 9B).
        const site: types.Site = .{ .hq = id };
        const g = tuning.generation;
        try self.addStock(site, "provisions", g.starter_provisions);
        try self.addStock(site, "medical_supplies", g.starter_medical);
        try self.addStock(site, "armor", g.starter_armor);
        for (part_mod.component_keys) |key| try self.addStock(site, key, g.starter_components_each);
        for (part_mod.munition_keys) |key| try self.addStock(site, key, g.starter_munitions_each);
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
        // A famous outfit (12C.7) draws a better class of walk-in.
        const queries = @import("queries.zig");
        if (queries.ratingIndex(queries.ratingScore(self)) >= @import("../domain/tuning.zig").t.rating.recruit_bonus_index) bonus += 1;
        return @min(bonus, 4);
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
            .monthly_upkeep = tier.monthlyUpkeep(),
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

    /// Air wings of the companies assigned to an HQ (Stage 12.15).
    pub fn airCompaniesAtHq(self: *GameState, hq_id: types.HqId) u32 {
        var n: u32 = 0;
        var it = self.forces.iterator();
        while (it.next()) |entry| {
            const f = entry.value_ptr;
            if (f.echelon != .air_company) continue;
            const co = self.forces.getPtr(f.parent) orelse continue;
            if (co.supplying_hq == hq_id) n += 1;
        }
        return n;
    }

    /// The company's air wing, if raised.
    pub fn airCompanyOf(self: *GameState, company: types.ForceId) ?types.ForceId {
        const f = self.forces.getPtr(company) orelse return null;
        for (f.children.items) |cid| {
            const c = self.forces.getPtr(cid) orelse continue;
            if (c.echelon == .air_company) return cid;
        }
        return null;
    }

    /// The company's support echelon (Omega Company), if any.
    pub fn supportCompanyOf(self: *GameState, company: types.ForceId) ?types.ForceId {
        const f = self.forces.getPtr(company) orelse return null;
        for (f.children.items) |cid| {
            const c = self.forces.getPtr(cid) orelse continue;
            if (c.echelon == .support_company) return cid;
        }
        return null;
    }

    /// Lances under a force of one echelon (air lances of a wing, support
    /// lances of a support company).
    pub fn lancesOfEchelon(self: *GameState, parent: types.ForceId, echelon: force_mod.Echelon) u32 {
        const f = self.forces.getPtr(parent) orelse return 0;
        var n: u32 = 0;
        for (f.children.items) |cid| {
            const c = self.forces.getPtr(cid) orelse continue;
            if (c.echelon == echelon) n += 1;
        }
        return n;
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

    /// What the crewed, idle ships berthed at an HQ can lift (Stage 12.15).
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

    /// Money already on its way to the outfit's treasury (couriers in
    /// transit): it counts toward solvency at turn end (12.24 bug fix —
    /// pulling funds back could not unblock the turn until they landed).
    pub fn inboundToOutfit(self: *GameState) types.CBills {
        var sum: types.CBills = 0;
        for (self.fund_couriers.items) |c| if (c.to == .outfit) {
            sum += c.amount;
        };
        return sum;
    }

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
    /// its logistics trucks: 20t per cargo truck, 5t per salvage truck.
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
                    if (std.mem.eql(u8, u.chassis_key, "CGT-3")) cap += tuning.unit.truck_tons.cargo;
                    if (std.mem.eql(u8, u.chassis_key, "SVT-1")) cap += tuning.unit.truck_tons.salvage;
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
        const field_supply = @import("field_supply.zig");
        const home = self.homeSiteFor(company_id);
        const dest: types.Site = .{ .company = company_id };
        // The same plan the resupply policy follows, sized for the contract's
        // transit so the trucks land with the line already covered.
        const transit: u32 = if (self.deploymentContract(company_id)) |c| c.transit_days else 0;
        var arena = std.heap.ArenaAllocator.init(self.allocator());
        defer arena.deinit();
        const p = try field_supply.plan(arena.allocator(), self, company_id, transit, 14, 0);
        // Capped lines first; provisions fill whatever the trucks have left.
        for (p.lines) |l| if (!std.mem.eql(u8, l.key, "provisions")) {
            _ = try self.moveStock(home, dest, l.key, l.target);
        };
        for (p.lines) |l| if (std.mem.eql(u8, l.key, "provisions")) {
            _ = try self.moveStock(home, dest, l.key, l.target);
        };
    }

    /// Crate goods a company picked up in the field (salvaged structure,
    /// windfalls it cannot use out there) for the next convoy home: they
    /// arrive at the home warehouse after the map transit, no freight — the
    /// salvage crews haul them. Structural work is depot work (Stage 12).
    pub fn sendHome(self: *GameState, company: types.ForceId, key: []const u8, qty: u32) !void {
        if (qty == 0) return;
        const home = self.homeHqFor(company);
        if (home == .none) {
            // No HQ yet (tests, pre-commander): straight into the outfit depot.
            try self.addStock(self.defaultSite(), key, qty);
            return;
        }
        const days = @max(3, self.courierEtaDays(.{ .company = company }));
        try self.part_orders.append(self.allocator(), .{
            .part_key = key,
            .quantity = qty,
            .dest = .{ .hq = home },
            .ordered_day = self.clock.day_index,
            .eta_day = self.clock.day_index + days,
            .cost = 0,
            .status = .in_transit,
        });
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
            // Prisoners eat too (12B.7).
            if (p.status != .active and p.status != .wounded and p.status != .pow) continue;
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

    /// Can this person work a hull in the unassigned pool (12.26)? The
    /// pool sits at the outfit's seat; their company must be home there
    /// (or they belong to no company at all).
    pub fn canReachPool(self: *GameState, p: *const person_mod.Person) bool {
        const company = self.companyOf(p.assigned_force);
        if (company == .none) return true;
        if (!self.isCompanyHome(company)) return false;
        const seat: types.HqId = if (self.hqs.count() > 0) self.hqs.keys()[0] else .none;
        return self.homeHqFor(company) == seat;
    }

    pub const AssignSlotError = error{ UnknownUnit, UnknownPerson, WrongRole, Unavailable, NoTechSlot, PersonAway };

    /// Put a person in a hull's pilot or tech slot. A pilot leaves any
    /// previous hull; a tech may cover several hulls (hours permitting —
    /// the maintenance pass enforces the budget, not this).
    pub fn assignSlot(self: *GameState, unit_id: types.UnitId, slot: Slot, person_id: types.PersonId) AssignSlotError!void {
        const u = self.unit(unit_id) orelse return error.UnknownUnit;
        const p = self.person(person_id) orelse return error.UnknownPerson;
        if (!p.isAvailable(self.clock.day_index)) return error.Unavailable;
        if (u.force == .none and !self.canReachPool(p)) return error.PersonAway;
        const resolved: Slot = if (slot != .any) slot else if (p.role == unit_mod.crewRoleFor(u.kind)) .pilot else if (unit_mod.techRoleFor(u.kind) == p.role) .tech else return error.WrongRole;
        switch (resolved) {
            .any => unreachable,
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
            .any => {
                u.pilot = .none;
                u.tech = .none;
            },
        }
    }

    /// Weekly hours a tech already carries across assigned hulls.
    pub fn techLoadHours(self: *GameState, tech_id: types.PersonId) u32 {
        var hours: u32 = 0;
        const tech = self.person(tech_id);
        var it = self.units.iterator();
        while (it.next()) |entry| {
            const u = entry.value_ptr;
            if (u.tech != tech_id or u.status == .destroyed or u.status == .mothballed) continue;
            hours += if (tech) |t| self.techHoursFor(t, u) else self.hullHours(u);
        }
        return hours;
    }

    /// Weekly hours a hull wants from a regular tech (12C.15): the class
    /// table scaled by quality (a neglected machine fights back) and by an
    /// exotic design (rare on the market, rare in the manuals).
    pub fn hullHours(self: *GameState, u: *const unit_mod.Unit) u32 {
        _ = self;
        const t = tuning.maintenance;
        const design = chassis_mod.find(u.chassis_key);
        const tonnage: u8 = if (design) |d| d.tonnage else 50;
        const base = unit_mod.maintenanceHours(u.kind, tonnage);
        const q_bp: types.Bp = switch (u.quality) {
            .a => t.hours_quality_bp.a,
            .b => t.hours_quality_bp.b,
            .c => t.hours_quality_bp.c,
            .d => t.hours_quality_bp.d,
            .e => t.hours_quality_bp.e,
            .f => t.hours_quality_bp.f,
        };
        var hours = types.applyBp(@as(i64, base), q_bp);
        if (design) |d| if (d.rarity == .very_rare) {
            hours = types.applyBp(hours, t.hours_exotic_bp);
        };
        return @intCast(@max(1, hours));
    }

    /// The same hull in this tech's hands (12C.15): skill sets the pace.
    pub fn techHoursFor(self: *GameState, tech: *const person_mod.Person, u: *const unit_mod.Unit) u32 {
        const t = tuning.maintenance;
        const role = unit_mod.techRoleFor(u.kind) orelse tech.role;
        const skill = tech.skill(role.primarySkill()) orelse 7;
        const bp: types.Bp = if (skill <= 2) t.hours_skill_bp.elite else if (skill == 3) t.hours_skill_bp.veteran else if (skill == 4) t.hours_skill_bp.regular else if (skill == 5) t.hours_skill_bp.green else t.hours_skill_bp.untrained;
        return @intCast(@max(1, types.applyBp(@as(i64, self.hullHours(u)), bp)));
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

            // A seat needs filling when empty or its pilot is away; a spent
            // pilot (12C.1) is benched only when someone fresher is free.
            const seated = if (u.pilot != .none) self.person(u.pilot) else null;
            const pilot_missing = seated == null or !seated.?.isAvailable(self.clock.day_index);
            const pilot_spent = seated != null and seated.?.isUnfit();
            if (pilot_missing or pilot_spent) {
                const role = unit_mod.crewRoleFor(u.kind);
                var pit = self.people.iterator();
                var found = false;
                while (pit.next()) |pe| {
                    const p = pe.value_ptr;
                    if (p.role != role or !p.isAvailable(self.clock.day_index) or p.posted_hq != .none) continue;
                    if (self.companyOf(p.assigned_force) != company and p.assigned_force != .none) continue;
                    if (self.pilotSeat(p.id) != .none) continue;
                    if (pilot_spent and p.isUnfit()) continue; // no better off
                    self.assignSlot(u.id, .pilot, p.id) catch continue;
                    found = true;
                    break;
                }
                if (!found and pilot_missing) open += 1;
            }
            if (unit_mod.techRoleFor(u.kind)) |role| {
                if (u.tech == .none or !(self.person(u.tech) orelse continue).isAvailable(self.clock.day_index)) {
                    const hours = self.hullHours(u);
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
    /// Move a hull between forces (lance ↔ lance, into a support lance, or
    /// straight under a company): roster lists and the pilot's posting
    /// follow it; the tech seat is kept.
    pub fn moveUnitToForce(self: *GameState, unit_id: types.UnitId, force_id: types.ForceId) !void {
        const u = self.unit(unit_id) orelse return error.UnknownUnit;
        const dest = self.forces.getPtr(force_id) orelse return error.UnknownForce;
        if (self.forces.getPtr(u.force)) |old| {
            for (old.units.items, 0..) |id, i| {
                if (id == unit_id) {
                    _ = old.units.orderedRemove(i);
                    break;
                }
            }
        }
        u.force = force_id;
        try dest.units.append(self.allocator(), unit_id);
        if (self.person(u.pilot)) |p| p.assigned_force = force_id;
    }

    /// The support lance under a company's Omega that a support hull
    /// belongs in, by trade: MASH rigs to the MASH lance, salvage trucks to
    /// salvage, cargo trucks to transport, platoons to security.
    pub fn supportLanceFor(self: *GameState, company: types.ForceId, u: *const unit_mod.Unit) ?types.ForceId {
        const want: force_mod.SupportLanceKind = switch (u.kind) {
            .mash => .mash,
            .cargo => if (std.mem.eql(u8, u.chassis_key, "SVT-1")) .salvage else .transport,
            .infantry => .security,
            else => return null,
        };
        const co = self.forces.getPtr(company) orelse return null;
        for (co.children.items) |cid| {
            const omega = self.forces.getPtr(cid) orelse continue;
            if (omega.echelon != .support_company) continue;
            for (omega.children.items) |sid| {
                const sl = self.forces.getPtr(sid) orelse continue;
                if (sl.echelon == .support_lance and sl.support_kind == want) return sid;
            }
        }
        return null;
    }

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
            if (u.kind == .aerospace) {
                // Fighters go to the air wing's first lance with room.
                if (self.airCompanyOf(company)) |wing_id| {
                    const wing = self.forces.getPtr(wing_id).?;
                    for (wing.children.items) |cid| {
                        const lance = self.forces.getPtr(cid) orelse continue;
                        if (lance.echelon == .air_lance and lance.units.items.len < force_mod.lance_size) {
                            dest = cid;
                            break;
                        }
                    }
                }
            } else if (u.kind == .mek or u.kind == .vehicle) {
                for (co.children.items) |cid| {
                    const lance = self.forces.getPtr(cid) orelse continue;
                    if (lance.echelon == .lance and lance.units.items.len < force_mod.lance_size) {
                        dest = cid;
                        break;
                    }
                }
            } else if (self.supportLanceFor(company, u)) |sid| {
                // Trucks, ambulances and platoons join the support lance of
                // their trade (play feedback: they used to sit on the roster).
                dest = sid;
            }
        }
        u.force = dest;
        // A bought wreck lands as damaged, not ready (play feedback).
        if (u.status == .in_transit) u.status = if (u.needsDepot()) .damaged else .ready;
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
    /// condition (Stage 12).
    pub fn unitSaleValue(self: *GameState, u: *const unit_mod.Unit) types.CBills {
        _ = self;
        if (u.status == .destroyed) return 0;
        const base: types.CBills = if (u.purchase_price > 0) u.purchase_price else if (chassis_mod.find(u.chassis_key)) |c| c.cost else 0;
        const by_condition = @divTrunc(base * @as(types.CBills, u.conditionPct()) * tuning.unit.sale_bp, 10_000 * 100);
        // Quality on the ticket (12C.13): ± per step from C (A worst, F best).
        const steps: i64 = @as(i64, @intFromEnum(u.quality)) - @intFromEnum(types.Quality.c);
        return types.applyBp(by_condition, @intCast(10_000 + steps * tuning.maintenance.quality_sale_bp_per_step));
    }

    /// What an HQ's facilities fetch: 40% of what they cost to build.
    pub fn hqSaleValue(self: *GameState, h: *const hq_mod.Hq) types.CBills {
        _ = self;
        var total: types.CBills = 0;
        for (h.facilities.items) |f| {
            var lvl: u8 = 1;
            while (lvl <= f.level) : (lvl += 1) total += hq_mod.upgradeCost(f.kind, lvl);
        }
        return @divTrunc(total * @as(types.CBills, tuning.hq.sale_pct), 100);
    }

    /// Everything the outfit could raise by selling hulls and all HQs but
    /// the first.
    /// Resale value of `qty` of a stock line (Stage 12): market.stock_resale_bp
    /// of catalogue cost, component_resale_bp for comp_* parts.
    pub fn stockSaleValue(self: *GameState, key: []const u8, qty: u32) types.CBills {
        _ = self;
        const market = @import("../econ/market.zig");
        const def = part_mod.find(key) orelse return 0;
        const bp: types.Bp = if (part_mod.isComponent(key)) market.component_resale_bp else market.stock_resale_bp;
        return types.applyBp(def.cost * qty, bp);
    }

    pub fn liquidationValue(self: *GameState) types.CBills {
        var total: types.CBills = 0;
        var uit = self.units.iterator();
        while (uit.next()) |e| total += self.unitSaleValue(e.value_ptr);
        var sit = self.spare_parts.iterator();
        while (sit.next()) |e| total += self.stockSaleValue(e.key_ptr.*, e.value_ptr.*);
        var hqs_it = self.hqs.iterator();
        while (hqs_it.next()) |e| {
            var st = e.value_ptr.stock.iterator();
            while (st.next()) |line| total += self.stockSaleValue(line.key_ptr.*, line.value_ptr.*);
        }
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

    /// Lenders extend half the liquidation value plus a floor.
    pub fn creditLimit(self: *GameState) types.CBills {
        return types.applyBp(self.liquidationValue(), tuning.finance.credit_liquidation_bp) + tuning.finance.credit_floor;
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
        h.update(std.mem.asBytes(&self.share_profit_bp));
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
            const injuries: u64 = p.injuries.items.len;
            h.update(std.mem.asBytes(&injuries));
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
            h.update(std.mem.asBytes(&u.berth_hq));
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
        var sit = self.faction_standing.iterator();
        while (sit.next()) |entry| {
            h.update(entry.key_ptr.*);
            h.update(std.mem.asBytes(entry.value_ptr));
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

test "12C.1: auto-assign benches a spent pilot when a fresher one is free, keeps them when nobody is" {
    var gs = GameState.init(std.testing.allocator, .{ .seed = 121 });
    defer gs.deinit();
    _ = try gs.createCommander("T", .LC, .paymaster);
    const co = try gs.createForce("Alpha", .company, .none);
    const lance = try gs.createForce("1st", .lance, co);
    const mek = try gs.addUnit("LCT-1V");
    gs.unit(mek).?.force = lance;
    const worn = try gs.hirePerson("Worn", "Out", .mekwarrior);
    gs.person(worn).?.assigned_force = co;
    gs.person(worn).?.fatigue = 100;
    try gs.assignSlot(mek, .pilot, worn);
    // Alone, the spent pilot keeps the seat; only the tech slot counts as open.
    try std.testing.expectEqual(@as(u32, 1), try gs.autoAssign(co));
    try std.testing.expectEqual(worn, gs.unit(mek).?.pilot);
    // A fresh pilot on the books takes over.
    const fresh = try gs.hirePerson("Fresh", "Face", .mekwarrior);
    gs.person(fresh).?.assigned_force = co;
    _ = try gs.autoAssign(co);
    try std.testing.expectEqual(fresh, gs.unit(mek).?.pilot);
    try std.testing.expect(gs.pilotSeat(worn) == .none);
}

test "12C.13: quality moves the resale ticket" {
    var gs = GameState.init(std.testing.allocator, .{ .seed = 1213 });
    defer gs.deinit();
    const uid = try gs.addUnit("SHD-2H");
    const u = gs.unit(uid).?;
    u.quality = .c;
    const c = gs.unitSaleValue(u);
    u.quality = .f;
    try std.testing.expect(gs.unitSaleValue(u) > c);
    u.quality = .a;
    try std.testing.expect(gs.unitSaleValue(u) < c);
}

test "12C.15: a worn or exotic hull wants more hours; a sharper tech needs fewer" {
    var gs = GameState.init(std.testing.allocator, .{ .seed = 1215 });
    defer gs.deinit();
    const uid = try gs.addUnit("AS7-D");
    const u = gs.unit(uid).?;
    u.quality = .c;
    const plain = gs.hullHours(u);
    try std.testing.expectEqual(@as(u32, 10), plain); // the class table, unchanged at C
    u.quality = .a;
    try std.testing.expect(gs.hullHours(u) > plain);
    u.quality = .f;
    try std.testing.expect(gs.hullHours(u) < plain);
    u.quality = .c;
    const tech = try gs.hirePerson("Ace", "Wrench", .tech_mek);
    try gs.person(tech).?.skills.put(gs.allocator(), .tech_mek, 4);
    const regular = gs.techHoursFor(gs.person(tech).?, u);
    try std.testing.expectEqual(plain, regular);
    try gs.person(tech).?.skills.put(gs.allocator(), .tech_mek, 2);
    try std.testing.expect(gs.techHoursFor(gs.person(tech).?, u) < regular);
    try gs.person(tech).?.skills.put(gs.allocator(), .tech_mek, 6);
    try std.testing.expect(gs.techHoursFor(gs.person(tech).?, u) > regular);
}

test "12C.8: counters rebuild from the AAR lines of an older save" {
    var gs = GameState.init(std.testing.allocator, .{ .seed = 1288 });
    defer gs.deinit();
    try gs.log(.battle, .{}, "[AAR] garrison_duty vs DC: victory — power 900 vs 700 (recon 0, fatigue 4, morale 50)", .{});
    try gs.log(.battle, .{}, "[AAR]   losses: 2 hit / 1 destroyed, 1 wounded, 1 KIA | enemy losses 1200 BV ≈ 1 kill credited | salvage 300 BV claimed | comp 0 | score 1", .{});
    try gs.log(.battle, .{}, "[AAR]   salvage: wreck #40 SHD-2H Shadow Hawk (armor 30%) → home depot in 5 days; wreck #41 LCT-1V Locust → home depot in 5 days; ", .{});
    try gs.log(.battle, .{}, "[AAR] raid vs CC — ambush on heavy woods, night action: rout — power 500 vs 900 (recon 0, fatigue 9, morale 40)", .{});
    try gs.log(.battle, .{}, "[AAR]   losses: 4 hit / 2 destroyed, 2 wounded, 0 KIA | enemy losses 100 BV ≈ 0 kills credited | salvage 0 BV claimed | comp 0 | score -2", .{});
    try gs.log(.battle, .{}, "[AAR]   salvage: none — the field was not held", .{});
    gs.rebuildStatsFromLog();
    try std.testing.expectEqual(@as(u32, 1), gs.stats.battles_won);
    try std.testing.expectEqual(@as(u32, 1), gs.stats.battles_lost);
    try std.testing.expectEqual(@as(u32, 3), gs.stats.hulls_lost);
    try std.testing.expectEqual(@as(u32, 1), gs.stats.people_kia);
    try std.testing.expectEqual(@as(u32, 2), gs.stats.hulls_salvaged);
    try std.testing.expectEqual(@as(u64, 1300), gs.stats.enemy_bv_destroyed);
}
