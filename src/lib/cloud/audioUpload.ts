// Uploading a recording's audio to Parley Cloud (pathorsAI/parley#755).
//
// Cloudflare's edge refuses any request body over 100 MB before the Worker
// sees it, and our 16 kHz mono Opus runs about 10.8 MB an hour, so a meeting
// longer than ~9 h could never go up with the single `PUT /recordings/:id/audio`.
// Files over 64 MiB now use the multipart API instead:
//
//   POST   /recordings/:id/audio/multipart                        → { uploadId, partSize }
//   PUT    /recordings/:id/audio/multipart/:uploadId/:partNumber  → { partNumber, etag }
//   POST   /recordings/:id/audio/multipart/:uploadId/complete     → { ok, size }
//   DELETE /recordings/:id/audio/multipart/:uploadId              (abort)
//
// Each 32 MiB part is read from disk when it is sent (`readRange`), so a
// many-hour recording is never held whole in the webview. A part answered 408
// (body cut short, R2 hiccup) or lost to the network is retried; 404
// `no_such_upload` (the upload expired or was aborted) and 400 `invalid_parts`
// at complete restart the whole upload; 410 is the recording tombstoned in the
// cloud and goes back to the caller, which stops pushing it. An upload that
// gives up is aborted, best effort, so R2 holds no orphaned parts.

import { CloudError, isAuthError } from "./client";

/** At or below this the single PUT is used (the server's part ceiling). */
export const MULTIPART_THRESHOLD_BYTES = 64 * 1024 * 1024;
/** The part size the server asks for (all parts but the last). */
export const DEFAULT_PART_BYTES = 32 * 1024 * 1024;
/** R2's smallest non-trailing part. */
const MIN_PART_BYTES = 5 * 1024 * 1024;

export interface PartPlan {
  partNumber: number;
  offset: number;
  length: number;
}

/** Split `size` bytes into 1-based parts of `partSize` (the last smaller). */
export function planParts(size: number, partSize: number = DEFAULT_PART_BYTES): PartPlan[] {
  if (!Number.isFinite(size) || size <= 0) return [];
  if (!Number.isFinite(partSize) || partSize <= 0) throw new Error(`invalid part size ${partSize}`);
  const parts: PartPlan[] = [];
  for (let offset = 0, n = 1; offset < size; offset += partSize, n++) {
    parts.push({ partNumber: n, offset, length: Math.min(partSize, size - offset) });
  }
  return parts;
}

/** The part size to use: the server's when it is one R2 and the edge accept. */
export function usablePartSize(fromServer: unknown): number {
  const n = typeof fromServer === "number" ? fromServer : Number.NaN;
  return Number.isInteger(n) && n >= MIN_PART_BYTES && n <= MULTIPART_THRESHOLD_BYTES ? n : DEFAULT_PART_BYTES;
}

export interface MultipartDeps {
  /** Bearer fetch against the cloud (`cloudFetch`): throws `CloudError` on a non-2xx. */
  cloudFetch: (path: string, init?: RequestInit) => Promise<Response>;
  /** `length` bytes of the recording from `offset`. */
  readRange: (offset: number, length: number) => Promise<ArrayBuffer>;
  /** Waits between part retries; injectable for tests. */
  sleep?: (ms: number) => Promise<void>;
}

/** Tries per part (408 / network) and whole-upload restarts (404 / invalid_parts). */
export const PART_TRIES = 4;
export const UPLOAD_RESTARTS = 2;

const statusOf = (e: unknown) => (e instanceof CloudError ? e.status : null);

/** The upload must start over: it is gone server-side or its parts were refused. */
class RestartUpload extends Error {}

const defaultSleep = (ms: number) => new Promise<void>((r) => setTimeout(r, ms));

/** PUT one part, retrying what a retry can fix; returns its etag. */
async function putPart(base: string, part: PartPlan, deps: MultipartDeps): Promise<string> {
  const sleep = deps.sleep ?? defaultSleep;
  for (let attempt = 1; ; attempt++) {
    try {
      const body = await deps.readRange(part.offset, part.length);
      if (body.byteLength !== part.length) {
        throw new Error(`read ${body.byteLength} of ${part.length} bytes at ${part.offset}`);
      }
      const res = await deps.cloudFetch(`${base}/${part.partNumber}`, {
        method: "PUT",
        headers: { "Content-Type": "application/octet-stream" },
        body,
      });
      const { etag } = (await res.json()) as { etag?: unknown };
      if (typeof etag !== "string" || !etag) throw new Error(`part ${part.partNumber}: no etag`);
      return etag;
    } catch (e) {
      const status = statusOf(e);
      if (status === 404) throw new RestartUpload(`part ${part.partNumber}: upload gone`);
      // 408 and network errors are retried; any other answer (a dead
      // session included) is final.
      const retryable = status === 408 || (status === null && !isAuthError(e));
      if (!retryable || attempt >= PART_TRIES) throw e;
      await sleep(1000 * 2 ** (attempt - 1));
    }
  }
}

/** One pass: create, send every part, complete. */
async function uploadOnce(id: string, size: number, deps: MultipartDeps): Promise<void> {
  const root = `/recordings/${encodeURIComponent(id)}/audio/multipart`;
  const created = (await (await deps.cloudFetch(root, { method: "POST" })).json()) as {
    uploadId?: unknown;
    partSize?: unknown;
  };
  if (typeof created.uploadId !== "string" || !created.uploadId) throw new Error("multipart: no uploadId");
  const base = `${root}/${encodeURIComponent(created.uploadId)}`;
  try {
    const parts: { partNumber: number; etag: string }[] = [];
    for (const part of planParts(size, usablePartSize(created.partSize))) {
      parts.push({ partNumber: part.partNumber, etag: await putPart(base, part, deps) });
    }
    await completeUpload(base, parts, deps);
  } catch (e) {
    // Whatever went wrong, leave no parts behind (a 404 upload is already gone).
    if (!(e instanceof RestartUpload)) await abortQuietly(base, deps);
    throw e;
  }
}

async function completeUpload(
  base: string,
  parts: { partNumber: number; etag: string }[],
  deps: MultipartDeps,
): Promise<void> {
  try {
    await deps.cloudFetch(`${base}/complete`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ parts }),
    });
  } catch (e) {
    const status = statusOf(e);
    if (status === 404) throw new RestartUpload("complete: upload gone");
    if (status === 400) {
      await abortQuietly(base, deps);
      throw new RestartUpload("complete: parts refused");
    }
    throw e;
  }
}

async function abortQuietly(base: string, deps: MultipartDeps): Promise<void> {
  await deps.cloudFetch(base, { method: "DELETE" }).catch(() => {});
}

/**
 * Upload `size` bytes of recording `id` through the multipart API. Throws the
 * cloud's error when it gives up (a 410 included, for the caller's tombstone
 * handling).
 */
export async function uploadAudioMultipart(id: string, size: number, deps: MultipartDeps): Promise<void> {
  for (let restart = 0; ; restart++) {
    try {
      await uploadOnce(id, size, deps);
      return;
    } catch (e) {
      if (!(e instanceof RestartUpload) || restart >= UPLOAD_RESTARTS) throw e;
    }
  }
}
