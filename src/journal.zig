//! The recording journal: the format of the raw files a recording is written to first.
//!
//! While recording, every source's data is appended to the journal as chunks, in the order it
//! arrives, so data captured around the same time sits close together on disk. Each source's
//! chunks are in order; different sources' chunks interleave. A background thread reads the
//! chunks back and writes the final per-track files (FLAC).
//!
//! A journal file is a ring on disk, like the audio rings in memory: a FileHeader, then a data
//! area of `capacity` bytes that the writer fills and the compressor frees, wrapping around.
//! Chunks never straddle the end: a padding chunk fills the rest of the area and the next chunk
//! starts at its beginning. When the writer would overwrite what the compressor hasn't read,
//! it ends the file with a segment_end chunk and continues in a new file twice the size; the
//! compressor deletes the old file once it's past that chunk and recovery can't need it.
//!
//! The journal describes itself (tracks are announced by a track_start chunk) and every chunk
//! has a sequence number and a CRC, so the final files can be rebuilt from it alone after a
//! crash: a scan stops at the first chunk that fails its CRC or breaks the sequence, which is
//! where new data ends and the previous lap's stale data begins.
//!
//! All fields are little-endian.

pub const magic: u32 = std.mem.readInt(u32, "BBCH", .little);

/// Chunks start and end on this boundary, so the room left before the end of the data area is
/// always a whole number of chunk headers.
pub const chunk_align = 64;

/// A journal file's first bytes; the data area starts at `data_start`.
pub const FileHeader = extern struct {
    magic: u32 = file_magic,
    version: u32 = 1,
    /// Its place in the recording's journal files: journal-000000.bbj is 0.
    index: u32,
    reserved: u32 = 0,
    /// Bytes in the data area: a multiple of chunk_align.
    capacity: u64,
    /// The journal_seq of the file's first chunk.
    first_seq: u64,
    /// When the recording started, QPC in 100ns units: for recording.json, also after a crash.
    start_qpc: u64,
    /// And in local time: year, month, day of week, day, hour, minute, second, milliseconds
    /// (Windows' SYSTEMTIME).
    started: [8]u16,

    pub const data_start = 4096;
};

pub const file_magic: u32 = std.mem.readInt(u32, "BBJF", .little);

pub const Kind = enum(u8) {
    /// A track's first chunk. Payload: TrackStart then its strings.
    track_start = 1,
    /// Audio, as the capture delivered it: the payload is Records, each followed by its
    /// samples. The header's frames, first_frame and capture_qpc sum up the records.
    audio = 2,
    /// The track ends: nothing more comes for it. No payload.
    track_end = 3,
    /// The recording ends: the journal's last chunk. No payload.
    recording_end = 4,
    /// Fills the rest of the data area: the next chunk is at its start. `len` covers the rest;
    /// the bytes there aren't part of the journal (and aren't in the CRC).
    padding = 5,
    /// The file's last chunk: the journal continues in the next file. No payload.
    segment_end = 6,
    _,
};

pub const Flags = packed struct(u8) {
    _: u8 = 0,
};

/// One packet of audio in an audio chunk, followed by `len` bytes of samples in TrackStart's
/// format (none when silent).
pub const Record = extern struct {
    frames: u32,
    flags: RecordFlags,
    /// Bytes of samples after this record.
    len: u32,
    reserved: u32 = 0,
    /// The device's position (in frames) of the first frame. Positions that never came are
    /// gaps, filled with silence in the final file.
    first_frame: u64,
    /// When the first frame was captured, QPC in 100ns units, as WASAPI reports it.
    capture_qpc: u64,

    comptime {
        std.debug.assert(@sizeOf(Record) == 32);
    }
};

pub const RecordFlags = packed struct(u32) {
    /// Digital silence: `frames` of zeros, not stored.
    silent: bool = false,
    /// Windows said capture_qpc is wrong (AUDCLNT_BUFFERFLAGS_TIMESTAMP_ERROR).
    timestamp_error: bool = false,
    /// Windows said audio was lost before this (AUDCLNT_BUFFERFLAGS_DATA_DISCONTINUITY).
    /// first_frame says how much.
    discontinuity: bool = false,
    _: u29 = 0,
};

pub const Header = extern struct {
    magic: u32 = magic,
    /// CRC-32 of the rest of the header and the payload.
    crc: u32 = 0,
    /// Payload bytes.
    len: u32,
    /// The source's id. 0 for recording_end.
    track: u32,
    /// Counts each track's chunks from 0, so a missing or repeated chunk shows.
    seq: u32,
    kind: Kind,
    flags: Flags = .{},
    reserved0: u16 = 0,
    /// audio: how many frames, in all its records.
    frames: u32 = 0,
    reserved1: u32 = 0,
    /// audio: the first record's first_frame.
    first_frame: u64 = 0,
    /// audio: the first record's capture_qpc.
    capture_qpc: u64 = 0,
    /// When the writer wrote the chunk, QPC in 100ns units: how far behind capture it was.
    write_qpc: u64 = 0,
    /// Counts every chunk in the journal, across its files, from 0.
    journal_seq: u64 = 0,

    comptime {
        std.debug.assert(@sizeOf(Header) == 64);
    }

    /// Bytes the chunk takes in the data area, its alignment padding included.
    pub fn size(h: *const Header) u64 {
        return std.mem.alignForward(u64, @sizeOf(Header) + h.len, chunk_align);
    }

    /// The CRC for this header and a payload in one or more pieces.
    pub fn computeCrc(h: *const Header, payload: []const []const u8) u32 {
        var c: std.hash.Crc32 = .init();
        c.update(std.mem.asBytes(h)[8..]);
        for (payload) |piece| c.update(piece);
        return c.final();
    }
};

/// A track_start chunk's payload starts with this, then `device_name_len` bytes of the
/// device's name and `file_name_len` bytes of the final file's name (UTF-8).
pub const TrackStart = extern struct {
    /// The samples, as captured.
    sample: SampleType,
    channels: u8,
    block_align: u16,
    rate: u32,
    /// The device's own format, if known (Sound settings' "Default Format").
    device_format_known: u8,
    device_sample: u8,
    device_bits: u16,
    device_rate: u32,
    device_channels: u16,
    /// Windows' audio effects were bypassed.
    raw: u8,
    reserved: u8 = 0,
    device_name_len: u16,
    file_name_len: u16,

    comptime {
        std.debug.assert(@sizeOf(TrackStart) == 24);
    }
};

pub const SampleType = enum(u8) { f32 = 1, i16 = 2, i24 = 3, i32 = 4, _ };

const std = @import("std");
