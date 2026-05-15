const std = @import("std");

pub const MAX_SKILL_MD_BYTES: usize = 256 * 1024;

pub const LookupError = error{
    SkillNotFound,
    DuplicateSkillName,
    InvalidSkillMarkdown,
    SkillTooLarge,
};

pub const SkillMeta = struct {
    name: []u8,
    description: []u8,
    dir_name: []u8,
    rel_dir: []u8,

    pub fn deinit(self: *SkillMeta, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        allocator.free(self.description);
        allocator.free(self.dir_name);
        allocator.free(self.rel_dir);
        self.* = undefined;
    }
};

pub const Snapshot = struct {
    name: []u8,
    source: []u8,
    hash_hex: [16]u8,
    content: []u8,

    pub fn deinit(self: *Snapshot, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        allocator.free(self.source);
        allocator.free(self.content);
        self.* = undefined;
    }
};

pub fn listSkills(
    allocator: std.mem.Allocator,
    root_dir: std.fs.Dir,
    skills_rel: []const u8,
) ![]SkillMeta {
    const dir_names = try collectSkillDirNames(allocator, root_dir, skills_rel);
    defer freeStringList(allocator, dir_names);

    var skills: std.ArrayListUnmanaged(SkillMeta) = .empty;
    errdefer {
        for (skills.items) |*skill| skill.deinit(allocator);
        skills.deinit(allocator);
    }

    var skills_dir = openSkillsDir(root_dir, skills_rel) catch |err| switch (err) {
        error.FileNotFound => return allocator.alloc(SkillMeta, 0),
        else => return err,
    };
    defer skills_dir.close();

    for (dir_names) |dir_name| {
        var skill_dir = try skills_dir.openDir(dir_name, .{});
        defer skill_dir.close();

        const bytes = try readSkillMarkdown(allocator, skill_dir) orelse continue;
        defer allocator.free(bytes);

        var meta = try parseSkillMeta(allocator, bytes, skills_rel, dir_name);
        skills.append(allocator, meta) catch |err| {
            meta.deinit(allocator);
            return err;
        };
    }

    std.sort.insertion(SkillMeta, skills.items, {}, skillLessThan);
    return skills.toOwnedSlice(allocator);
}

pub fn freeSkillList(allocator: std.mem.Allocator, list: []SkillMeta) void {
    for (list) |*skill| skill.deinit(allocator);
    allocator.free(list);
}

pub fn loadSkillSnapshot(
    allocator: std.mem.Allocator,
    root_dir: std.fs.Dir,
    skills_rel: []const u8,
    skill_name: []const u8,
) !Snapshot {
    const dir_names = try collectSkillDirNames(allocator, root_dir, skills_rel);
    defer freeStringList(allocator, dir_names);

    var skills_dir = openSkillsDir(root_dir, skills_rel) catch |err| switch (err) {
        error.FileNotFound => return LookupError.SkillNotFound,
        else => return err,
    };
    defer skills_dir.close();

    var candidate: ?SkillCandidate = null;
    errdefer if (candidate) |*found| found.deinit(allocator);

    for (dir_names) |dir_name| {
        var skill_dir = try skills_dir.openDir(dir_name, .{});
        defer skill_dir.close();

        const bytes = try readSkillMarkdown(allocator, skill_dir) orelse continue;

        var meta = parseSkillMeta(allocator, bytes, skills_rel, dir_name) catch |err| switch (err) {
            LookupError.InvalidSkillMarkdown => {
                allocator.free(bytes);
                if (std.mem.eql(u8, dir_name, skill_name)) return LookupError.InvalidSkillMarkdown;
                continue;
            },
            else => {
                allocator.free(bytes);
                return err;
            },
        };

        const matches_name = std.mem.eql(u8, meta.name, skill_name);
        const matches_dir = std.mem.eql(u8, meta.dir_name, skill_name);
        if (!matches_name and !matches_dir) {
            meta.deinit(allocator);
            allocator.free(bytes);
            continue;
        }

        if (candidate) |*found| {
            meta.deinit(allocator);
            allocator.free(bytes);
            found.deinit(allocator);
            candidate = null;
            return LookupError.DuplicateSkillName;
        }

        candidate = .{ .meta = meta, .bytes = bytes };
    }

    var found = candidate orelse return LookupError.SkillNotFound;
    candidate = null;
    defer found.deinit(allocator);

    var hash_hex: [16]u8 = undefined;
    writeHashHex(&hash_hex, found.bytes);

    const name = try allocator.dupe(u8, found.meta.name);
    errdefer allocator.free(name);
    const source = try allocator.dupe(u8, found.meta.rel_dir);
    errdefer allocator.free(source);
    const content = try std.fmt.allocPrint(
        allocator,
        "# Skill: {s}\nsource: {s}\nhash: {s}\n\n{s}",
        .{ found.meta.name, found.meta.rel_dir, hash_hex[0..], found.bytes },
    );
    errdefer allocator.free(content);

    return .{
        .name = name,
        .source = source,
        .hash_hex = hash_hex,
        .content = content,
    };
}

const SkillCandidate = struct {
    meta: SkillMeta,
    bytes: []u8,

    fn deinit(self: *SkillCandidate, allocator: std.mem.Allocator) void {
        self.meta.deinit(allocator);
        allocator.free(self.bytes);
        self.* = undefined;
    }
};

fn collectSkillDirNames(
    allocator: std.mem.Allocator,
    root_dir: std.fs.Dir,
    skills_rel: []const u8,
) ![][]u8 {
    var skills_dir = openSkillsDir(root_dir, skills_rel) catch |err| switch (err) {
        error.FileNotFound => return allocator.alloc([]u8, 0),
        else => return err,
    };
    defer skills_dir.close();

    var names: std.ArrayListUnmanaged([]u8) = .empty;
    errdefer deinitStringArrayList(allocator, &names);

    var it = skills_dir.iterate();
    while (try it.next()) |entry| {
        if (entry.kind != .directory) continue;
        const name = try allocator.dupe(u8, entry.name);
        errdefer allocator.free(name);
        try names.append(allocator, name);
    }

    std.sort.insertion([]u8, names.items, {}, stringLessThan);
    return names.toOwnedSlice(allocator);
}

fn freeStringList(allocator: std.mem.Allocator, list: [][]u8) void {
    for (list) |item| allocator.free(item);
    allocator.free(list);
}

fn deinitStringArrayList(allocator: std.mem.Allocator, list: *std.ArrayListUnmanaged([]u8)) void {
    for (list.items) |item| allocator.free(item);
    list.deinit(allocator);
}

fn openSkillsDir(root_dir: std.fs.Dir, skills_rel: []const u8) !std.fs.Dir {
    if (skills_rel.len == 0) return root_dir.openDir(".", .{ .iterate = true });
    return root_dir.openDir(skills_rel, .{ .iterate = true });
}

fn readSkillMarkdown(allocator: std.mem.Allocator, skill_dir: std.fs.Dir) !?[]u8 {
    var file = skill_dir.openFile("SKILL.md", .{}) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    defer file.close();

    const stat = try file.stat();
    if (stat.size > MAX_SKILL_MD_BYTES) return LookupError.SkillTooLarge;

    return try file.readToEndAlloc(allocator, MAX_SKILL_MD_BYTES);
}

fn parseSkillMeta(
    allocator: std.mem.Allocator,
    bytes: []const u8,
    skills_rel: []const u8,
    dir_name: []const u8,
) !SkillMeta {
    const frontmatter = frontmatterSlice(bytes) orelse return LookupError.InvalidSkillMarkdown;

    var parsed_name: ?[]const u8 = null;
    var parsed_description: ?[]const u8 = null;

    var lines = std.mem.splitScalar(u8, frontmatter, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r");
        if (line.len == 0) continue;

        const colon_idx = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        const key = std.mem.trim(u8, line[0..colon_idx], " \t");
        const value = std.mem.trim(u8, line[colon_idx + 1 ..], " \t");

        if (std.mem.eql(u8, key, "name")) {
            parsed_name = value;
        } else if (std.mem.eql(u8, key, "description")) {
            parsed_description = value;
        }
    }

    const name_value = if (parsed_name) |name|
        if (name.len == 0) dir_name else name
    else
        dir_name;
    const description_value = parsed_description orelse "";

    const name = try allocator.dupe(u8, name_value);
    errdefer allocator.free(name);
    const description = try allocator.dupe(u8, description_value);
    errdefer allocator.free(description);
    const dir_name_copy = try allocator.dupe(u8, dir_name);
    errdefer allocator.free(dir_name_copy);
    const rel_dir = try relativeSkillDir(allocator, skills_rel, dir_name);
    errdefer allocator.free(rel_dir);

    return .{
        .name = name,
        .description = description,
        .dir_name = dir_name_copy,
        .rel_dir = rel_dir,
    };
}

fn frontmatterSlice(bytes: []const u8) ?[]const u8 {
    const start = "---\n";
    const end = "\n---\n";
    if (!std.mem.startsWith(u8, bytes, start)) return null;

    const rest = bytes[start.len..];
    const end_idx = std.mem.indexOf(u8, rest, end) orelse return null;
    return rest[0..end_idx];
}

fn relativeSkillDir(
    allocator: std.mem.Allocator,
    skills_rel: []const u8,
    dir_name: []const u8,
) ![]u8 {
    if (skills_rel.len == 0) return allocator.dupe(u8, dir_name);
    return std.fmt.allocPrint(allocator, "{s}/{s}", .{ skills_rel, dir_name });
}

fn writeHashHex(out: *[16]u8, bytes: []const u8) void {
    const hash = std.hash.Wyhash.hash(0, bytes);
    _ = std.fmt.bufPrint(out, "{x:0>16}", .{hash}) catch unreachable;
}

fn skillLessThan(_: void, a: SkillMeta, b: SkillMeta) bool {
    const name_order = std.mem.order(u8, a.name, b.name);
    if (name_order != .eq) return name_order == .lt;
    return std.mem.order(u8, a.dir_name, b.dir_name) == .lt;
}

fn stringLessThan(_: void, a: []u8, b: []u8) bool {
    return std.mem.order(u8, a, b) == .lt;
}

test "skill_registry: parses SKILL frontmatter and lists sorted skills" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.makePath("skills/pdf");
    try tmp.dir.writeFile(.{
        .sub_path = "skills/pdf/SKILL.md",
        .data = "---\nname: pdf\ndescription: Work with PDF files.\n---\n# PDF\n",
    });

    const skills = try listSkills(std.testing.allocator, tmp.dir, "skills");
    defer freeSkillList(std.testing.allocator, skills);

    try std.testing.expectEqual(@as(usize, 1), skills.len);
    try std.testing.expectEqualStrings("pdf", skills[0].name);
    try std.testing.expectEqualStrings("Work with PDF files.", skills[0].description);
    try std.testing.expectEqualStrings("pdf", skills[0].dir_name);
}

test "skill_registry: listSkills cleans up appended metadata on later error" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.makePath("skills/a");
    try tmp.dir.makePath("skills/b");
    try tmp.dir.writeFile(.{
        .sub_path = "skills/a/SKILL.md",
        .data = "---\nname: first\n---\n# First\n",
    });
    try tmp.dir.writeFile(.{
        .sub_path = "skills/b/SKILL.md",
        .data = "# Missing frontmatter",
    });

    try std.testing.expectError(
        LookupError.InvalidSkillMarkdown,
        listSkills(std.testing.allocator, tmp.dir, "skills"),
    );
}

test "skill_registry: snapshot is deterministic and includes hash" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const skill_md = "---\nname: pdf\ndescription: PDF skill.\n---\n# PDF Body";
    try tmp.dir.makePath("skills/pdf");
    try tmp.dir.writeFile(.{
        .sub_path = "skills/pdf/SKILL.md",
        .data = skill_md,
    });

    var snapshot = try loadSkillSnapshot(std.testing.allocator, tmp.dir, "skills", "pdf");
    defer snapshot.deinit(std.testing.allocator);
    var second_snapshot = try loadSkillSnapshot(std.testing.allocator, tmp.dir, "skills", "pdf");
    defer second_snapshot.deinit(std.testing.allocator);

    var hasher = std.hash.Wyhash.init(0);
    hasher.update(skill_md);
    var expected_hash: [16]u8 = undefined;
    _ = std.fmt.bufPrint(&expected_hash, "{x:0>16}", .{hasher.final()}) catch unreachable;

    const expected_content = try std.fmt.allocPrint(
        std.testing.allocator,
        "# Skill: pdf\nsource: skills/pdf\nhash: {s}\n\n{s}",
        .{ expected_hash[0..], skill_md },
    );
    defer std.testing.allocator.free(expected_content);

    try std.testing.expectEqualStrings("pdf", snapshot.name);
    try std.testing.expectEqualStrings("skills/pdf", snapshot.source);
    try std.testing.expectEqualSlices(u8, expected_hash[0..], snapshot.hash_hex[0..]);
    try std.testing.expectEqualStrings(expected_content, snapshot.content);
    try std.testing.expectEqualSlices(u8, snapshot.hash_hex[0..], second_snapshot.hash_hex[0..]);
    try std.testing.expectEqualStrings(snapshot.content, second_snapshot.content);
}

test "skill_registry: duplicate names fail deterministically" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.makePath("skills/a");
    try tmp.dir.makePath("skills/b");
    try tmp.dir.writeFile(.{
        .sub_path = "skills/a/SKILL.md",
        .data = "---\nname: same\n---\n# A\n",
    });
    try tmp.dir.writeFile(.{
        .sub_path = "skills/b/SKILL.md",
        .data = "---\nname: same\n---\n# B\n",
    });

    try std.testing.expectError(
        LookupError.DuplicateSkillName,
        loadSkillSnapshot(std.testing.allocator, tmp.dir, "skills", "same"),
    );
}

test "skill_registry: invalid markdown without frontmatter fails" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.makePath("skills/bad");
    try tmp.dir.writeFile(.{
        .sub_path = "skills/bad/SKILL.md",
        .data = "# Missing frontmatter",
    });

    try std.testing.expectError(
        LookupError.InvalidSkillMarkdown,
        loadSkillSnapshot(std.testing.allocator, tmp.dir, "skills", "bad"),
    );
}
