import { describe, expect, it, vi } from "vitest";

vi.mock("./client", () => {
  class CloudError extends Error {
    constructor(
      message: string,
      readonly code: string | null,
      readonly status: number,
    ) {
      super(message);
      this.name = "CloudError";
    }
  }
  return {
    CloudError,
    isAuthError: (e: unknown) =>
      e instanceof Error && /\bauth\b/.test(e.message),
  };
});

const { CloudError } = await import("./client");
const {
  planParts,
  usablePartSize,
  uploadAudioMultipart,
  PART_TRIES,
  DEFAULT_PART_BYTES,
} = await import("./audioUpload");

const MiB = 1024 * 1024;
const last = <T>(xs: readonly T[]): T => xs[xs.length - 1];

describe("planParts", () => {
  it("cuts equal parts with a smaller last one, 1-based, covering every byte", () => {
    const parts = planParts(70 * MiB, 32 * MiB);
    expect(parts).toEqual([
      { partNumber: 1, offset: 0, length: 32 * MiB },
      { partNumber: 2, offset: 32 * MiB, length: 32 * MiB },
      { partNumber: 3, offset: 64 * MiB, length: 6 * MiB },
    ]);
    expect(parts.reduce((n, p) => n + p.length, 0)).toBe(70 * MiB);
  });

  it("makes no tiny trailing part on an exact multiple, and nothing for an empty file", () => {
    expect(planParts(64 * MiB, 32 * MiB)).toHaveLength(2);
    expect(planParts(0)).toEqual([]);
    expect(() => planParts(10, 0)).toThrow();
  });

  it("takes the server's part size only when R2 and the edge accept it", () => {
    expect(usablePartSize(32 * MiB)).toBe(32 * MiB);
    expect(usablePartSize(8 * MiB)).toBe(8 * MiB);
    expect(usablePartSize(1 * MiB)).toBe(DEFAULT_PART_BYTES);
    expect(usablePartSize(100 * MiB)).toBe(DEFAULT_PART_BYTES);
    expect(usablePartSize("32")).toBe(DEFAULT_PART_BYTES);
  });
});

/** A fake multipart server: `onPart` decides each part PUT's answer. */
function fakeServer(
  onPart: (n: number, call: number) => "ok" | number = () => "ok",
) {
  const calls: string[] = [];
  let uploads = 0;
  const partCalls = new Map<string, number>();
  const cloudFetch = vi.fn(async (path: string, init?: RequestInit) => {
    const method = init?.method ?? "GET";
    calls.push(`${method} ${path}`);
    const m = /\/multipart(?:\/([^/]+)(?:\/(\d+|complete))?)?$/.exec(path)!;
    const [, uploadId, step] = m;
    if (!uploadId)
      return new Response(
        JSON.stringify({ uploadId: `u${++uploads}`, partSize: 32 * MiB }),
      );
    if (method === "DELETE") return new Response("{}");
    if (step === "complete")
      return new Response(
        JSON.stringify({ ok: true, size: 1, body: init?.body }),
      );
    const key = step; // counted across restarts
    const call = (partCalls.get(key) ?? 0) + 1;
    partCalls.set(key, call);
    const answer = onPart(Number(step), call);
    if (answer !== "ok")
      throw new CloudError(`cloud PUT ${path} → ${answer}`, null, answer);
    expect((init?.body as ArrayBuffer).byteLength).toBeGreaterThan(0);
    return new Response(
      JSON.stringify({ partNumber: Number(step), etag: `etag-${step}` }),
    );
  });
  const reads: [number, number][] = [];
  const readRange = vi.fn(async (offset: number, length: number) => {
    reads.push([offset, length]);
    return new ArrayBuffer(length);
  });
  return { calls, cloudFetch, readRange, reads, sleep: async () => {} };
}

describe("uploadAudioMultipart", () => {
  it("creates, sends each part read from disk by offset, and completes with the etags", async () => {
    const s = fakeServer();
    await uploadAudioMultipart("rec", 70 * MiB, s);
    expect(s.reads).toEqual([
      [0, 32 * MiB],
      [32 * MiB, 32 * MiB],
      [64 * MiB, 6 * MiB],
    ]);
    expect(s.calls).toEqual([
      "POST /recordings/rec/audio/multipart",
      "PUT /recordings/rec/audio/multipart/u1/1",
      "PUT /recordings/rec/audio/multipart/u1/2",
      "PUT /recordings/rec/audio/multipart/u1/3",
      "POST /recordings/rec/audio/multipart/u1/complete",
    ]);
    const complete = last(s.cloudFetch.mock.calls)[1]!;
    expect(JSON.parse(complete.body as string)).toEqual({
      parts: [
        { partNumber: 1, etag: "etag-1" },
        { partNumber: 2, etag: "etag-2" },
        { partNumber: 3, etag: "etag-3" },
      ],
    });
  });

  it("retries a part answered 408", async () => {
    const s = fakeServer((n, call) => (n === 2 && call < 3 ? 408 : "ok"));
    await uploadAudioMultipart("rec", 70 * MiB, s);
    expect(s.calls.filter((c) => c.endsWith("/u1/2"))).toHaveLength(3);
    expect(last(s.calls)).toBe(
      "POST /recordings/rec/audio/multipart/u1/complete",
    );
  });

  it("gives up on a part after its tries and aborts the upload", async () => {
    const s = fakeServer((n) => (n === 1 ? 408 : "ok"));
    await expect(uploadAudioMultipart("rec", 40 * MiB, s)).rejects.toThrow(
      /408/,
    );
    expect(s.calls.filter((c) => c.endsWith("/u1/1"))).toHaveLength(PART_TRIES);
    expect(last(s.calls)).toBe("DELETE /recordings/rec/audio/multipart/u1");
  });

  it("restarts the whole upload when the server lost it (404 no_such_upload)", async () => {
    const s = fakeServer((n, call) => (n === 2 && call === 1 ? 404 : "ok"));
    await uploadAudioMultipart("rec", 40 * MiB, s);
    expect(s.calls).toContain("POST /recordings/rec/audio/multipart");
    expect(
      s.calls.filter((c) => c === "POST /recordings/rec/audio/multipart"),
    ).toHaveLength(2);
    expect(last(s.calls)).toBe(
      "POST /recordings/rec/audio/multipart/u2/complete",
    );
  });

  it("hands a 410 (tombstoned) straight back without retrying", async () => {
    const s = fakeServer(() => 410);
    const err = await uploadAudioMultipart("rec", 40 * MiB, s).catch(
      (e: unknown) => e,
    );
    expect((err as { status?: number }).status).toBe(410);
    expect(s.calls.filter((c) => c.startsWith("PUT"))).toHaveLength(1);
  });
});
