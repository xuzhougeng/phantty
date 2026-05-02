//! DirectWrite font discovery and fallback for Windows
//!
//! This module provides font discovery using Windows DirectWrite API.
//! It allows finding fonts by name and provides fallback fonts for
//! characters not supported by the primary font.
//!
//! Based on Alacritty's crossfont implementation.

const std = @import("std");
const Allocator = std.mem.Allocator;

// Windows API imports
const windows = std.os.windows;
const HRESULT = windows.HRESULT;
const BOOL = windows.BOOL;
const GUID = windows.GUID;
const UINT32 = u32;
const UINT16 = u16;
const FLOAT = f32;
const WCHAR = u16;
const HMODULE = windows.HMODULE;

// COM base interface
const IUnknown = extern struct {
    vtable: *const VTable,

    const VTable = extern struct {
        QueryInterface: *const fn (*IUnknown, *const GUID, *?*anyopaque) callconv(.c) HRESULT,
        AddRef: *const fn (*IUnknown) callconv(.c) u32,
        Release: *const fn (*IUnknown) callconv(.c) u32,
    };

    pub fn release(self: *IUnknown) void {
        _ = self.vtable.Release(self);
    }
};

// DirectWrite GUIDs
const IID_IDWriteFactory = GUID{
    .Data1 = 0xb859ee5a,
    .Data2 = 0xd838,
    .Data3 = 0x4b5b,
    .Data4 = .{ 0xa2, 0xe8, 0x1a, 0xdc, 0x7d, 0x93, 0xdb, 0x48 },
};

const CLSID_DWriteFactory = GUID{
    .Data1 = 0xb859ee5a,
    .Data2 = 0xd838,
    .Data3 = 0x4b5b,
    .Data4 = .{ 0xa2, 0xe8, 0x1a, 0xdc, 0x7d, 0x93, 0xdb, 0x48 },
};

// DirectWrite enums
pub const DWRITE_FACTORY_TYPE = enum(u32) {
    SHARED = 0,
    ISOLATED = 1,
};

pub const DWRITE_FONT_WEIGHT = enum(u32) {
    THIN = 100,
    EXTRA_LIGHT = 200,
    LIGHT = 300,
    SEMI_LIGHT = 350,
    NORMAL = 400,
    MEDIUM = 500,
    SEMI_BOLD = 600,
    BOLD = 700,
    EXTRA_BOLD = 800,
    BLACK = 900,
    EXTRA_BLACK = 950,
};

pub const DWRITE_FONT_STYLE = enum(u32) {
    NORMAL = 0,
    OBLIQUE = 1,
    ITALIC = 2,
};

pub const DWRITE_FONT_STRETCH = enum(u32) {
    UNDEFINED = 0,
    ULTRA_CONDENSED = 1,
    EXTRA_CONDENSED = 2,
    CONDENSED = 3,
    SEMI_CONDENSED = 4,
    NORMAL = 5,
    SEMI_EXPANDED = 6,
    EXPANDED = 7,
    EXTRA_EXPANDED = 8,
    ULTRA_EXPANDED = 9,
};

// DirectWrite structures
pub const DWRITE_FONT_METRICS = extern struct {
    designUnitsPerEm: UINT16,
    ascent: UINT16,
    descent: UINT16,
    lineGap: i16,
    capHeight: UINT16,
    xHeight: UINT16,
    underlinePosition: i16,
    underlineThickness: UINT16,
    strikethroughPosition: i16,
    strikethroughThickness: UINT16,
};

pub const DWRITE_GLYPH_METRICS = extern struct {
    leftSideBearing: i32,
    advanceWidth: u32,
    rightSideBearing: i32,
    topSideBearing: i32,
    advanceHeight: u32,
    bottomSideBearing: i32,
    verticalOriginY: i32,
};

pub const DWRITE_GLYPH_OFFSET = extern struct {
    advanceOffset: FLOAT,
    ascenderOffset: FLOAT,
};

pub const DWRITE_GLYPH_RUN = extern struct {
    fontFace: ?*IDWriteFontFace,
    fontEmSize: FLOAT,
    glyphCount: UINT32,
    glyphIndices: [*]const UINT16,
    glyphAdvances: ?[*]const FLOAT,
    glyphOffsets: ?[*]const DWRITE_GLYPH_OFFSET,
    isSideways: BOOL,
    bidiLevel: UINT32,
};

// Forward declarations for DirectWrite interfaces
pub const IDWriteFactory = extern struct {
    vtable: *const VTable,

    const VTable = extern struct {
        // IUnknown
        QueryInterface: *const fn (*IDWriteFactory, *const GUID, *?*anyopaque) callconv(.c) HRESULT,
        AddRef: *const fn (*IDWriteFactory) callconv(.c) u32,
        Release: *const fn (*IDWriteFactory) callconv(.c) u32,
        // IDWriteFactory
        GetSystemFontCollection: *const fn (*IDWriteFactory, *?*IDWriteFontCollection, BOOL) callconv(.c) HRESULT,
        CreateCustomFontCollection: *const anyopaque,
        RegisterFontCollectionLoader: *const anyopaque,
        UnregisterFontCollectionLoader: *const anyopaque,
        CreateFontFileReference: *const anyopaque,
        CreateCustomFontFileReference: *const anyopaque,
        CreateFontFace: *const fn (
            *IDWriteFactory,
            DWRITE_FONT_FACE_TYPE,
            UINT32,
            [*]const ?*IDWriteFontFile,
            UINT32,
            DWRITE_FONT_SIMULATIONS,
            *?*IDWriteFontFace,
        ) callconv(.c) HRESULT,
        CreateRenderingParams: *const anyopaque,
        CreateMonitorRenderingParams: *const anyopaque,
        CreateCustomRenderingParams: *const anyopaque,
        RegisterFontFileLoader: *const anyopaque,
        UnregisterFontFileLoader: *const anyopaque,
        CreateTextFormat: *const fn (
            *IDWriteFactory,
            [*:0]const WCHAR, // fontFamilyName
            ?*IDWriteFontCollection, // fontCollection
            DWRITE_FONT_WEIGHT,
            DWRITE_FONT_STYLE,
            DWRITE_FONT_STRETCH,
            FLOAT, // fontSize
            [*:0]const WCHAR, // localeName
            *?*IDWriteTextFormat,
        ) callconv(.c) HRESULT,
        CreateTypography: *const anyopaque,
        GetGdiInterop: *const anyopaque,
        CreateTextLayout: *const anyopaque,
        CreateGdiCompatibleTextLayout: *const anyopaque,
        CreateEllipsisTrimmingSign: *const anyopaque,
        CreateTextAnalyzer: *const anyopaque,
        CreateNumberSubstitution: *const anyopaque,
        CreateGlyphRunAnalysis: *const anyopaque,
    };

    pub fn getSystemFontCollection(self: *IDWriteFactory, check_updates: bool) !*IDWriteFontCollection {
        var collection: ?*IDWriteFontCollection = null;
        const hr = self.vtable.GetSystemFontCollection(self, &collection, if (check_updates) 1 else 0);
        if (hr < 0) return error.DirectWriteError;
        return collection orelse error.DirectWriteError;
    }

    pub fn release(self: *IDWriteFactory) void {
        _ = self.vtable.Release(self);
    }
};

pub const DWRITE_FONT_FACE_TYPE = enum(u32) {
    CFF = 0,
    TRUETYPE = 1,
    TRUETYPE_COLLECTION = 2,
    TYPE1 = 3,
    VECTOR = 4,
    BITMAP = 5,
    UNKNOWN = 6,
    RAW_CFF = 7,
};

pub const DWRITE_FONT_SIMULATIONS = packed struct(u32) {
    none: bool = false,
    bold: bool = false,
    oblique: bool = false,
    _padding: u29 = 0,
};

pub const IDWriteFontFile = extern struct {
    vtable: *const VTable,

    const VTable = extern struct {
        QueryInterface: *const fn (*IDWriteFontFile, *const GUID, *?*anyopaque) callconv(.c) HRESULT,
        AddRef: *const fn (*IDWriteFontFile) callconv(.c) u32,
        Release: *const fn (*IDWriteFontFile) callconv(.c) u32,
        GetReferenceKey: *const fn (*IDWriteFontFile, *?*const anyopaque, *UINT32) callconv(.c) HRESULT,
        GetLoader: *const fn (*IDWriteFontFile, *?*IDWriteFontFileLoader) callconv(.c) HRESULT,
        Analyze: *const anyopaque,
    };

    pub fn getReferenceKey(self: *IDWriteFontFile) !struct { key: *const anyopaque, size: u32 } {
        var key: ?*const anyopaque = null;
        var size: UINT32 = 0;
        const hr = self.vtable.GetReferenceKey(self, &key, &size);
        if (hr < 0) return error.DirectWriteError;
        return .{ .key = key orelse return error.DirectWriteError, .size = size };
    }

    pub fn getLoader(self: *IDWriteFontFile) !*IDWriteFontFileLoader {
        var loader: ?*IDWriteFontFileLoader = null;
        const hr = self.vtable.GetLoader(self, &loader);
        if (hr < 0) return error.DirectWriteError;
        return loader orelse error.DirectWriteError;
    }

    pub fn release(self: *IDWriteFontFile) void {
        _ = self.vtable.Release(self);
    }
};

// GUID for IDWriteLocalFontFileLoader
const IID_IDWriteLocalFontFileLoader = GUID{
    .Data1 = 0xb2d9f3ec,
    .Data2 = 0xc9fe,
    .Data3 = 0x4a11,
    .Data4 = .{ 0xa2, 0xec, 0xd8, 0x62, 0x08, 0xf7, 0xc0, 0xa2 },
};

pub const IDWriteFontFileLoader = extern struct {
    vtable: *const VTable,

    const VTable = extern struct {
        QueryInterface: *const fn (*IDWriteFontFileLoader, *const GUID, *?*anyopaque) callconv(.c) HRESULT,
        AddRef: *const fn (*IDWriteFontFileLoader) callconv(.c) u32,
        Release: *const fn (*IDWriteFontFileLoader) callconv(.c) u32,
        CreateStreamFromKey: *const anyopaque,
    };

    pub fn queryLocalFontFileLoader(self: *IDWriteFontFileLoader) ?*IDWriteLocalFontFileLoader {
        var local_loader: ?*anyopaque = null;
        const hr = self.vtable.QueryInterface(self, &IID_IDWriteLocalFontFileLoader, &local_loader);
        if (hr < 0 or local_loader == null) return null;
        return @ptrCast(@alignCast(local_loader));
    }

    pub fn release(self: *IDWriteFontFileLoader) void {
        _ = self.vtable.Release(self);
    }
};

pub const IDWriteLocalFontFileLoader = extern struct {
    vtable: *const VTable,

    const VTable = extern struct {
        QueryInterface: *const fn (*IDWriteLocalFontFileLoader, *const GUID, *?*anyopaque) callconv(.c) HRESULT,
        AddRef: *const fn (*IDWriteLocalFontFileLoader) callconv(.c) u32,
        Release: *const fn (*IDWriteLocalFontFileLoader) callconv(.c) u32,
        CreateStreamFromKey: *const anyopaque,
        GetFilePathLengthFromKey: *const fn (*IDWriteLocalFontFileLoader, *const anyopaque, UINT32, *UINT32) callconv(.c) HRESULT,
        GetFilePathFromKey: *const fn (*IDWriteLocalFontFileLoader, *const anyopaque, UINT32, [*]WCHAR, UINT32) callconv(.c) HRESULT,
        GetLastWriteTimeFromKey: *const anyopaque,
    };

    pub fn getFilePathLengthFromKey(self: *IDWriteLocalFontFileLoader, key: *const anyopaque, key_size: u32) !u32 {
        var length: UINT32 = 0;
        const hr = self.vtable.GetFilePathLengthFromKey(self, key, key_size, &length);
        if (hr < 0) return error.DirectWriteError;
        return length;
    }

    pub fn getFilePathFromKey(self: *IDWriteLocalFontFileLoader, key: *const anyopaque, key_size: u32, buffer: []WCHAR) !void {
        const hr = self.vtable.GetFilePathFromKey(self, key, key_size, buffer.ptr, @intCast(buffer.len));
        if (hr < 0) return error.DirectWriteError;
    }

    pub fn release(self: *IDWriteLocalFontFileLoader) void {
        _ = self.vtable.Release(self);
    }
};

pub const IDWriteFontCollection = extern struct {
    vtable: *const VTable,

    const VTable = extern struct {
        // IUnknown
        QueryInterface: *const fn (*IDWriteFontCollection, *const GUID, *?*anyopaque) callconv(.c) HRESULT,
        AddRef: *const fn (*IDWriteFontCollection) callconv(.c) u32,
        Release: *const fn (*IDWriteFontCollection) callconv(.c) u32,
        // IDWriteFontCollection
        GetFontFamilyCount: *const fn (*IDWriteFontCollection) callconv(.c) UINT32,
        GetFontFamily: *const fn (*IDWriteFontCollection, UINT32, *?*IDWriteFontFamily) callconv(.c) HRESULT,
        FindFamilyName: *const fn (*IDWriteFontCollection, [*:0]const WCHAR, *UINT32, *BOOL) callconv(.c) HRESULT,
        GetFontFromFontFace: *const anyopaque,
    };

    pub fn getFontFamilyCount(self: *IDWriteFontCollection) u32 {
        return self.vtable.GetFontFamilyCount(self);
    }

    pub fn getFontFamily(self: *IDWriteFontCollection, index: u32) !*IDWriteFontFamily {
        var family: ?*IDWriteFontFamily = null;
        const hr = self.vtable.GetFontFamily(self, index, &family);
        if (hr < 0) return error.DirectWriteError;
        return family orelse error.DirectWriteError;
    }

    pub fn findFamilyName(self: *IDWriteFontCollection, name: [*:0]const WCHAR) ?u32 {
        var index: UINT32 = 0;
        var exists: BOOL = 0;
        const hr = self.vtable.FindFamilyName(self, name, &index, &exists);
        if (hr < 0 or exists == 0) return null;
        return index;
    }

    pub fn release(self: *IDWriteFontCollection) void {
        _ = self.vtable.Release(self);
    }
};

pub const IDWriteFontFamily = extern struct {
    vtable: *const VTable,

    const VTable = extern struct {
        // IUnknown
        QueryInterface: *const fn (*IDWriteFontFamily, *const GUID, *?*anyopaque) callconv(.c) HRESULT,
        AddRef: *const fn (*IDWriteFontFamily) callconv(.c) u32,
        Release: *const fn (*IDWriteFontFamily) callconv(.c) u32,
        // IDWriteFontList (inherited)
        GetFontCollection: *const anyopaque,
        GetFontCount: *const fn (*IDWriteFontFamily) callconv(.c) UINT32,
        GetFont: *const fn (*IDWriteFontFamily, UINT32, *?*IDWriteFont) callconv(.c) HRESULT,
        // IDWriteFontFamily
        GetFamilyNames: *const fn (*IDWriteFontFamily, *?*IDWriteLocalizedStrings) callconv(.c) HRESULT,
        GetFirstMatchingFont: *const fn (
            *IDWriteFontFamily,
            DWRITE_FONT_WEIGHT,
            DWRITE_FONT_STRETCH,
            DWRITE_FONT_STYLE,
            *?*IDWriteFont,
        ) callconv(.c) HRESULT,
        GetMatchingFonts: *const anyopaque,
    };

    pub fn getFontCount(self: *IDWriteFontFamily) u32 {
        return self.vtable.GetFontCount(self);
    }

    pub fn getFont(self: *IDWriteFontFamily, index: u32) !*IDWriteFont {
        var font: ?*IDWriteFont = null;
        const hr = self.vtable.GetFont(self, index, &font);
        if (hr < 0) return error.DirectWriteError;
        return font orelse error.DirectWriteError;
    }

    pub fn getFirstMatchingFont(
        self: *IDWriteFontFamily,
        weight: DWRITE_FONT_WEIGHT,
        stretch: DWRITE_FONT_STRETCH,
        style: DWRITE_FONT_STYLE,
    ) !*IDWriteFont {
        var font: ?*IDWriteFont = null;
        const hr = self.vtable.GetFirstMatchingFont(self, weight, stretch, style, &font);
        if (hr < 0) return error.DirectWriteError;
        return font orelse error.DirectWriteError;
    }

    pub fn release(self: *IDWriteFontFamily) void {
        _ = self.vtable.Release(self);
    }
};

pub const IDWriteFont = extern struct {
    vtable: *const VTable,

    const VTable = extern struct {
        // IUnknown
        QueryInterface: *const fn (*IDWriteFont, *const GUID, *?*anyopaque) callconv(.c) HRESULT,
        AddRef: *const fn (*IDWriteFont) callconv(.c) u32,
        Release: *const fn (*IDWriteFont) callconv(.c) u32,
        // IDWriteFont
        GetFontFamily: *const anyopaque,
        GetWeight: *const fn (*IDWriteFont) callconv(.c) DWRITE_FONT_WEIGHT,
        GetStretch: *const fn (*IDWriteFont) callconv(.c) DWRITE_FONT_STRETCH,
        GetStyle: *const fn (*IDWriteFont) callconv(.c) DWRITE_FONT_STYLE,
        IsSymbolFont: *const fn (*IDWriteFont) callconv(.c) BOOL,
        GetFaceNames: *const fn (*IDWriteFont, *?*IDWriteLocalizedStrings) callconv(.c) HRESULT,
        GetInformationalStrings: *const anyopaque,
        GetSimulations: *const anyopaque,
        GetMetrics: *const fn (*IDWriteFont, *DWRITE_FONT_METRICS) callconv(.c) void,
        HasCharacter: *const fn (*IDWriteFont, UINT32, *BOOL) callconv(.c) HRESULT,
        CreateFontFace: *const fn (*IDWriteFont, *?*IDWriteFontFace) callconv(.c) HRESULT,
    };

    pub fn getWeight(self: *IDWriteFont) DWRITE_FONT_WEIGHT {
        return self.vtable.GetWeight(self);
    }

    pub fn getStretch(self: *IDWriteFont) DWRITE_FONT_STRETCH {
        return self.vtable.GetStretch(self);
    }

    pub fn getStyle(self: *IDWriteFont) DWRITE_FONT_STYLE {
        return self.vtable.GetStyle(self);
    }

    pub fn hasCharacter(self: *IDWriteFont, codepoint: u32) bool {
        var exists: BOOL = 0;
        const hr = self.vtable.HasCharacter(self, codepoint, &exists);
        return hr >= 0 and exists != 0;
    }

    pub fn createFontFace(self: *IDWriteFont) !*IDWriteFontFace {
        var face: ?*IDWriteFontFace = null;
        const hr = self.vtable.CreateFontFace(self, &face);
        if (hr < 0) return error.DirectWriteError;
        return face orelse error.DirectWriteError;
    }

    pub fn release(self: *IDWriteFont) void {
        _ = self.vtable.Release(self);
    }
};

pub const IDWriteFontFace = extern struct {
    vtable: *const VTable,

    const VTable = extern struct {
        // IUnknown
        QueryInterface: *const fn (*IDWriteFontFace, *const GUID, *?*anyopaque) callconv(.c) HRESULT,
        AddRef: *const fn (*IDWriteFontFace) callconv(.c) u32,
        Release: *const fn (*IDWriteFontFace) callconv(.c) u32,
        // IDWriteFontFace
        GetType: *const fn (*IDWriteFontFace) callconv(.c) DWRITE_FONT_FACE_TYPE,
        GetFiles: *const fn (*IDWriteFontFace, *UINT32, ?[*]?*IDWriteFontFile) callconv(.c) HRESULT,
        GetIndex: *const fn (*IDWriteFontFace) callconv(.c) UINT32,
        GetSimulations: *const anyopaque,
        IsSymbolFont: *const anyopaque,
        GetMetrics: *const fn (*IDWriteFontFace, *DWRITE_FONT_METRICS) callconv(.c) void,
        GetGlyphCount: *const fn (*IDWriteFontFace) callconv(.c) UINT16,
        GetDesignGlyphMetrics: *const fn (
            *IDWriteFontFace,
            [*]const UINT16, // glyphIndices
            UINT32, // glyphCount
            [*]DWRITE_GLYPH_METRICS, // glyphMetrics
            BOOL, // isSideways
        ) callconv(.c) HRESULT,
        GetGlyphIndices: *const fn (
            *IDWriteFontFace,
            [*]const UINT32, // codePoints
            UINT32, // codePointCount
            [*]UINT16, // glyphIndices
        ) callconv(.c) HRESULT,
        TryGetFontTable: *const anyopaque,
        ReleaseFontTable: *const anyopaque,
        GetGlyphRunOutline: *const anyopaque,
        GetRecommendedRenderingMode: *const anyopaque,
        GetGdiCompatibleMetrics: *const anyopaque,
        GetGdiCompatibleGlyphMetrics: *const anyopaque,
    };

    pub fn getMetrics(self: *IDWriteFontFace, metrics: *DWRITE_FONT_METRICS) void {
        self.vtable.GetMetrics(self, metrics);
    }

    /// Get the font files for this font face.
    /// Returns the first font file (most fonts have exactly one).
    pub fn getFiles(self: *IDWriteFontFace) !*IDWriteFontFile {
        // First call to get the count
        var file_count: UINT32 = 0;
        var hr = self.vtable.GetFiles(self, &file_count, null);
        if (hr < 0) return error.DirectWriteError;
        if (file_count == 0) return error.NoFontFiles;

        // Second call to get the files
        var files: [1]?*IDWriteFontFile = .{null};
        var count: UINT32 = 1;
        hr = self.vtable.GetFiles(self, &count, &files);
        if (hr < 0) return error.DirectWriteError;

        return files[0] orelse error.DirectWriteError;
    }

    /// Get the index of this font face within a TrueType Collection
    pub fn getIndex(self: *IDWriteFontFace) u32 {
        return self.vtable.GetIndex(self);
    }

    pub fn getGlyphIndices(self: *IDWriteFontFace, codepoints: []const u32, glyph_indices: []u16) !void {
        std.debug.assert(codepoints.len == glyph_indices.len);
        const hr = self.vtable.GetGlyphIndices(
            self,
            codepoints.ptr,
            @intCast(codepoints.len),
            glyph_indices.ptr,
        );
        if (hr < 0) return error.DirectWriteError;
    }

    pub fn getDesignGlyphMetrics(
        self: *IDWriteFontFace,
        glyph_indices: []const u16,
        metrics: []DWRITE_GLYPH_METRICS,
    ) !void {
        std.debug.assert(glyph_indices.len == metrics.len);
        const hr = self.vtable.GetDesignGlyphMetrics(
            self,
            glyph_indices.ptr,
            @intCast(glyph_indices.len),
            metrics.ptr,
            0,
        );
        if (hr < 0) return error.DirectWriteError;
    }

    pub fn release(self: *IDWriteFontFace) void {
        _ = self.vtable.Release(self);
    }
};

pub const IDWriteTextFormat = extern struct {
    vtable: *const VTable,

    const VTable = extern struct {
        QueryInterface: *const fn (*IDWriteTextFormat, *const GUID, *?*anyopaque) callconv(.c) HRESULT,
        AddRef: *const fn (*IDWriteTextFormat) callconv(.c) u32,
        Release: *const fn (*IDWriteTextFormat) callconv(.c) u32,
        // ... other methods
    };

    pub fn release(self: *IDWriteTextFormat) void {
        _ = self.vtable.Release(self);
    }
};

pub const IDWriteLocalizedStrings = extern struct {
    vtable: *const VTable,

    const VTable = extern struct {
        QueryInterface: *const fn (*IDWriteLocalizedStrings, *const GUID, *?*anyopaque) callconv(.c) HRESULT,
        AddRef: *const fn (*IDWriteLocalizedStrings) callconv(.c) u32,
        Release: *const fn (*IDWriteLocalizedStrings) callconv(.c) u32,
        GetCount: *const fn (*IDWriteLocalizedStrings) callconv(.c) UINT32,
        FindLocaleName: *const anyopaque,
        GetLocaleNameLength: *const anyopaque,
        GetLocaleName: *const anyopaque,
        GetStringLength: *const fn (*IDWriteLocalizedStrings, UINT32, *UINT32) callconv(.c) HRESULT,
        GetString: *const fn (*IDWriteLocalizedStrings, UINT32, [*]WCHAR, UINT32) callconv(.c) HRESULT,
    };

    pub fn getCount(self: *IDWriteLocalizedStrings) u32 {
        return self.vtable.GetCount(self);
    }

    pub fn getStringLength(self: *IDWriteLocalizedStrings, index: u32) !u32 {
        var len: UINT32 = 0;
        const hr = self.vtable.GetStringLength(self, index, &len);
        if (hr < 0) return error.DirectWriteError;
        return len;
    }

    pub fn getString(self: *IDWriteLocalizedStrings, index: u32, buffer: []WCHAR) !void {
        const hr = self.vtable.GetString(self, index, buffer.ptr, @intCast(buffer.len));
        if (hr < 0) return error.DirectWriteError;
    }

    pub fn release(self: *IDWriteLocalizedStrings) void {
        _ = self.vtable.Release(self);
    }
};

// DWriteCreateFactory function signature
const DWriteCreateFactoryFn = *const fn (
    DWRITE_FACTORY_TYPE,
    *const GUID,
    *?*IDWriteFactory,
) callconv(.c) HRESULT;

/// DirectWrite font discovery system
pub const FontDiscovery = struct {
    factory: *IDWriteFactory,
    system_collection: *IDWriteFontCollection,
    dwrite_dll: HMODULE,

    pub fn init() !FontDiscovery {
        // Load dwrite.dll
        const dwrite_dll = windows.kernel32.LoadLibraryW(
            std.unicode.utf8ToUtf16LeStringLiteral("dwrite.dll"),
        ) orelse return error.DWriteLoadFailed;
        errdefer _ = windows.kernel32.FreeLibrary(dwrite_dll);

        // Get DWriteCreateFactory
        const create_factory: DWriteCreateFactoryFn = @ptrCast(
            windows.kernel32.GetProcAddress(dwrite_dll, "DWriteCreateFactory") orelse
                return error.DWriteCreateFactoryNotFound,
        );

        // Create factory
        var factory: ?*IDWriteFactory = null;
        const hr = create_factory(.SHARED, &IID_IDWriteFactory, &factory);
        if (hr < 0) return error.DirectWriteError;
        const factory_ptr = factory orelse return error.DirectWriteError;
        errdefer factory_ptr.release();

        // Get system font collection
        const collection = try factory_ptr.getSystemFontCollection(false);
        errdefer collection.release();

        return .{
            .factory = factory_ptr,
            .system_collection = collection,
            .dwrite_dll = dwrite_dll,
        };
    }

    pub fn deinit(self: *FontDiscovery) void {
        self.system_collection.release();
        self.factory.release();
        _ = windows.kernel32.FreeLibrary(self.dwrite_dll);
    }

    /// Find a font family by name
    pub fn findFontFamily(self: *FontDiscovery, family_name: []const u8) !?*IDWriteFontFamily {
        // Convert UTF-8 to UTF-16
        var name_buf: [256]u16 = undefined;
        const name_len = std.unicode.utf8ToUtf16Le(&name_buf, family_name) catch return error.InvalidFontName;
        if (name_len >= name_buf.len) return error.FontNameTooLong;
        name_buf[name_len] = 0;

        const index = self.system_collection.findFamilyName(@ptrCast(&name_buf)) orelse return null;
        return try self.system_collection.getFontFamily(index);
    }

    /// Find the best matching font in a family
    pub fn findFont(
        self: *FontDiscovery,
        family_name: []const u8,
        weight: DWRITE_FONT_WEIGHT,
        style: DWRITE_FONT_STYLE,
    ) !?*IDWriteFont {
        const family = (try self.findFontFamily(family_name)) orelse return null;
        defer family.release();

        return try family.getFirstMatchingFont(weight, .NORMAL, style);
    }

    /// Find a fallback font that supports a specific character
    pub fn findFallbackFont(self: *FontDiscovery, codepoint: u32) !?*IDWriteFont {
        const count = self.system_collection.getFontFamilyCount();

        for (0..count) |i| {
            const family = try self.system_collection.getFontFamily(@intCast(i));
            defer family.release();

            const font_count = family.getFontCount();
            for (0..font_count) |j| {
                const font = family.getFont(@intCast(j)) catch continue;
                if (font.hasCharacter(codepoint)) {
                    return font;
                }
                font.release();
            }
        }

        return null;
    }

    /// Try a preferred family list first before falling back to a blind
    /// system-wide scan. This helps keep CJK fallback stable on Windows.
    pub fn findPreferredFallbackFont(
        self: *FontDiscovery,
        codepoint: u32,
        families: []const []const u8,
    ) !?*IDWriteFont {
        for (families) |family_name| {
            const font = (try self.findFont(family_name, .NORMAL, .NORMAL)) orelse continue;
            if (font.hasCharacter(codepoint)) return font;
            font.release();
        }

        return null;
    }

    /// List all font families (for debugging)
    pub fn listFontFamilies(self: *FontDiscovery, allocator: Allocator) ![][]const u8 {
        const count = self.system_collection.getFontFamilyCount();
        var families = try allocator.alloc([]const u8, count);
        var added: usize = 0;

        for (0..count) |i| {
            const family = self.system_collection.getFontFamily(@intCast(i)) catch continue;
            defer family.release();

            var names: ?*IDWriteLocalizedStrings = null;
            if (family.vtable.GetFamilyNames(family, &names) >= 0) {
                if (names) |n| {
                    defer n.release();

                    const len = n.getStringLength(0) catch continue;
                    var name_buf = try allocator.alloc(u16, len + 1);
                    defer allocator.free(name_buf);

                    n.getString(0, name_buf) catch continue;

                    // Convert UTF-16 to UTF-8
                    const utf8_buf = std.unicode.utf16LeToUtf8Alloc(allocator, name_buf[0..len]) catch continue;

                    families[added] = utf8_buf;
                    added += 1;
                }
            }
        }

        return families[0..added];
    }

    /// Result of font discovery including file path and face index
    pub const FontResult = struct {
        /// Font file path (UTF-8, null-terminated, owned by caller)
        path: [:0]const u8,
        /// Face index within the font file (for TTC fonts)
        face_index: u32,
        /// Allocator used for path (needed for cleanup)
        allocator: Allocator,

        pub fn deinit(self: *FontResult) void {
            self.allocator.free(self.path);
        }
    };

    /// Find a font by family name and get its file path for loading with FreeType.
    /// Returns the file path and face index. Caller owns the returned path.
    pub fn findFontFilePath(
        self: *FontDiscovery,
        allocator: Allocator,
        family_name: []const u8,
        weight: DWRITE_FONT_WEIGHT,
        style: DWRITE_FONT_STYLE,
    ) !?FontResult {
        // Find the font
        const font = (try self.findFont(family_name, weight, style)) orelse return null;
        defer font.release();

        // Create a font face to access file info
        const face = try font.createFontFace();
        defer face.release();

        // Get the face index (for TTC fonts)
        const face_index = face.getIndex();

        // Get the font file
        const font_file = try face.getFiles();
        defer font_file.release();

        // Get the file loader
        const loader = try font_file.getLoader();
        defer loader.release();

        // Try to get the local font file loader (only works for local fonts)
        const local_loader = loader.queryLocalFontFileLoader() orelse {
            return error.NotLocalFont;
        };
        defer local_loader.release();

        // Get the reference key for the file
        const ref_key = try font_file.getReferenceKey();

        // Get the path length
        const path_len = try local_loader.getFilePathLengthFromKey(ref_key.key, ref_key.size);

        // Allocate buffer for the path (UTF-16)
        var path_buf = try allocator.alloc(u16, path_len + 1);
        defer allocator.free(path_buf);

        // Get the path
        try local_loader.getFilePathFromKey(ref_key.key, ref_key.size, path_buf);

        // Convert UTF-16 to UTF-8 with null terminator
        const utf8_path = std.unicode.utf16LeToUtf8AllocZ(allocator, path_buf[0..path_len]) catch return error.InvalidPath;

        return FontResult{
            .path = utf8_path,
            .face_index = face_index,
            .allocator = allocator,
        };
    }
};

/// Loaded font with metrics
pub const LoadedFont = struct {
    face: *IDWriteFontFace,
    metrics: DWRITE_FONT_METRICS,

    pub fn init(font: *IDWriteFont) !LoadedFont {
        const face = try font.createFontFace();
        errdefer face.release();

        var metrics: DWRITE_FONT_METRICS = undefined;
        face.getMetrics(&metrics);

        return .{
            .face = face,
            .metrics = metrics,
        };
    }

    pub fn deinit(self: *LoadedFont) void {
        self.face.release();
    }

    /// Get the glyph index for a codepoint (0 = missing glyph)
    pub fn getGlyphIndex(self: *LoadedFont, codepoint: u32) u16 {
        var codepoints = [_]u32{codepoint};
        var indices = [_]u16{0};
        self.face.getGlyphIndices(&codepoints, &indices) catch return 0;
        return indices[0];
    }

    /// Check if this font has a glyph for the given codepoint
    pub fn hasGlyph(self: *LoadedFont, codepoint: u32) bool {
        return self.getGlyphIndex(codepoint) != 0;
    }
};

// Test that the module compiles (actual tests need Windows)
test "directwrite module compiles" {
    // Just ensure the types are properly defined
    _ = FontDiscovery;
    _ = LoadedFont;
}
