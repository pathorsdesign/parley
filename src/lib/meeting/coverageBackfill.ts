// Coverage backfill for live meetings (#728), the desktop twin of iOS's
// `TranscriptCoverage` + `MeetingUploader` backfill queue (#363) and Android's
// `TranscriptBackfiller`.
//
// A live transcript can come out much shorter than the recording: the relay
// dropped and could not come back, the session was refused, the app was quit
// or crashed mid-meeting (a recovered recording has no transcript at all). The
// recording is still whole on disk, so once a meeting is saved its transcript
// coverage is measured, and when it falls short — one gap of 30 s or more, or
// gaps adding up to 10 % of the recording, iOS's `BackfillPolicy.standard` —
// the whole file goes through the hosted batch lane (`transcribeRecording`)
// and the new transcript replaces the live one, exactly as iOS does and as the
// replay screen's 重新轉錄 button does by hand.
//
// Hosted (Parley Cloud) only: a BYOK user's batch provider bills their own key,
// and that is theirs to start (the re-transcribe button). The hosted batch
// ceiling is six hours; a recording over 5 h 50 min is skipped with a log line
// (cutting the gaps out of the file is not worth the second encoder for a case
// that has not been seen).
//
// The queue lives in localStorage so a backfill owed when Parley quits is run
// on the next launch. Each recording gets a few tries, then is dropped: a
// transcript that stays short is still the user's to fix by hand.

import { log } from "../log";
import { useStore, hasSpokenSegment } from "../store";
import { cloudToken } from "../cloud/client";
import { isTauri } from "../tauriEvents";
import type { TranscriptSegment } from "../types";

/** iOS `TranscriptCoverage.BackfillPolicy.standard`. */
export const BACKFILL_LONGEST_GAP_MS = 30_000;
export const BACKFILL_GAP_FRACTION = 0.1;
/** Hosted batch jobs stop at six hours; leave room for the measuring slack. */
export const BACKFILL_MAX_DURATION_MS = (5 * 60 + 50) * 60_000;
/** Tries per recording before it is left to the re-transcribe button. */
export const BACKFILL_MAX_ATTEMPTS = 3;

export interface Span {
  startMs: number;
  endMs: number;
}

export interface CoverageReport {
  totalMs: number;
  covered: Span[];
  gaps: Span[];
  gapMs: number;
  longestGapMs: number;
}

const spanMs = (s: Span) => s.endMs - s.startMs;

/** Overlapping or touching spans folded into one, in order. */
function mergeSpans(spans: Span[]): Span[] {
  const sorted = spans.filter((s) => spanMs(s) > 0).sort((a, b) => a.startMs - b.startMs || a.endMs - b.endMs);
  const merged: Span[] = [];
  for (const span of sorted) {
    const last = merged[merged.length - 1];
    if (last && span.startMs <= last.endMs) last.endMs = Math.max(last.endMs, span.endMs);
    else merged.push({ ...span });
  }
  return merged;
}

/** What of [0, totalMs) the merged `covered` spans leave out. */
function complement(covered: Span[], totalMs: number): Span[] {
  const gaps: Span[] = [];
  let cursor = 0;
  for (const span of covered) {
    if (span.startMs > cursor) gaps.push({ startMs: cursor, endMs: span.startMs });
    cursor = Math.max(cursor, span.endMs);
  }
  if (cursor < totalMs) gaps.push({ startMs: cursor, endMs: totalMs });
  return gaps;
}

/**
 * How much of a `totalMs` recording its final segments cover (iOS
 * `TranscriptCoverage.report`): tentative lines and the live tail don't count,
 * and segments are clipped to the recording.
 */
export function coverageReport(segments: readonly TranscriptSegment[], totalMs: number): CoverageReport {
  const total = Math.max(0, totalMs);
  const spans = segments
    .filter((s) => s.isFinal && !s.id.endsWith("-tail"))
    .map((s) => ({ startMs: Math.min(Math.max(0, s.startMs), total), endMs: Math.min(s.endMs, total) }))
    .filter((s) => s.endMs > s.startMs);
  const covered = mergeSpans(spans);
  const gaps = total > 0 ? complement(covered, total) : [];
  const gapMs = gaps.reduce((n, g) => n + spanMs(g), 0);
  const longestGapMs = gaps.reduce((n, g) => Math.max(n, spanMs(g)), 0);
  return { totalMs: total, covered, gaps, gapMs, longestGapMs };
}

/** iOS `Report.needsBackfill(policy: .standard)`. */
export function needsBackfill(report: CoverageReport): boolean {
  if (report.totalMs <= 0) return false;
  if (report.longestGapMs >= BACKFILL_LONGEST_GAP_MS) return true;
  return report.gapMs >= report.totalMs * BACKFILL_GAP_FRACTION;
}

export type BackfillPlan =
  | { kind: "none" }
  | { kind: "whole"; report: CoverageReport }
  | { kind: "too-long"; report: CoverageReport };

/** What to do about one saved recording's transcript. Pure. */
export function planBackfill(entry: { segments: readonly TranscriptSegment[]; durationMs: number }): BackfillPlan {
  const report = coverageReport(entry.segments, entry.durationMs);
  if (!needsBackfill(report)) return { kind: "none" };
  if (report.totalMs > BACKFILL_MAX_DURATION_MS) return { kind: "too-long", report };
  return { kind: "whole", report };
}

/** Covered milliseconds of a transcript over a `totalMs` recording. */
export function coveredMs(segments: readonly TranscriptSegment[], totalMs: number): number {
  const r = coverageReport(segments, totalMs);
  return r.totalMs - r.gapMs;
}

// ── Queue ───────────────────────────────────────────────────────────────────

const QUEUE_KEY = "parley.coverageBackfill.v1";

type Queue = Record<string, { attempts: number }>;

function readQueue(): Queue {
  try {
    return JSON.parse(localStorage.getItem(QUEUE_KEY) ?? "{}") as Queue;
  } catch {
    return {};
  }
}

function writeQueue(q: Queue): void {
  try {
    localStorage.setItem(QUEUE_KEY, JSON.stringify(q));
  } catch {
    /* storage full / unavailable: the backfill is best-effort */
  }
}

/** Ids waiting for a backfill, oldest first. */
export function pendingBackfills(): string[] {
  return Object.keys(readQueue());
}

function dropFromQueue(id: string): void {
  const q = readQueue();
  delete q[id];
  writeQueue(q);
}

/** Count a failed try; true while the recording has tries left. */
function countAttempt(id: string): boolean {
  const q = readQueue();
  const attempts = (q[id]?.attempts ?? 0) + 1;
  if (attempts >= BACKFILL_MAX_ATTEMPTS) {
    delete q[id];
    writeQueue(q);
    return false;
  }
  q[id] = { attempts };
  writeQueue(q);
  return true;
}

/** Whether a backfill can run now: hosted transcription, signed in. */
function hostedReady(): "ready" | "not-hosted" | "signed-out" {
  if (useStore.getState().settings.transcriptionProvider !== "parley") return "not-hosted";
  return cloudToken() ? "ready" : "signed-out";
}

/** What one try did. */
type Outcome = "done" | "retry" | "wait";

/** Resolve once the post-save speaker correction is no longer rewriting `id`
 *  (it folds labels onto the segments it read, so a backfill landing mid-way
 *  would be overwritten), or after `maxMs`. */
async function afterSpeakerCorrection(id: string, maxMs = 15 * 60_000): Promise<void> {
  const until = Date.now() + maxMs;
  while (useStore.getState().postSaveDiarizingId === id && Date.now() < until) {
    await new Promise((r) => setTimeout(r, 1000));
  }
}

/** Backfill one recording now. */
async function backfillOne(id: string): Promise<Outcome> {
  const gate = hostedReady();
  if (gate === "signed-out") return "wait";
  if (gate === "not-hosted") {
    log.info("backfill: not hosted transcription, leaving the transcript as is", { id });
    return "done";
  }
  const ipc = await import("../ipc/commands");
  const { meta, audioPath } = await ipc.readHistoryEntry({ id });
  const entry = meta as unknown as { segments?: TranscriptSegment[]; durationMs?: number };
  const segments = entry.segments ?? [];
  const plan = planBackfill({ segments, durationMs: entry.durationMs ?? 0 });
  if (plan.kind === "none" || !audioPath) return "done";
  const { totalMs, gapMs, longestGapMs } = plan.report;
  if (plan.kind === "too-long") {
    log.warn("backfill: recording is past the batch ceiling, skipped", { id, totalMs, gapMs });
    return "done";
  }
  log.info("backfill: transcript covers too little of the recording, re-transcribing", {
    id,
    totalMs,
    gapMs,
    longestGapMs,
  });
  const { transcribeRecording } = await import("../replay/ingest");
  const fresh = await transcribeRecording(useStore.getState().settings, audioPath, { fresh: true });
  const total = Math.max(totalMs, fresh.durationMs || 0);
  if (!hasSpokenSegment(fresh.segments) || coveredMs(fresh.segments, total) <= coveredMs(segments, total)) {
    log.info("backfill: batch transcript is no better, keeping the live one", { id });
    return "done";
  }
  await afterSpeakerCorrection(id);
  await replaceTranscript(id, fresh);
  return "done";
}

/** Swap the batch transcript in, the way the re-transcribe button does. */
async function replaceTranscript(id: string, fresh: import("../replay/types").ReplaySession): Promise<void> {
  const { retranscribedEntry } = await import("../replay/retranscribe");
  const { rewriteEntry, emitHistoryUpdated } = await import("../history/entryStore");
  const { pushToCloud } = await import("../history/cloudPush");
  const saved = await rewriteEntry(id, (m) => retranscribedEntry(m, fresh));
  log.info("backfill: transcript replaced", { id, segments: saved.segments.length, durationMs: saved.durationMs });
  await emitHistoryUpdated(id).catch(() => {});
  pushToCloud(id).catch((e) => log.warn("backfill: cloud push failed", { id, error: String(e) }));
  if (useStore.getState().loadedHistoryId === id) {
    const { loadHistoryEntry } = await import("../history/open");
    await loadHistoryEntry(id);
  }
}

/** One try, with its failure counted against the recording's attempts. */
async function tryBackfill(id: string): Promise<void> {
  let outcome: Outcome;
  try {
    outcome = await backfillOne(id);
  } catch (e) {
    log.warn("backfill: failed", { id, error: String(e) });
    outcome = "retry";
  }
  if (outcome === "done") dropFromQueue(id);
  else if (outcome === "retry" && !countAttempt(id)) log.warn("backfill: giving up on this recording", { id });
}

let draining: Promise<void> | null = null;

/** Run every queued backfill, one at a time. Concurrent calls share one run. */
export function drainCoverageBackfills(): Promise<void> {
  if (!isTauri()) return Promise.resolve();
  draining ??= (async () => {
    for (const id of pendingBackfills()) await tryBackfill(id);
  })().finally(() => {
    draining = null;
  });
  return draining;
}

/** Queue a just-saved live (or recovered) meeting for a coverage check, then
 *  run the queue in the background. Never throws. */
export function queueCoverageBackfill(id: string): void {
  const q = readQueue();
  if (!q[id]) {
    q[id] = { attempts: 0 };
    writeQueue(q);
  }
  // A drain already running walks the list it read when it started; chain
  // another pass so this id is picked up.
  void (draining ?? Promise.resolve()).then(() => drainCoverageBackfills());
}
