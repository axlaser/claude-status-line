//! The transcript scan: message count, token totals, and the idle/working
//! verdict, from one pass over the session's JSONL file.
//!
//! Ported from the `# 5b/5c` awk program in `macos/statusline.sh`, which the
//! PowerShell script mirrors line for line. Three properties of that program
//! are load-bearing and easy to lose in a port:
//!
//! - **It is byte-oriented, not text-oriented.** The awk runs under `LC_ALL=C`
//!   so `length()` counts bytes. An earlier version ran under a UTF-8 locale
//!   and gawk's greedy token extraction then silently zeroed the token counts
//!   of any line carrying a character outside the BMP — see
//!   `docs/solutions/logic-errors/gawk-utf8-locale-zeroes-astral-plane-extraction.md`.
//!   Everything here works on `&[u8]` for the same reason: no decoding step
//!   means no decoding bug, and a transcript is not guaranteed to be valid
//!   UTF-8 anyway.
//! - **Synthetic entries do not vote.** Slash commands, meta entries, and tool
//!   results are filtered out of the idle/working decision. Without that filter
//!   the detector sticks on "working" after any slash command.
//! - **A line is consumed only if it fits inside the sampled size.** The size
//!   is read once, before the scan; a line extending past it is a torn or
//!   racing tail, so it is skipped and so is everything after it. That keeps
//!   the consumed count covering an unbroken prefix, and it is why a transcript
//!   being appended to while it is read cannot miscount.

/// What one pass over a transcript yields.
#[derive(Debug, Default, Clone, PartialEq, Eq)]
pub struct Scan {
    /// Real user messages — synthetic entries excluded.
    pub messages: u64,
    pub input_tokens: u64,
    pub cache_write_tokens: u64,
    pub cache_read_tokens: u64,
    pub output_tokens: u64,
    /// The last non-synthetic entry's verdict, or the caller's starting value
    /// when the scanned span contains no entry that votes.
    pub idle: bool,
    /// Bytes of the unbroken prefix actually consumed. Always a record
    /// boundary, so it is a safe place for a later scan to resume from.
    pub consumed: u64,
}

/// The record format's version tag.
///
/// `v3` rather than `v1`: the scripts' 16-field `v2` record lives at a
/// different path and carries fields this one deliberately drops, and a shared
/// version number across two incompatible formats is how a stale record gets
/// read as a fresh one. Bump this whenever the field list changes.
pub const RECORD_VERSION: &str = "v4";

/// The per-session token record, the only part of the scripts' transcript
/// cache that survives the port.
///
/// It is a render input, not a performance cache. The `(+N)` beside each token
/// bucket is this tick's total minus the previous tick's, so without a stored
/// previous there is no delta to render; and while the transcript is unchanged
/// the stored deltas are re-displayed rather than recomputed to zero, which is
/// why the mtime and size are part of the record and not just its key.
///
/// What the scripts stored and this does not: the incremental parser's byte
/// offset and head checksum, deleted with the parser itself, and
/// `working_start_out_tokens`, which both scripts compute, store, and read back
/// solely to compute again — no platform renders it.
#[derive(Debug, Default, Clone, PartialEq, Eq)]
pub struct TokenRecord {
    pub mtime: i64,
    pub size: u64,
    /// Carried so an unchanged transcript needs no scan at all. Everything the
    /// tokens row and the model row render is then reconstructable from this
    /// record, which is what makes the skip in `cmd::statusline` possible.
    pub messages: u64,
    pub idle: bool,
    pub input_tokens: u64,
    pub cache_write_tokens: u64,
    pub cache_read_tokens: u64,
    pub output_tokens: u64,
    pub delta_in: u64,
    pub delta_cache_write: u64,
    pub delta_cache_read: u64,
    pub delta_out: u64,
}

impl TokenRecord {
    /// Serializes to the scripts' pipe-separated shape, version first.
    pub fn to_line(&self) -> String {
        format!(
            "{}|{}|{}|{}|{}|{}|{}|{}|{}|{}|{}|{}|{}",
            RECORD_VERSION,
            self.mtime,
            self.size,
            self.messages,
            self.idle,
            self.input_tokens,
            self.cache_write_tokens,
            self.cache_read_tokens,
            self.output_tokens,
            self.delta_in,
            self.delta_cache_write,
            self.delta_cache_read,
            self.delta_out
        )
    }

    /// Parses a stored record, or `None` for anything that is not exactly one.
    ///
    /// Every rejection lands in the same place as an absent record: deltas are
    /// computed against zero, which renders the totals as one large increment
    /// once and then settles. That is the scripts' behaviour on a failed
    /// validation too, and it is why this can afford to be strict.
    ///
    /// The scripts bound each digit run to 18 characters so a planted value
    /// could not wrap 64-bit shell arithmetic. Parsing into `u64` is the
    /// stronger form of the same guard: an over-long run fails to parse instead
    /// of wrapping.
    pub fn parse(raw: &str) -> Option<Self> {
        let fields: Vec<&str> = raw.trim_end_matches(['\r', '\n']).split('|').collect();
        if fields.len() != 13 || fields[0] != RECORD_VERSION {
            return None;
        }
        Some(Self {
            mtime: fields[1].parse().ok()?,
            size: fields[2].parse().ok()?,
            messages: fields[3].parse().ok()?,
            // Strict: anything that is not exactly `true` or `false` rejects
            // the whole record rather than defaulting, because this field now
            // decides whether the transcript is read at all.
            idle: match fields[4] {
                "true" => true,
                "false" => false,
                _ => return None,
            },
            input_tokens: fields[5].parse().ok()?,
            cache_write_tokens: fields[6].parse().ok()?,
            cache_read_tokens: fields[7].parse().ok()?,
            output_tokens: fields[8].parse().ok()?,
            delta_in: fields[9].parse().ok()?,
            delta_cache_write: fields[10].parse().ok()?,
            delta_cache_read: fields[11].parse().ok()?,
            delta_out: fields[12].parse().ok()?,
        })
    }

    /// Combines a fresh scan with the previous record into what renders now.
    ///
    /// Two cases:
    ///
    /// - **The transcript is unchanged** (same mtime and size). The stored
    ///   deltas are re-displayed rather than recomputed to zero, which is what
    ///   the scripts do on a cache hit and is why an idle status line keeps
    ///   showing the last turn's increments.
    /// - **It changed.** Deltas are this scan's totals minus the stored ones,
    ///   saturating at zero — a rotated or replaced transcript can shrink, and
    ///   both scripts clamp rather than render a negative increment.
    ///
    /// The totals always come from this tick's scan, never from the record,
    /// even in the unchanged case. That is what lets the head checksum go: the
    /// scripts needed it to notice a same-size rewrite, because a cache hit
    /// there would have skipped the scan and rendered stale totals forever.
    /// This port scans every tick, so a same-size rewrite is simply seen.
    ///
    /// The second return value is whether the record needs storing — false
    /// whenever nothing about it changed, which keeps idle ticks off the disk.
    pub fn fold(prev: Option<&TokenRecord>, scan: &Scan, mtime: i64, size: u64) -> (Self, bool) {
        let unchanged = prev.is_some_and(|p| p.mtime == mtime && p.size == size);
        let (prev_in, prev_cw, prev_cr, prev_out) = match prev {
            Some(p) => (
                p.input_tokens,
                p.cache_write_tokens,
                p.cache_read_tokens,
                p.output_tokens,
            ),
            None => (0, 0, 0, 0),
        };
        let record = Self {
            mtime,
            size,
            messages: scan.messages,
            idle: scan.idle,
            input_tokens: scan.input_tokens,
            cache_write_tokens: scan.cache_write_tokens,
            cache_read_tokens: scan.cache_read_tokens,
            output_tokens: scan.output_tokens,
            delta_in: match prev {
                Some(p) if unchanged => p.delta_in,
                _ => scan.input_tokens.saturating_sub(prev_in),
            },
            delta_cache_write: match prev {
                Some(p) if unchanged => p.delta_cache_write,
                _ => scan.cache_write_tokens.saturating_sub(prev_cw),
            },
            delta_cache_read: match prev {
                Some(p) if unchanged => p.delta_cache_read,
                _ => scan.cache_read_tokens.saturating_sub(prev_cr),
            },
            delta_out: match prev {
                Some(p) if unchanged => p.delta_out,
                _ => scan.output_tokens.saturating_sub(prev_out),
            },
        };
        let write = prev != Some(&record);
        (record, write)
    }
}

/// Where this session's token record lives.
///
/// `None` for a session id that sanitizes to nothing, which would otherwise
/// produce one shared `statusline-tokens-.txt` that every such session would
/// read each other's deltas from.
pub fn record_path(temp: &std::path::Path, session_id: &str) -> Option<std::path::PathBuf> {
    let safe = crate::session::sanitize_session_id(session_id);
    if safe.is_empty() {
        return None;
    }
    Some(temp.join(format!("statusline-tokens-{safe}.txt")))
}

/// Scans `bytes`, counting only records that fit within `sampled_size`.
///
/// `sampled_size` is the file size observed before the read. `None` disables
/// the gate, matching the script's `total < 0` path for the case where the size
/// could not be determined — everything present is then consumed.
///
/// `init_idle` is the verdict that holds if nothing in this span votes.
pub fn scan(bytes: &[u8], sampled_size: Option<u64>, init_idle: bool) -> Scan {
    let mut out = Scan {
        idle: init_idle,
        ..Default::default()
    };

    // A trailing newline terminates the final record rather than starting an
    // empty one, which is how awk reads it. Without this the empty tail would
    // consume a phantom byte in the ungated case.
    let body = match bytes.last() {
        Some(b'\n') => &bytes[..bytes.len() - 1],
        _ => bytes,
    };

    let mut stop = false;
    for line in body.split(|b| *b == b'\n') {
        // The record includes its newline, present or not: a final line lacking
        // one does not fit the sampled size and is therefore left for the next
        // scan rather than counted half-written.
        let rec = line.len() as u64 + 1;
        if let Some(total) = sampled_size {
            if stop || out.consumed + rec > total {
                stop = true;
                continue;
            }
        }
        out.consumed += rec;

        if is_typed(line, b"\"user\"")
            && !contains(line, b"\"toolUseResult\"")
            && !keyed_literal(line, b"\"isMeta\"", b"true")
            && !contains(line, b"<command-name>")
            && !contains(line, b"<local-command-stdout>")
        {
            out.messages += 1;
        }

        if is_typed(line, b"\"assistant\"") {
            out.input_tokens = out
                .input_tokens
                .saturating_add(token_value(line, b"\"input_tokens\""));
            out.cache_write_tokens = out
                .cache_write_tokens
                .saturating_add(token_value(line, b"\"cache_creation_input_tokens\""));
            out.cache_read_tokens = out
                .cache_read_tokens
                .saturating_add(token_value(line, b"\"cache_read_input_tokens\""));
            out.output_tokens = out
                .output_tokens
                .saturating_add(token_value(line, b"\"output_tokens\""));
        }

        // The idle vote uses its own filter list, which is deliberately not the
        // message filter above: `"isMeta"` is excluded whatever its value, and
        // `toolUseResult` and `<local-command-` are matched unquoted and
        // unterminated. The last surviving entry wins, which is the forward
        // equivalent of the reverse scan this replaced.
        if !contains(line, b"\"isMeta\"")
            && !contains(line, b"<command-name>")
            && !contains(line, b"<local-command-")
            && !contains(line, b"toolUseResult")
        {
            if ordered(line, b"\"type\"", b"\"assistant\"") {
                out.idle = ordered(line, b"\"stop_reason\"", b"\"end_turn\"");
            } else if ordered(line, b"\"type\"", b"\"user\"") {
                out.idle = contains(line, b"Request interrupted by user");
            }
        }
    }

    out
}

/// `/"type"[[:space:]]*:[[:space:]]*<literal>/`, used for the counting rules.
///
/// Distinct from [`ordered`], which the voting rule uses: that one requires no
/// colon and so also matches a line where the words merely appear in order.
/// The scripts use both, at different sites, and reconciling them would change
/// which entries count.
fn is_typed(line: &[u8], literal: &[u8]) -> bool {
    keyed_literal(line, b"\"type\"", literal)
}

/// `/<key>[[:space:]]*:[[:space:]]*<literal>/` anywhere in the line.
fn keyed_literal(line: &[u8], key: &[u8], literal: &[u8]) -> bool {
    let mut from = 0;
    while let Some(i) = find_from(line, key, from) {
        let p = skip_ws(line, i + key.len());
        if line.get(p) == Some(&b':') {
            let v = skip_ws(line, p + 1);
            if line[v..].starts_with(literal) {
                return true;
            }
        }
        from = i + 1;
    }
    false
}

/// The digits following the **last** `<key>` occurrence that is followed by a
/// colon, or 0.
///
/// A faithful port of the awk `tok()` helper, including two behaviours that
/// look like accidents and are not:
///
/// - An occurrence *not* followed by a colon leaves the previous value standing
///   rather than clearing it, so `"input_tokens"` appearing inside a quoted
///   string cannot wipe a real reading that preceded it.
/// - An occurrence that is followed by a colon but not by digits — `null`, or a
///   float — clears the value to 0. The last colon-bearing occurrence wins
///   whatever it holds.
///
/// Values are read as bytes, never decoded, which is the whole point: the
/// incident this replaces came from a UTF-8-aware extractor mis-slicing lines
/// carrying astral-plane characters.
fn token_value(line: &[u8], key: &[u8]) -> u64 {
    let mut last: Option<u64> = None;
    let mut from = 0;
    while let Some(i) = find_from(line, key, from) {
        let p = skip_ws(line, i + key.len());
        if line.get(p) == Some(&b':') {
            let start = skip_ws(line, p + 1);
            let mut end = start;
            while end < line.len() && line[end].is_ascii_digit() {
                end += 1;
            }
            // Non-digits, or a run too long for u64, both read as 0 — awk would
            // hand bash a float in scientific notation and bash's `^[0-9]+$`
            // guard would reject it.
            last = Some(
                std::str::from_utf8(&line[start..end])
                    .ok()
                    .and_then(|s| s.parse().ok())
                    .unwrap_or(0),
            );
        }
        from = i + 1;
    }
    last.unwrap_or(0)
}

/// `/<first>.*<second>/`: both present, the second starting at or after the end
/// of the first. Testing only the first `first` is sufficient — any later one
/// that satisfies the pattern implies the first does too.
fn ordered(line: &[u8], first: &[u8], second: &[u8]) -> bool {
    match find_from(line, first, 0) {
        Some(i) => find_from(line, second, i + first.len()).is_some(),
        None => false,
    }
}

fn contains(line: &[u8], needle: &[u8]) -> bool {
    find_from(line, needle, 0).is_some()
}

/// Substring search, first-byte-scan then compare.
///
/// The obvious `windows(n).position(..)` is a byte-at-a-time comparison at
/// every offset; this form lets the first-byte scan vectorize and only runs a
/// full compare where that byte hits. On a multi-megabyte transcript the
/// difference is the difference between a scan you notice and one you do not,
/// and it is the reason no search crate is needed.
fn find_from(hay: &[u8], needle: &[u8], from: usize) -> Option<usize> {
    let (first, rest) = needle.split_first()?;
    if from > hay.len() {
        return None;
    }
    let mut i = from;
    while let Some(off) = hay[i..].iter().position(|b| b == first) {
        let start = i + off;
        match hay.get(start + 1..) {
            Some(tail) if tail.starts_with(rest) => return Some(start),
            _ => i = start + 1,
        }
    }
    None
}

/// The awk `wskip` character class, which is wider than ASCII space and tab.
fn skip_ws(line: &[u8], mut p: usize) -> usize {
    while p < line.len() && matches!(line[p], b' ' | b'\t' | b'\n' | b'\r' | 0x0c | 0x0b) {
        p += 1;
    }
    p
}
