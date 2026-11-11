// What each leader conversation's direction is called (docs/assistant/unified-entry.md "Leader conversations"): the
// sidebar's Directions group shows that name, not the conversation's title. `GET /api/v1/assistant` lists only the
// leaders' ids (`assistant.leaders`); the names come from `GET /api/v1/assistant/leaders` (#3519, #3695), which the hub
// works out (the name given, else the project's, else the title without its "MMDD | kind | " prefix).
// Asked again whenever the leaders or their titles change; until it answers, or on a hub that cannot, a row shows its title.
// Each current leader also has its open tasks' counts (`counts`: Working and Waiting on you, #4331); the hub sends the
// whole list again as `assistant_leaders` whenever the leaders, their names or their counts change (applyLeadersEvent),
// so an open sidebar follows a leader made or ended anywhere at once.
import { useEffect, useSyncExternalStore } from "react";
import { api } from "./api";

export const LEADERS_PATH = "/assistant/leaders";

export interface LeaderInfo {
  id: string;
  title?: string;
  name?: string;
  project?: string;
  ended?: boolean;
  counts?: LeaderCounts;
}

/** A leader's open tasks in the To-dos page's Working and Waiting on you sections. */
export interface LeaderCounts {
  working: number;
  needs_you: number;
}

/** The names of the current leaders, by conversation id (ended ones and blank names left out). */
export function directionNames(list: readonly LeaderInfo[] | undefined): Map<string, string> {
  const out = new Map<string, string>();
  for (const l of list ?? []) {
    const name = l.name?.trim();
    if (l.id && name && !l.ended) out.set(l.id, name);
  }
  return out;
}

/** What a leader row says: its direction's name, else the conversation's own title. */
export function directionLabel(names: ReadonlyMap<string, string>, id: string, title: string): string {
  return names.get(id) ?? title;
}

/** The counts of the current leaders, by conversation id. */
export function leaderCounts(list: readonly LeaderInfo[] | undefined): Map<string, LeaderCounts> {
  const out = new Map<string, LeaderCounts>();
  for (const l of list ?? []) {
    if (l.id && !l.ended && l.counts) out.set(l.id, { working: l.counts.working ?? 0, needs_you: l.counts.needs_you ?? 0 });
  }
  return out;
}

/** What a direction's row says at its end: "在做 N · 等你 N", the parts that are not zero; "" with nothing open. */
export function countsLabel(c: LeaderCounts | undefined, t: (key: string, o: { count: number }) => string): string {
  if (!c) return "";
  return [c.working > 0 ? t("sidebar.leader_working", { count: c.working }) : "", c.needs_you > 0 ? t("sidebar.leader_needs_you", { count: c.needs_you }) : ""].filter(Boolean).join(" · ");
}

/** The counts of every leader added up (the folded section's tally). */
export function totalCounts(counts: ReadonlyMap<string, LeaderCounts>, ids: readonly string[]): LeaderCounts {
  const out = { working: 0, needs_you: 0 };
  for (const id of ids) {
    const c = counts.get(id);
    if (c) {
      out.working += c.working;
      out.needs_you += c.needs_you;
    }
  }
  return out;
}

const listeners = new Set<() => void>();
let names: Map<string, string> = new Map();
let counts: Map<string, LeaderCounts> = new Map();
let askedFor = "";
let asked = 0;

function set(list: readonly LeaderInfo[] | undefined) {
  names = directionNames(list);
  counts = leaderCounts(list);
  listeners.forEach((l) => l());
}

/** The hub's `assistant_leaders` (the current leaders with their names and counts): taken at once, and remembered as
 *  asked for, so the next render does not ask again. Returns the leaders' ids in order. */
export function applyLeadersEvent(list: readonly LeaderInfo[] | undefined): string[] {
  asked++;
  set(list);
  const ids = (list ?? []).map((l) => l.id).filter(Boolean);
  toldIds = ids.join("\u0001");
  return ids;
}

/** The leaders the hub's last `assistant_leaders` named: while the page shows those, the event keeps their names and
 *  counts current (it comes again on any change), so nothing is asked for. */
let toldIds: string | null = null;
const idsOf = (key: string) => key.split("\u0001").map((k) => k.split("\u0000")[0]).filter(Boolean).join("\u0001");

/** Asks the hub for the names when `key` (the leaders and their titles) differs from the last ask. */
function ask(key: string) {
  if (key === askedFor) return;
  askedFor = key;
  if (toldIds !== null && idsOf(key) === toldIds) return;
  const n = ++asked;
  if (!key) return set([]);
  api<{ leaders?: LeaderInfo[] }>(LEADERS_PATH).then(
    (res) => n === asked && set(res.leaders),
    // an older hub or a failed read: the rows keep their titles; the next change asks again
    () => n === asked && (askedFor = ""),
  );
}

/** Forget the names (another login, tests). */
export function resetDirectionNames() {
  askedFor = "";
  asked++;
  names = new Map();
  counts = new Map();
  toldIds = null;
}

const subscribe = (l: () => void) => {
  listeners.add(l);
  return () => void listeners.delete(l);
};
const snapshot = () => names;

/** The direction names of `leaders` (ids), asked for again when `key` changes: pass the leaders with their titles,
 *  so a rename that changes a fallback name is picked up. */
export function useDirectionNames(key: string): ReadonlyMap<string, string> {
  useEffect(() => ask(key), [key]);
  return useSyncExternalStore(subscribe, snapshot, snapshot);
}

const countsSnapshot = () => counts;

/** The current leaders' counts (read with useDirectionNames, which asks for them). */
export function useLeaderCounts(): ReadonlyMap<string, LeaderCounts> {
  return useSyncExternalStore(subscribe, countsSnapshot, countsSnapshot);
}
