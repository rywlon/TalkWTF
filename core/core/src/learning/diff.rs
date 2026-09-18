//! Detect a small, localized edit between what we pasted and what the field now
//! contains. Pure logic — no platform APIs — so the whole thing is unit-tested.
//!
//! The shape of a "correction" is: the pasted text is still *mostly* there, and
//! one contiguous region in the middle differs. So instead of a general diff we
//! compute the common prefix and the common suffix and treat what is left in
//! between as the candidate. Two separate edit regions merge into one big span
//! and get rejected by the span limit — which is what we want (a rewrite is not
//! a correction).

/// What we would learn from an edit.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct EditCandidate {
    /// The text as it was (what the recognizer produced).
    pub pattern: String,
    /// The text as the user corrected it to.
    pub replacement: String,
}

/// Leading characters of the pasted text used to locate it inside the field.
/// Tried longest-first, so an edit near the start still anchors.
const ANCHOR_LENGTHS: [usize; 3] = [8, 4, 2];
/// Characters past the pasted length that still count as "our" window — the user
/// may have kept typing after the paste.
const WINDOW_SLACK: usize = 20;
/// A correction must not span more than this many characters.
const MAX_SPAN_CHARS: usize = 40;
/// Longest pasted text we bother analyzing. Guards the scan against a
/// pathological dictation.
const MAX_PASTED_CHARS: usize = 600;
/// Most rules one dictation may teach. A message with more separate corrections
/// than this is unusual, and each extra rule costs prompt space.
const MAX_CANDIDATES: usize = 5;
/// Unchanged characters required on both sides together. Scaled by length so a
/// wholesale rewrite cannot pass, with an absolute floor for short dictations.
const MIN_UNCHANGED_CHARS: usize = 4;
/// Unchanged characters required between two separate corrections. Below this the
/// LCS is just splitting one term, so the hunks are merged back together.
const MIN_HUNK_GAP: usize = 4;
/// Word ceiling for space-separated scripts: a correction is a phrase, not a
/// sentence.
const MAX_ASCII_SPAN_WORDS: usize = 6;
/// Length floors for the replaced / replacement spans.
const MIN_ASCII_SPAN_CHARS: usize = 2;
const MIN_CJK_SPAN_CHARS: usize = 2;
/// Similarity floors for the "this looks like a mishearing, not a change of mind"
/// gate. ASCII terms must be close under normalized edit distance; CJK terms must
/// share enough characters. A dictionary word biases future recognition, so a
/// semantic edit ("早" -> "晚") must never be learned.
const LEARN_SIMILARITY_THRESHOLD: f64 = 0.6;
const LEARN_CJK_OVERLAP: f64 = 0.5;

fn is_cjk(character: char) -> bool {
    let code = character as u32;
    // CJK ideographs (incl. extensions A), compatibility ideographs, kana.
    (0x3040..=0x30FF).contains(&code)
        || (0x3400..=0x4DBF).contains(&code)
        || (0x4E00..=0x9FFF).contains(&code)
        || (0xF900..=0xFAFF).contains(&code)
}

fn has_cjk(text: &str) -> bool {
    text.chars().any(is_cjk)
}

/// Whether a correction looks like the recognizer misheard the user, rather than
/// the user changing their mind. Cross-script pairs (the recognizer wrote Chinese
/// for an English term, or vice versa) are treated as mishearings: local code
/// cannot score their pronunciation, and they are rarely a deliberate rewrite.
pub fn is_likely_mishearing(pattern: &str, replacement: &str) -> bool {
    // Identical text (after the same normalization the distance uses) is not an
    // edit at all. `detect_edits` never produces one, but the gate stands alone.
    if match_key(pattern) == match_key(replacement) {
        return false;
    }

    let old_has_cjk = has_cjk(pattern);
    let new_has_cjk = has_cjk(replacement);

    if old_has_cjk != new_has_cjk {
        return true;
    }

    if old_has_cjk {
        cjk_overlap(pattern, replacement) >= LEARN_CJK_OVERLAP
    } else {
        normalized_distance(pattern, replacement) <= LEARN_SIMILARITY_THRESHOLD
    }
}

/// Normalized Levenshtein distance over alphanumeric, lowercased text.
fn normalized_distance(left: &str, right: &str) -> f64 {
    let left = match_key(left);
    let right = match_key(right);
    let max = left.chars().count().max(right.chars().count());
    if max == 0 {
        return 1.0;
    }
    strsim::levenshtein(&left, &right) as f64 / max as f64
}

fn match_key(text: &str) -> String {
    text.chars()
        .filter(|character| character.is_alphanumeric())
        .flat_map(|character| character.to_lowercase())
        .collect()
}

/// Shared-character ratio (multiset intersection over the longer side).
fn cjk_overlap(left: &str, right: &str) -> f64 {
    let mut remaining: Vec<char> = right.chars().collect();
    let mut shared = 0usize;
    for character in left.chars() {
        if let Some(index) = remaining
            .iter()
            .position(|candidate| *candidate == character)
        {
            remaining.remove(index);
            shared += 1;
        }
    }
    let max = left.chars().count().max(right.chars().count());
    if max == 0 {
        return 0.0;
    }
    shared as f64 / max as f64
}

/// Characters that separate one term from the next. CJK counts as a boundary
/// because it has no spaces: otherwise expanding a span would swallow the whole
/// sentence.
fn is_token_boundary(character: char) -> bool {
    character.is_whitespace()
        || is_cjk(character)
        || character.is_ascii_punctuation()
        || matches!(
            character,
            '，' | '。'
                | '、'
                | '？'
                | '！'
                | '：'
                | '；'
                | '（'
                | '）'
                | '「'
                | '」'
                | '“'
                | '”'
                | '‘'
                | '’'
                | '…'
                | '—'
                | '·'
        )
}

/// Widen a span to its surrounding tokens.
///
/// The prefix/suffix scan can leave a single character when the old and new text
/// share most of it — "C3XO" vs "Cica Exo" share the C and the XO, leaving just
/// "3", which is both a useless rule and too short to pass validation. Widening
/// to token boundaries recovers the term the user actually replaced.
fn expand_to_token_bounds(chars: &[char], start: usize, end: usize) -> (usize, usize) {
    let mut start = start;
    while start > 0 && !is_token_boundary(chars[start - 1]) {
        start -= 1;
    }

    let mut end = end;
    while end < chars.len() && !is_token_boundary(chars[end]) {
        end += 1;
    }

    (start, end)
}

/// A span that is exactly one CJK character.
fn is_single_cjk(span: &[char]) -> bool {
    span.len() == 1 && is_cjk(span[0])
}

fn span_length_ok(span: &str) -> bool {
    let length = span.chars().count();
    if length == 0 {
        return false;
    }
    if has_cjk(span) {
        length >= MIN_CJK_SPAN_CHARS
    } else {
        length >= MIN_ASCII_SPAN_CHARS
    }
}

/// A span made only of spaces is not a correction.
fn span_has_content(span: &str) -> bool {
    span.chars().any(|character| !character.is_whitespace())
}

fn word_count(span: &str) -> usize {
    span.split_whitespace().count()
}

fn spans_are_plausible(old_span: &str, new_span: &str) -> bool {
    // Token-boundary expansion can leave the neighbouring space attached
    // (" Cica Exo"); a term never starts or ends with whitespace.
    let old_span = old_span.trim();
    let new_span = new_span.trim();
    if old_span.is_empty() || new_span.is_empty() {
        return false;
    }
    // What is learned is a term. A phrase that mixes scripts, or that runs to
    // several words, is the signature of a misaligned diff (the user rewrote more
    // than they corrected), not of a misheard word — learning it pollutes the
    // dictionary and the polish prompt.
    if new_span.split_whitespace().count() > 2 {
        return false;
    }
    if has_cjk(new_span)
        && new_span
            .chars()
            .any(|character| character.is_ascii_alphabetic())
    {
        return false;
    }
    if !span_length_ok(old_span) || !span_length_ok(new_span) {
        return false;
    }
    if !span_has_content(old_span) || !span_has_content(new_span) {
        return false;
    }
    if old_span.chars().count() > MAX_SPAN_CHARS || new_span.chars().count() > MAX_SPAN_CHARS {
        return false;
    }
    // For space-separated scripts a correction is a few words at most. CJK has no
    // spaces, so the character limit is the only bound there.
    if !has_cjk(old_span) && word_count(old_span) > MAX_ASCII_SPAN_WORDS {
        return false;
    }
    true
}

/// Every position in `current` where `needle` occurs (case-insensitive).
fn find_all(haystack: &[char], needle: &[char]) -> Vec<usize> {
    if needle.is_empty() || needle.len() > haystack.len() {
        return Vec::new();
    }

    (0..=(haystack.len() - needle.len()))
        .filter(|start| {
            haystack[*start..*start + needle.len()]
                .iter()
                .flat_map(|character| character.to_lowercase())
                .eq(needle.iter().flat_map(|character| character.to_lowercase()))
        })
        .collect()
}

/// Common prefix and suffix lengths between the pasted text and a window,
/// case-insensitive. This is the "evidence that nothing changed" measure.
fn unchanged_span(pasted: &[char], window: &[char]) -> (usize, usize) {
    let comparable = pasted.len().min(window.len());

    let mut prefix = 0;
    while prefix < comparable && eq_ignore_case(pasted[prefix], window[prefix]) {
        prefix += 1;
    }

    let mut suffix = 0;
    while suffix < comparable - prefix
        && eq_ignore_case(
            pasted[pasted.len() - 1 - suffix],
            window[window.len() - 1 - suffix],
        )
    {
        suffix += 1;
    }

    (prefix, suffix)
}

/// Whether `needle` appears in `haystack` after normalizing both to lowercase
/// alphanumerics. Used to anchor a read to the text we just pasted.
pub fn contains_normalized(haystack: &str, needle: &str) -> bool {
    let needle = match_key(needle);
    if needle.is_empty() {
        return false;
    }
    match_key(haystack).contains(&needle)
}

/// Common prefix + suffix length between two texts, case-insensitive. The
/// "how much of the pasted text is still there" score.
pub fn relation_score(pasted: &str, current: &str) -> usize {
    let pasted: Vec<char> = pasted.chars().collect();
    let current: Vec<char> = current.chars().collect();
    let (prefix, suffix) = unchanged_span(&pasted, &current);
    prefix + suffix
}

/// The differing middle of `baseline` / `final_text`, widened by `radius`
/// characters on both sides. Used to send only the edit's neighbourhood to the
/// LLM: the context is bounded to ±`radius` characters around the edit, and a
/// field shorter than that is returned in full.
pub fn bounded_context(baseline: &str, final_text: &str, radius: usize) -> (String, String) {
    let old: Vec<char> = baseline.chars().collect();
    let new: Vec<char> = final_text.chars().collect();
    let (prefix, suffix) = unchanged_span(&old, &new);

    let start = prefix.saturating_sub(radius);
    let old_end = old
        .len()
        .saturating_sub(suffix)
        .saturating_add(radius)
        .min(old.len());
    let new_end = new
        .len()
        .saturating_sub(suffix)
        .saturating_add(radius)
        .min(new.len());

    let old_start = start.min(old_end);
    let new_start = start.min(new_end);
    (
        old[old_start..old_end].iter().collect(),
        new[new_start..new_end].iter().collect(),
    )
}

/// Whether `current` still looks like an edit of `pasted` — enough shared text on
/// both sides that they are the same field, not a different one. `unchanged_span`
/// is already case-insensitive.
pub fn is_related(pasted: &str, current: &str) -> bool {
    if pasted.is_empty() || current.is_empty() {
        return false;
    }
    let required = (pasted.chars().count() / 2).max(2);
    relation_score(pasted, current) >= required
}

/// Windows of `current` that might hold the pasted text, best alignment first.
///
/// Anchors on the pasted text's *suffix* first: a correction can begin at the very
/// start of the text ("那嗨桌飞手可以吗？" → "那Hydra Facial可以吗？"), which destroys
/// any prefix anchor. The exact start is then found by scoring alignments — a
/// correction can grow or shrink the text, so the start is not simply
/// `end - pasted.len()`.
fn window_candidates(pasted: &[char], current: &[char]) -> Vec<(usize, usize)> {
    let mut candidates: Vec<(usize, usize, usize)> = Vec::new(); // (score, start, end)

    for length in ANCHOR_LENGTHS {
        if length > pasted.len() {
            break;
        }
        let needle = &pasted[pasted.len() - length..];
        let positions = find_all(current, needle);
        if positions.is_empty() {
            continue;
        }

        for position in positions {
            let end = position + length;
            let window_end = (end + WINDOW_SLACK).min(current.len());
            let base = end.saturating_sub(pasted.len());
            let from = base.saturating_sub(WINDOW_SLACK);
            let to = (base + WINDOW_SLACK).min(end);

            for start in from..=to {
                let (prefix, suffix) = unchanged_span(pasted, &current[start..window_end]);
                candidates.push((prefix + suffix, start, window_end));
            }
        }
        break; // the longest suffix anchor is the most specific
    }

    // No suffix match: the correction is at the very end of the text, so anchor on
    // the start instead.
    if candidates.is_empty() {
        for length in ANCHOR_LENGTHS {
            if length > pasted.len() {
                break;
            }
            let needle = &pasted[..length];
            let positions = find_all(current, needle);
            if positions.is_empty() {
                continue;
            }

            for position in positions {
                let window_end = (position + pasted.len() + WINDOW_SLACK).min(current.len());
                let (prefix, suffix) = unchanged_span(pasted, &current[position..window_end]);
                candidates.push((prefix + suffix, position, window_end));
            }
            break;
        }
    }

    // Best alignment first: the window that preserves the most of the pasted text
    // is the one whose diff is a correction rather than a rewrite.
    candidates.sort_by(|left, right| right.0.cmp(&left.0));
    candidates.dedup_by_key(|(_, start, _)| *start);

    candidates
        .into_iter()
        .take(8)
        .map(|(_, start, end)| (start, end))
        .collect()
}

/// LCS over characters (case-insensitive), returned as unmatched runs
/// `(old_start, old_end, new_start, new_end)`.
///
/// Only used on short spans, so the quadratic table stays tiny.
fn lcs_hunks(old: &[char], new: &[char]) -> Vec<(usize, usize, usize, usize)> {
    let (n, m) = (old.len(), new.len());
    if n == 0 || m == 0 {
        return Vec::new();
    }

    let stride = m + 1;
    let mut table = vec![0u32; (n + 1) * stride];
    for i in (0..n).rev() {
        for j in (0..m).rev() {
            table[i * stride + j] = if eq_ignore_case(old[i], new[j]) {
                table[(i + 1) * stride + j + 1] + 1
            } else {
                table[(i + 1) * stride + j].max(table[i * stride + j + 1])
            };
        }
    }

    let mut hunks = Vec::new();
    let (mut i, mut j) = (0usize, 0usize);
    let mut open: Option<(usize, usize)> = None;

    while i < n && j < m {
        if eq_ignore_case(old[i], new[j]) {
            if let Some((start_i, start_j)) = open.take() {
                hunks.push((start_i, i, start_j, j));
            }
            i += 1;
            j += 1;
        } else if table[(i + 1) * stride + j] >= table[i * stride + j + 1] {
            open.get_or_insert((i, j));
            i += 1;
        } else {
            open.get_or_insert((i, j));
            j += 1;
        }
    }
    if let Some((start_i, start_j)) = open {
        hunks.push((start_i, n, start_j, m));
    }

    hunks
}

/// Turn one merged span into candidates.
///
/// A single correction keeps the whole span, which reads better as a rule
/// (" type place" -> "Typeless" rather than the minimal "ace" -> "ess"). When
/// unchanged text sits *inside* the span, the user corrected two separate things,
/// so the span is split — otherwise one rule would swallow everything between
/// them.
fn candidates_from_span(old: &[char], new: &[char]) -> Vec<EditCandidate> {
    // Two corrections the user made separately are separated by a real chunk of
    // unchanged text ("，他想做"). When the LCS instead splits one term because the
    // old and new share letters ("hydro fish" → "Hydra Facial"), the separator is
    // just a space or two. Merging those keeps the term whole.
    let mut grouped: Vec<(usize, usize, usize, usize)> = Vec::new();
    for (old_start, old_end, new_start, new_end) in lcs_hunks(old, new) {
        match grouped.last_mut() {
            Some(previous) if old_start.saturating_sub(previous.1) < MIN_HUNK_GAP => {
                previous.1 = old_end;
                previous.3 = new_end;
            }
            _ => grouped.push((old_start, old_end, new_start, new_end)),
        }
    }

    let mut split: Vec<EditCandidate> = Vec::new();
    let mut last_old_end = 0usize;

    for (old_start, old_end, new_start, new_end) in grouped {
        // A hunk with an empty side is a pure insertion or deletion (" " removed
        // between two matched words). Learning it is meaningless, and widening an
        // empty range would invent a span out of the neighbouring token.
        if old_start == old_end || new_start == new_end {
            continue;
        }

        // LCS reports minimal edits, which are frequently a single character
        // ("Q" for "QL" -> "KOL", because the L is common). Widening each hunk to
        // its token boundaries turns it back into the term the user replaced.
        let (old_start, old_end) = expand_to_token_bounds(old, old_start, old_end);
        let (new_start, new_end) = expand_to_token_bounds(new, new_start, new_end);

        // Widening can make neighbours overlap; the first one already covers it.
        if old_start < last_old_end {
            continue;
        }
        last_old_end = old_end;

        let candidate = EditCandidate {
            pattern: old[old_start..old_end].iter().collect(),
            replacement: new[new_start..new_end].iter().collect(),
        };
        if !candidate.pattern.is_empty() && !candidate.replacement.is_empty() {
            split.push(candidate);
        }
    }

    if split.len() >= 2 {
        return split;
    }

    vec![EditCandidate {
        pattern: old.iter().collect(),
        replacement: new.iter().collect(),
    }]
}

/// Every correction we can justify between `pasted` and `current`.
///
/// Empty when there is no edit, when we cannot locate the pasted text, or when
/// the change looks like a rewrite rather than a correction.
pub fn detect_edits(pasted: &str, current: &str) -> Vec<EditCandidate> {
    if pasted.trim().is_empty() || pasted == current {
        return Vec::new();
    }

    let pasted_chars: Vec<char> = pasted.chars().collect();
    if pasted_chars.len() > MAX_PASTED_CHARS {
        return Vec::new();
    }

    let current_chars: Vec<char> = current.chars().collect();

    for (start, end) in window_candidates(&pasted_chars, &current_chars)
        .into_iter()
        .take(8)
    {
        if let Some(candidates) = edits_in_window(&pasted_chars, &current_chars[start..end]) {
            return candidates;
        }
    }

    Vec::new()
}

/// The corrections visible in one candidate window, if any.
fn edits_in_window(pasted_chars: &[char], window: &[char]) -> Option<Vec<EditCandidate>> {
    let (prefix, suffix) = unchanged_span(pasted_chars, window);
    let unchanged = prefix + suffix;
    let required = MIN_UNCHANGED_CHARS.max(pasted_chars.len() / 3);
    if unchanged < required {
        return None;
    }

    let (raw_old_start, raw_old_end) = (prefix, pasted_chars.len() - suffix);
    let (raw_new_start, raw_new_end) = (prefix, window.len() - suffix);

    // Nothing changed, or a pure insertion/deletion. Checked *before* widening:
    // expanding an empty span would invent a candidate out of the neighbouring
    // token (a capitalization fix or appended text would look like an edit).
    if raw_old_start == raw_old_end || raw_new_start == raw_new_end {
        return None;
    }

    // A lone hanzi is not a term, so a change that is exactly one CJK character is
    // not learnable. Stop the window search here rather than sliding to a worse
    // alignment: the next alignment would smear the neighbouring characters into a
    // bogus multi-character span ("今天早" -> "天晚" for a simple 早 -> 晚 fix).
    if is_single_cjk(&pasted_chars[raw_old_start..raw_old_end])
        || is_single_cjk(&window[raw_new_start..raw_new_end])
    {
        return Some(Vec::new());
    }

    let (old_start, old_end) = expand_to_token_bounds(pasted_chars, raw_old_start, raw_old_end);
    let (new_start, new_end) = expand_to_token_bounds(window, raw_new_start, raw_new_end);

    let candidates: Vec<EditCandidate> = candidates_from_span(
        &pasted_chars[old_start..old_end],
        &window[new_start..new_end],
    )
    .into_iter()
    .filter(|candidate| spans_are_plausible(&candidate.pattern, &candidate.replacement))
    .take(MAX_CANDIDATES)
    .collect();

    if candidates.is_empty() {
        None
    } else {
        Some(candidates)
    }
}

fn eq_ignore_case(left: char, right: char) -> bool {
    left == right || left.to_lowercase().eq(right.to_lowercase())
}

#[cfg(test)]
mod tests {
    use super::*;

    /// The single (or first) correction, for assertions.
    fn candidate(pasted: &str, current: &str) -> Option<(String, String)> {
        detect_edits(pasted, current)
            .into_iter()
            .next()
            .map(|edit| (edit.pattern, edit.replacement))
    }

    #[test]
    fn rejects_a_whole_phrase_from_a_misaligned_diff() {
        // Real case: the polish step had replaced "Open Type Place" with the
        // dictionary word "Cica Exo", so the user's fix rewrote most of the
        // sentence. The diff aligned badly and proposed learning a whole phrase
        // (and a fragment starting with a space) as if it were a term.
        assert_eq!(
            candidate(
                "好，我们来测试一下我们新做的 Cica Exo 啊。",
                "好，我们来测试一下我们新做的这个 Open Type Place 啊。"
            ),
            None
        );
    }

    #[test]
    fn learns_a_chinese_to_english_replacement() {
        // Real case: the recognizer produced Chinese for "Hydra Facial", and the
        // correction starts at the very beginning of the text — which destroys any
        // prefix anchor.
        assert_eq!(
            candidate("那嗨桌飞手可以吗？", "那Hydra Facial可以吗？"),
            Some(("嗨桌飞手".to_string(), "Hydra Facial".to_string()))
        );
    }

    #[test]
    fn learns_a_two_word_english_term() {
        assert_eq!(
            candidate("那请问可以做hydro fish吗？", "那请问可以做Hydra Facial吗？"),
            Some(("hydro fish".to_string(), "Hydra Facial".to_string()))
        );
    }

    #[test]
    fn expands_a_short_span_to_the_replaced_term() {
        // Real case from the field: "C3XO" and "Cica Exo" share the C and the XO,
        // so the raw span was the single character "3" — useless as a rule.
        assert_eq!(
            candidate(
                "他想做 C3XO，可以吗？",
                "这儿有一个 KOL他想做 Cica Exo，可以吗？"
            ),
            Some(("C3XO".to_string(), "Cica Exo".to_string()))
        );
    }

    #[test]
    fn expands_to_boundaries_without_swallowing_cjk() {
        // The CJK text before the term must not be pulled into the span.
        assert_eq!(
            candidate("我们用 open type place 试试", "我们用 OpenTypeless 试试"),
            Some(("open type place".to_string(), "OpenTypeless".to_string()))
        );
    }

    #[test]
    fn learns_a_multi_word_term_fix() {
        assert_eq!(
            candidate("open type place 是什么", "OpenTypeless 是什么"),
            Some(("open type place".to_string(), "OpenTypeless".to_string()))
        );
    }

    #[test]
    fn a_single_cjk_character_is_not_learned() {
        // A lone character is not a term; the LLM path handles word-level fixes.
        assert_eq!(candidate("今天早上我要喝牛奶", "今天晚上我要喝牛奶"), None);
    }

    #[test]
    fn a_pure_insertion_at_the_end_is_not_a_correction() {
        assert_eq!(
            candidate("我们用的是大语言模型", "我们用的是大语言模型v2"),
            None
        );
    }

    #[test]
    fn learns_a_term_fix_with_a_prefix_in_the_field() {
        assert_eq!(
            candidate("我用 open type place", "我用 OpenTypeless"),
            Some(("open type place".to_string(), "OpenTypeless".to_string()))
        );
    }

    #[test]
    fn no_edit_is_not_a_candidate() {
        assert_eq!(candidate("hello world", "hello world"), None);
    }

    #[test]
    fn appended_text_is_not_a_correction() {
        assert_eq!(candidate("hello world", "hello world 还有更多"), None);
    }

    #[test]
    fn a_prefix_in_the_field_is_ignored() {
        assert_eq!(candidate("你好", "备注：你好"), None);
        assert_eq!(candidate("你好世界", "备注：你好世界"), None,);
    }

    #[test]
    fn capitalization_only_changes_are_ignored() {
        assert_eq!(candidate("abc", "Abc"), None);
        assert_eq!(candidate("hello world", "Hello World"), None);
    }

    #[test]
    fn pure_deletions_are_ignored() {
        assert_eq!(
            candidate("嗯那个就是说我们这个项目进展顺利", "我们这个项目进展顺利"),
            None
        );
    }

    #[test]
    fn a_full_rewrite_is_rejected() {
        assert_eq!(
            candidate(
                "the quick brown fox jumps",
                "a completely different sentence here"
            ),
            None
        );
    }

    #[test]
    fn a_long_span_is_rejected() {
        assert_eq!(
            candidate(
                "short",
                "a much longer replacement that goes well past the span limit"
            ),
            None
        );
    }

    #[test]
    fn a_single_word_change_in_a_long_sentence_is_learned() {
        // The prefix/suffix scan narrows this to the one word that changed, even
        // though the surrounding sentence is long.
        assert_eq!(
            candidate(
                "we should ship it today and then review tomorrow",
                "we should hold it today and then review tomorrow"
            ),
            Some(("ship".to_string(), "hold".to_string()))
        );
    }

    #[test]
    fn a_multi_word_span_over_the_word_limit_is_rejected() {
        // Both sides are short enough in characters, but seven words is a
        // rewrite of a phrase, not a term correction.
        assert_eq!(
            candidate(
                "we should alpha beta gamma delta epsilon zeta eta",
                "we should one two three four five six seven"
            ),
            None
        );
    }

    #[test]
    fn a_missing_anchor_gives_up() {
        assert_eq!(
            candidate("completely unrelated text", "nothing like it at all"),
            None
        );
    }

    #[test]
    fn empty_and_whitespace_inputs_are_safe() {
        assert_eq!(candidate("", "anything"), None);
        assert_eq!(candidate("   ", "anything"), None);
        assert_eq!(candidate("anything", ""), None);
    }

    #[test]
    fn an_absurdly_long_paste_is_skipped() {
        let pasted = "a".repeat(MAX_PASTED_CHARS + 1);
        let current = format!("{pasted}b");
        assert_eq!(candidate(&pasted, &current), None);
    }

    #[test]
    fn gate_accepts_a_close_ascii_mishearing() {
        assert!(is_likely_mishearing("C3XO", "Cica Exo"));
    }

    #[test]
    fn gate_rejects_a_semantic_ascii_change() {
        assert!(!is_likely_mishearing("ship", "hold"));
    }

    #[test]
    fn gate_accepts_cjk_with_shared_characters() {
        assert!(is_likely_mishearing("浏览起", "浏览器"));
    }

    #[test]
    fn gate_rejects_a_semantic_cjk_change() {
        assert!(!is_likely_mishearing("要喝牛奶", "想喝咖啡"));
    }

    #[test]
    fn gate_accepts_a_cross_script_mishearing() {
        assert!(is_likely_mishearing("嗨桌飞手", "Hydra Facial"));
    }

    #[test]
    fn gate_rejects_an_identical_pair() {
        assert!(!is_likely_mishearing("hello", "hello"));
    }

    #[test]
    fn related_accepts_a_short_dictation_still_anchoring() {
        // A short dictation has little shared text, but enough to prove the field
        // is the same one the user corrected.
        assert!(is_related("C3XO", "Cica Exo"));
    }

    #[test]
    fn related_accepts_a_small_append() {
        assert!(is_related("hello world", "hello world!"));
    }

    #[test]
    fn related_rejects_unrelated_text() {
        assert!(!is_related("hello world", "completely different text"));
    }

    #[test]
    fn related_rejects_an_empty_paste() {
        assert!(!is_related("", "anything"));
    }

    #[test]
    fn contains_normalized_ignores_case_and_punctuation() {
        assert!(contains_normalized("Hello, World!", "hello world"));
        assert!(contains_normalized("abc123", "ABC"));
        assert!(!contains_normalized("hello", "world"));
        assert!(!contains_normalized("hello", ""));
    }

    #[test]
    fn relation_score_counts_shared_prefix_and_suffix() {
        // Shared prefix "hello " (6); the differing middles share no suffix.
        assert_eq!(relation_score("hello world", "hello there"), 6);
        // Shared prefix "abc" (3) + shared suffix "def" (3).
        assert_eq!(relation_score("abcXYZdef", "abcQQQdef"), 6);
    }

    #[test]
    fn bounded_context_widens_the_difference() {
        let (old, new) = bounded_context("we should ship it today", "we should hold it today", 0);
        assert_eq!(old, "ship");
        assert_eq!(new, "hold");

        let (old, new) = bounded_context("we should ship it today", "we should hold it today", 3);
        assert_eq!(old, "ld ship it");
        assert_eq!(new, "ld hold it");
    }

    #[test]
    fn bounded_context_is_safe_on_identical_text() {
        let (old, new) = bounded_context("same", "same", 4);
        // Nothing differs: the returned context is empty (or the whole text).
        assert!(old.len() <= "same".len());
        assert!(new.len() <= "same".len());
    }
}
