import { describe, expect, it, vi } from "vitest";

vi.mock("../store", () => ({ useStore: { getState: () => ({}) }, hasSpokenSegment: () => true }));
vi.mock("../cloud/client", () => ({ cloudToken: () => "t" }));
vi.mock("../tauriEvents", () => ({ isTauri: () => false }));
vi.mock("../log", () => ({ log: { info: vi.fn(), warn: vi.fn() } }));

const { coverageReport, needsBackfill, planBackfill, coveredMs, BACKFILL_MAX_DURATION_MS } = await import(
  "./coverageBackfill"
);
import type { TranscriptSegment } from "../types";

const seg = (startMs: number, endMs: number, over: Partial<TranscriptSegment> = {}): TranscriptSegment => ({
  id: `s${startMs}`,
  source: "me",
  speaker: 0,
  text: "x",
  isFinal: true,
  startMs,
  endMs,
  ...over,
});
const MIN = 60_000;

describe("coverageReport", () => {
  it("merges overlapping segments and lists the gaps, ends included", () => {
    const r = coverageReport([seg(1000, 5000), seg(4000, 9000), seg(20_000, 30_000)], 40_000);
    expect(r.covered).toEqual([
      { startMs: 1000, endMs: 9000 },
      { startMs: 20_000, endMs: 30_000 },
    ]);
    expect(r.gaps).toEqual([
      { startMs: 0, endMs: 1000 },
      { startMs: 9000, endMs: 20_000 },
      { startMs: 30_000, endMs: 40_000 },
    ]);
    expect(r.gapMs).toBe(22_000);
    expect(r.longestGapMs).toBe(11_000);
  });

  it("ignores tentative lines and the live tail, and clips to the recording", () => {
    const r = coverageReport(
      [seg(0, 10_000, { isFinal: false }), seg(0, 10_000, { id: "me-tail" }), seg(5000, 99_000)],
      20_000,
    );
    expect(r.covered).toEqual([{ startMs: 5000, endMs: 20_000 }]);
    expect(r.gapMs).toBe(5000);
  });
});

describe("needsBackfill (iOS BackfillPolicy.standard)", () => {
  it("#728: 2.6 min of transcript over an 18.2 min recording needs one", () => {
    const live = [seg(0, 2.6 * MIN)];
    expect(needsBackfill(coverageReport(live, 18.2 * MIN))).toBe(true);
    expect(planBackfill({ segments: live, durationMs: 18.2 * MIN }).kind).toBe("whole");
  });

  it("a single gap of 30 s triggers it; 29 s of scattered pauses on a long meeting does not", () => {
    expect(needsBackfill(coverageReport([seg(0, 30 * MIN), seg(30 * MIN + 30_000, 60 * MIN)], 60 * MIN))).toBe(true);
    const pauses = [seg(0, 20 * MIN), seg(20 * MIN + 29_000, 60 * MIN)];
    expect(needsBackfill(coverageReport(pauses, 60 * MIN))).toBe(false);
  });

  it("many short gaps adding up to 10 % trigger it", () => {
    // 10 s of every 100 s uncovered.
    const segs = Array.from({ length: 10 }, (_, i) => seg(i * 100_000, i * 100_000 + 90_000));
    expect(needsBackfill(coverageReport(segs, 1_000_000))).toBe(true);
  });

  it("an empty transcript (a recovered recording) is one whole-file gap; an empty file needs nothing", () => {
    expect(planBackfill({ segments: [], durationMs: 10 * MIN }).kind).toBe("whole");
    expect(planBackfill({ segments: [], durationMs: 0 }).kind).toBe("none");
  });

  it("a recording past the 5 h 50 min batch ceiling is skipped, not sent", () => {
    expect(planBackfill({ segments: [], durationMs: BACKFILL_MAX_DURATION_MS + 1 }).kind).toBe("too-long");
    expect(planBackfill({ segments: [], durationMs: BACKFILL_MAX_DURATION_MS }).kind).toBe("whole");
  });

  it("coveredMs compares a batch result with the live transcript", () => {
    expect(coveredMs([seg(0, 2.6 * MIN)], 18.2 * MIN)).toBe(2.6 * MIN);
    expect(coveredMs([seg(0, 18 * MIN)], 18.2 * MIN)).toBe(18 * MIN);
  });
});
