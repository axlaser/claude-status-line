//! The stdin payload: one tolerant reader over the JSON contract Claude Code
//! pipes in on every refresh.
//!
//! The whole module exists to be *un*typed (KTD14). A `#[derive(Deserialize)]`
//! model would reject the entire document the day Claude Code changes one
//! field's type, and under the silent-degradation contract that renders as a
//! blank status line with no explanation. The scripts never had that failure
//! mode: they pull each field out on its own, and a field that is missing or
//! unusable costs exactly the row it feeds. This reproduces that — parse once
//! to a generic value, then read each documented field through a helper that
//! answers "absent" for anything it cannot use.
//!
//! The field list came from the JSON-extraction block in `macos/statusline.sh`,
//! and the accessors below are named after the `J_*` variables it assigned so
//! the two can be read side by side — see `eb56345` for the script's final
//! state. The accessors here are the contract now; `CLAUDE.md` documents the
//! fields.
//!
//! Nothing here scrubs (R24). [`sanitize_display`] lives in this module because
//! it is the counterpart of that same block, but it is applied at
//! the render sink, not at ingest: scrubbing on the way in would silently
//! corrupt values that never reach the screen, notably `transcript_path`, which
//! has to survive byte-intact to open a file.

use serde_json::Value;

/// A parsed stdin payload.
///
/// Construction is fallible in exactly the two cases the scripts treat as fatal
/// — see [`Payload::parse`] — so holding one means the render path has a JSON
/// object to read, and every field read after that degrades instead of failing.
pub struct Payload {
    root: Value,
}

impl Payload {
    /// Parses the raw stdin bytes, or `None` for input the scripts render
    /// `[statusline: bad JSON]` for.
    ///
    /// Two rejections, both deliberate:
    ///
    /// - **Unparseable input**, including empty stdin. Empty is not a special
    ///   case that renders a blank line; both scripts reach their bad-JSON
    ///   branch on it, because jq emits no rows and `ConvertFrom-Json` has
    ///   nothing to convert.
    /// - **Valid JSON that is not an object** — an array, a bare string, a
    ///   number. This mirrors the bash filter's explicit `if type != "object"
    ///   then error` guard. Windows has no equivalent check and would render a
    ///   defaults-only line instead; the bash behaviour is the one that was
    ///   written on purpose, so it is the one ported. Recorded as a resolved
    ///   divergence.
    pub fn parse(raw: &str) -> Option<Self> {
        match serde_json::from_str::<Value>(raw) {
            Ok(root) if root.is_object() => Some(Self { root }),
            _ => None,
        }
    }

    /// Walks a dotted path without ever panicking on a missing or non-object
    /// link. `.get()` on a non-object value is `None`, so a payload where
    /// `context_window` is a string simply has no `used_percentage`.
    fn at(&self, path: &[&str]) -> Option<&Value> {
        let mut cur = &self.root;
        for key in path {
            cur = cur.get(key)?;
        }
        Some(cur)
    }

    /// A string field, or `""` when it is absent, null, or any non-string type.
    ///
    /// Empty and absent deliberately collapse to the same value: every
    /// consuming site in the scripts tests `[[ -n ... ]]`, so a field present
    /// as `""` already behaved exactly as a missing one.
    ///
    /// Wrong-typed values read as absent, which is a divergence from both
    /// scripts and the point of AE6. jq renders an object to its compact JSON
    /// text and PowerShell renders it `@{a=1}`, so a payload with
    /// `model.display_name: {"a": 1}` puts `{"a":1}` in the model row on
    /// macOS and `@{a=1}` on Windows. There is no byte-exact behaviour to
    /// preserve between two platforms that already disagree, and neither
    /// output is defensible on screen, so the row falls back instead.
    pub fn text(&self, path: &[&str]) -> &str {
        self.at(path).and_then(Value::as_str).unwrap_or("")
    }

    /// A numeric field, accepting a JSON number or a numeric string.
    ///
    /// The string arm is not leniency for its own sake: jq hands bash every
    /// field as text and bash re-parses it, so a payload quoting
    /// `"used_percentage": "42.5"` renders identically to the unquoted form
    /// today. Dropping the string arm would silently blank rows that currently
    /// render.
    ///
    /// A JSON `false` reads as absent, matching jq's `//` operator, which
    /// returns its right-hand side for `false` as well as `null`. That is the
    /// same operator whose behaviour meant `notify`'s mute flags never worked
    /// (U7) — here it is being reproduced rather than fixed, because for a
    /// numeric field "false" has no sensible reading.
    pub fn number(&self, path: &[&str]) -> Option<f64> {
        match self.at(path)? {
            Value::Number(n) => n.as_f64(),
            Value::String(s) => s.parse().ok(),
            _ => None,
        }
    }

    /// A non-negative integer field, accepting a JSON number or a digits-only
    /// string.
    ///
    /// The string arm is exactly bash's `^[0-9]+$` guard: no sign, no decimal
    /// point, no leading blanks. An integral float (`200000.0`) is accepted
    /// because jq 1.6 prints it as `200000` and bash's guard then passes it;
    /// under jq 1.7's literal preservation the same payload would print
    /// `200000.0` and fail the guard, so the platforms cannot agree on that
    /// input anyway and the tolerant reading is the useful one.
    pub fn uint(&self, path: &[&str]) -> Option<u64> {
        match self.at(path)? {
            Value::Number(n) => n.as_u64().or_else(|| {
                let f = n.as_f64()?;
                (f >= 0.0 && f.fract() == 0.0).then_some(f as u64)
            }),
            Value::String(s) if !s.is_empty() && s.bytes().all(|b| b.is_ascii_digit()) => {
                s.parse().ok()
            }
            _ => None,
        }
    }

    // -- The documented fields, in the order the parity block assigns them ---

    /// `J_SESSION_ID`. Names every per-session state file, so it reaches a
    /// filename and must go through [`crate::session::sanitize_session_id`]
    /// before it does.
    pub fn session_id(&self) -> &str {
        self.text(&["session_id"])
    }

    /// `J_CWD` falling back to `J_CWD_FALLBACK`: `workspace.current_dir`, then
    /// the top-level `cwd`.
    pub fn cwd(&self) -> &str {
        let primary = self.text(&["workspace", "current_dir"]);
        if primary.is_empty() {
            self.text(&["cwd"])
        } else {
            primary
        }
    }

    /// `J_GIT_CWD`. The parity block extracts `workspace.current_dir` a second
    /// time for the git row and does **not** give it the `cwd` fallback, so the
    /// git segment and the path segment can resolve differently. Kept separate
    /// rather than aliased to [`Payload::cwd`] for that reason. U10 supplies
    /// the process working directory when this is empty.
    pub fn git_cwd(&self) -> &str {
        self.text(&["workspace", "current_dir"])
    }

    /// `J_MODEL_DISPLAY`.
    pub fn model_display_name(&self) -> &str {
        self.text(&["model", "display_name"])
    }

    /// `J_MODEL_ID`. Keys the learned model-to-window map.
    pub fn model_id(&self) -> &str {
        self.text(&["model", "id"])
    }

    /// `J_CTX_SIZE`.
    pub fn context_window_size(&self) -> Option<u64> {
        self.uint(&["context_window", "context_window_size"])
    }

    /// `J_USED_PCT`.
    pub fn used_percentage(&self) -> Option<f64> {
        self.number(&["context_window", "used_percentage"])
    }

    /// `J_TOTAL_INPUT_TOKENS`.
    pub fn total_input_tokens(&self) -> Option<u64> {
        self.uint(&["context_window", "total_input_tokens"])
    }

    /// `J_EFFORT_LEVEL`. A display field, so it is scrubbed at render (AE13).
    pub fn effort_level(&self) -> &str {
        self.text(&["effort", "level"])
    }

    /// `J_TOTAL_COST` falling back to the legacy top-level `total_cost_usd`.
    pub fn total_cost_usd(&self) -> Option<f64> {
        self.number(&["cost", "total_cost_usd"])
            .or_else(|| self.number(&["total_cost_usd"]))
    }

    /// `J_DURATION_MS` and its two legacy spellings, in the scripts' order:
    /// `cost.total_duration_ms`, then `total_duration_ms`, then `duration_ms`.
    ///
    /// Returned as a float because bash strips the fractional part textually
    /// (`${duration_ms%.*}`) before dividing, so a fractional value has always
    /// been accepted here.
    pub fn duration_ms(&self) -> Option<f64> {
        self.number(&["cost", "total_duration_ms"])
            .or_else(|| self.number(&["total_duration_ms"]))
            .or_else(|| self.number(&["duration_ms"]))
    }

    /// `J_TRANSCRIPT_PATH`. Opened as a file, never rendered, and therefore
    /// never scrubbed.
    pub fn transcript_path(&self) -> &str {
        self.text(&["transcript_path"])
    }

    /// `J_RATE_5H_PCT`.
    pub fn rate_five_hour_percentage(&self) -> Option<f64> {
        self.number(&["rate_limits", "five_hour", "used_percentage"])
    }

    /// `J_RATE_5H_RESETS`.
    pub fn rate_five_hour_resets_at(&self) -> &str {
        self.text(&["rate_limits", "five_hour", "resets_at"])
    }

    /// `J_RATE_7D_PCT`.
    pub fn rate_seven_day_percentage(&self) -> Option<f64> {
        self.number(&["rate_limits", "seven_day", "used_percentage"])
    }

    /// `J_RATE_7D_RESETS`.
    pub fn rate_seven_day_resets_at(&self) -> &str {
        self.text(&["rate_limits", "seven_day", "resets_at"])
    }

    /// `J_AGENT_NAME`. Present only in a subagent's own session; its emptiness
    /// is what selects the main-session layout.
    pub fn agent_name(&self) -> &str {
        self.text(&["agent", "name"])
    }

    /// `J_AGENT_IN`, defaulting to 0 rather than absent — both scripts pin it
    /// to zero at extraction (`${agent_in:-0}` and an explicit `$null` test)
    /// because it renders unconditionally inside the agent row.
    pub fn agent_input_tokens(&self) -> u64 {
        self.uint(&["context_window", "current_usage", "input_tokens"])
            .unwrap_or(0)
    }

    /// `J_AGENT_OUT`. Zero-defaulted for the same reason as
    /// [`Payload::agent_input_tokens`].
    pub fn agent_output_tokens(&self) -> u64 {
        self.uint(&["context_window", "current_usage", "output_tokens"])
            .unwrap_or(0)
    }
}

/// The render sink's scrub for untrusted display fields (R24, AE13).
///
/// Ports the scripts' `sa_sanitize_title`: control
/// bytes and DEL become spaces, `|` becomes a space so a value cannot forge a
/// column separator, and the result is trimmed of spaces so a field that was
/// nothing but control bytes reads as empty rather than as whitespace.
///
/// Applied to the git branch, subagent model and title, agent name, effort, and
/// model display name — every field whose bytes originate outside this tool.
/// The trim is space-only, matching bash's `[! ]` trim, which is not a
/// distinction that survives the replacement above but is kept literal so the
/// two read as the same function.
///
/// One byte diverges: bash's range starts at `\x01` because a bash string
/// cannot hold a NUL in the first place, while a JSON string can carry one.
/// It is scrubbed here rather than passed through to a terminal.
pub fn sanitize_display(raw: &str) -> String {
    let replaced: String = raw
        .chars()
        .map(|c| {
            if c == '|' || (c as u32) < 0x20 || c as u32 == 0x7f {
                ' '
            } else {
                c
            }
        })
        .collect();
    replaced.trim_matches(' ').to_string()
}
