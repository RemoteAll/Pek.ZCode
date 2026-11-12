//! 方言覆盖审计入口：`zig build audit-dialects`。
//!
//! 目的：用**事实**回答「小语种方言迁移完了么」——把 `DatabaseKind` 里每个方言
//! 都拿去跑一遍 SQL 生成函数，凡是 `isImplemented()` 为真却失败的，全部列出来。
//!
//! 输出（每行一条缺口）：`[GAP] <方言> <能力> <细节>`；结尾打印统计。
//! 有缺口时退出码 1（可直接接 CI）。
//!
//! `mongodb` / `influxdb` 属**有意未实现**（文档库 / Line Protocol，无 SQL 语义），
//! 直接跳过，不算缺口。

const std = @import("std");
const zcode = @import("zcode");
const zzig = @import("zzig");

const DatabaseKind = zcode.DatabaseKind;
const DataType = zcode.DataType;
const TableMeta = zcode.TableMeta;
const ColumnMeta = zcode.ColumnMeta;
const Buf = zzig.Buf;

/// 全部方言（与 `DatabaseKind` 一一对应；新增方言时必须同步加进来，否则审计会漏）。
const all_kinds = [_]DatabaseKind{
    .sqlite,   .mysql,     .sqlserver, .postgresql, .kingbase, .highgo,
    .vastbase, .oracle,    .duckdb,    .clickhouse, .tdengine, .influxdb,
    .hana,     .firebird,  .db2,       .dameng,     .iris,     .access,
    .sqlce,    .mongodb,   .nova,
};

const Gap = struct { kind: DatabaseKind, area: []const u8, detail: []const u8 };

/// 有自增语义的方言（ClickHouse / TDengine 不支持自增，不在此列）
fn hasIdentity(kind: DatabaseKind) bool {
    return switch (kind) {
        .clickhouse, .tdengine => false,
        else => true,
    };
}

fn testTable() TableMeta {
    return .{
        .name = "Demo",
        .table_name = "Demo",
        .columns = &.{
            .{ .name = "Id", .data_type = .int32, .identity = true, .primary_key = true },
            .{ .name = "Name", .data_type = .string, .length = 50 },
            .{ .name = "Amount", .data_type = .decimal, .precision = 18, .scale = 4 },
            .{ .name = "CreateTime", .data_type = .datetime },
        },
        .indexes = &.{
            .{ .name = "IX_Demo_Name", .columns = &.{"Name"} },
        },
    };
}

pub fn main() !u8 {
    var gpa_state = std.heap.DebugAllocator(.{}){};
    defer _ = gpa_state.deinit();
    const a = gpa_state.allocator();

    var gaps: std.ArrayList(Gap) = .empty;
    defer {
        for (gaps.items) |g| a.free(@constCast(g.detail));
        gaps.deinit(a);
    }

    const table = testTable();
    var implemented: usize = 0;

    for (all_kinds) |kind| {
        if (!kind.isImplemented()) continue;
        implemented += 1;

        // 1) 类型映射：12 种 DataType 逐个
        for (DataType.all) |dt| {
            const col = ColumnMeta{ .name = "C", .data_type = dt, .length = 50, .precision = 18, .scale = 4 };
            if (kind.fieldTypeAlloc(a, col)) |sql| {
                a.free(sql);
            } else |e| {
                try gaps.append(a, .{ .kind = kind, .area = "type", .detail = try std.fmt.allocPrint(a, "{s}:{s}", .{ dt.name(), @errorName(e) }) });
            }
        }

        // 2) 标识符引用
        {
            var b = Buf.init(a);
            defer b.deinit();
            if (kind.pushQuoted(&b, "Demo")) {} else |e| {
                try gaps.append(a, .{ .kind = kind, .area = "quote", .detail = try a.dupe(u8, @errorName(e)) });
            }
        }

        // 3) 占位符
        {
            var b = Buf.init(a);
            defer b.deinit();
            if (kind.pushPlaceholder(&b, 0)) {} else |e| {
                try gaps.append(a, .{ .kind = kind, .area = "placeholder", .detail = try a.dupe(u8, @errorName(e)) });
            }
        }

        // 4) 分页
        if (kind.usesTopPaging()) {
            // Access / SqlCe 只有 TOP：首页必须能出 SQL；带 offset 必须「明确报错」而不是生成错 SQL
            if (kind.applyPagingAlloc(a, "SELECT * FROM Demo", "", 0, 20)) |sql| {
                a.free(sql);
            } else |e| {
                try gaps.append(a, .{ .kind = kind, .area = "paging-first", .detail = try a.dupe(u8, @errorName(e)) });
            }
            if (kind.applyPagingAlloc(a, "SELECT * FROM Demo", "", 10, 20)) |sql| {
                a.free(sql);
                try gaps.append(a, .{ .kind = kind, .area = "paging-offset", .detail = try a.dupe(u8, "声明不支持 OFFSET 却生成了 SQL（调用方会误用）") });
            } else |_| {}
        } else if (kind.applyPagingAlloc(a, "SELECT * FROM Demo", "", 10, 20)) |sql| {
            a.free(sql);
        } else |e| {
            try gaps.append(a, .{ .kind = kind, .area = "paging", .detail = try a.dupe(u8, @errorName(e)) });
        }

        // 4b) 自增取值语句：有自增语义的库必须给语句（空串 = 调用方拿到无用的诊断 SQL）
        if (hasIdentity(kind) and kind.lastIdentitySql().len == 0) {
            try gaps.append(a, .{ .kind = kind, .area = "identitySql", .detail = try a.dupe(u8, "返回空串") });
        }

        // 5) 建表 DDL
        if (kind.createTableAlloc(a, &table)) |stmts| {
            for (stmts) |s| a.free(s);
            a.free(stmts);
        } else |e| {
            try gaps.append(a, .{ .kind = kind, .area = "ddl", .detail = try a.dupe(u8, @errorName(e)) });
        }

        // 6) 索引 DDL
        for (table.indexes) |idx| {
            if (kind.createIndexAlloc(a, &table, idx)) |maybe| {
                if (maybe) |sql| a.free(sql);
            } else |e| {
                try gaps.append(a, .{ .kind = kind, .area = "index", .detail = try a.dupe(u8, @errorName(e)) });
            }
        }

        // 7) 改列（`Full` 档用到）
        for (table.columns) |col| {
            if (kind.alterColumnAlloc(a, &table, col)) |maybe| {
                if (maybe) |sql| a.free(sql);
            } else |e| {
                try gaps.append(a, .{ .kind = kind, .area = "alter", .detail = try std.fmt.allocPrint(a, "{s}:{s}", .{ col.name, @errorName(e) }) });
            }
        }

        // 8) 删列（`Full` 档用到）
        if (kind.dropColumnAlloc(a, table.name, "Ex1")) |maybe| {
            if (maybe) |sql| a.free(sql);
        } else |e| {
            try gaps.append(a, .{ .kind = kind, .area = "dropColumn", .detail = try a.dupe(u8, @errorName(e)) });
        }
    }

    if (gaps.items.len == 0) {
        std.debug.print("方言审计通过：{d}/{d} 个可实现方言，全部生成函数均无缺口\n", .{ implemented, implemented });
    } else {
        for (gaps.items) |g| {
            std.debug.print("[GAP] {s} {s} {s}\n", .{ g.kind.name(), g.area, g.detail });
        }
        std.debug.print("方言审计失败：{d} 个缺口（已实现方言 {d} 个）\n", .{ gaps.items.len, implemented });
    }
    return if (gaps.items.len == 0) 0 else 1;
}
