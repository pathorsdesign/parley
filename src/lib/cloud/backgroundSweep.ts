// Background cloud sweep (#728). A live save pushes its recording once, fire
// and forget (history/cloudPush.ts); when that push fails — offline, a server
// hiccup, the app quit before it finished — the entry is left dirty for the
// sweep, and the sweep used to run only when the Library screen was opened. A
// user who records from the tray and never opens the library then never had
// that meeting in the cloud. Run it at launch, every few minutes, and whenever
// the network comes back.

import { log } from "../log";
import { pushUnsyncedToCloud } from "./sync";

/** How often the sweep runs while the app is open. */
export const SWEEP_EVERY_MS = 15 * 60_000;

/** Run one sweep, logging instead of throwing. */
function sweep(why: string): void {
  pushUnsyncedToCloud()
    .then((n) => {
      if (n) log.info("cloud: background sweep pushed entries", { why, changed: n });
    })
    .catch((e) => log.warn("cloud: background sweep failed", { why, error: String(e) }));
}

/** Start the sweep; returns its stop function. */
export function startBackgroundSweep(
  timers: Pick<typeof globalThis, "setInterval" | "clearInterval"> = globalThis,
): () => void {
  sweep("launch");
  const timer = timers.setInterval(() => sweep("interval"), SWEEP_EVERY_MS);
  const onOnline = () => sweep("online");
  globalThis.addEventListener?.("online", onOnline);
  return () => {
    timers.clearInterval(timer);
    globalThis.removeEventListener?.("online", onOnline);
  };
}
