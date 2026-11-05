/**
 * Pure date parsing and formatting utilities.
 *
 * No CM6 or DOM dependencies — safe to use from any context.
 * Supports multiple human-readable date formats, relative dates,
 * ISO 8601, and Org/Markdown timestamp delimiters.
 */

const ISO_DATE_PATTERN = /^(\d{4})-(\d{2})-(\d{2})$/;
const YEAR_FIRST_DATE_PATTERN = /^(\d{4})[-/.](\d{1,2})[-/.](\d{1,2})$/;
const MONTH_NAME_FIRST_PATTERN = /^([A-Za-z]+)\.?\s+(\d{1,2})(?:st|nd|rd|th)?(?:,)?\s+(\d{4})$/i;
const DAY_MONTH_NAME_PATTERN = /^(\d{1,2})(?:st|nd|rd|th)?\s+([A-Za-z]+)\.?(?:,)?\s+(\d{4})$/i;
const NUMERIC_MONTH_DAY_YEAR_PATTERN = /^(\d{1,2})[/-](\d{1,2})[/-](\d{4})$/;
const TIMESTAMP_LITERAL_PATTERN = /^([<[])([^\n]+)([>\]])$/;
const TIME_SUFFIX_PATTERN = /(?:^|\s)(\d{1,2}:\d{2})(?:-(\d{1,2}:\d{2}))?\s*$/;
const DAY_IN_MS = 86_400_000;

const WEEKDAY_NAMES = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"] as const;
const MONTH_NAMES_SHORT = [
  "Jan", "Feb", "Mar", "Apr", "May", "Jun",
  "Jul", "Aug", "Sep", "Oct", "Nov", "Dec",
] as const;

const MONTH_NAME_TO_INDEX = new Map<string, number>([
  ["jan", 1], ["january", 1],
  ["feb", 2], ["february", 2],
  ["mar", 3], ["march", 3],
  ["apr", 4], ["april", 4],
  ["may", 5],
  ["jun", 6], ["june", 6],
  ["jul", 7], ["july", 7],
  ["aug", 8], ["august", 8],
  ["sep", 9], ["sept", 9], ["september", 9],
  ["oct", 10], ["october", 10],
  ["nov", 11], ["november", 11],
  ["dec", 12], ["december", 12],
]);

const WEEKDAY_EDGE_PREFIX_PATTERN =
  /^(?:sun(?:day)?|mon(?:day)?|tue(?:s|sday)?|wed(?:nesday)?|thu(?:r|rs|rsday)?|fri(?:day)?|sat(?:urday)?)(?:,\s*|\s+)/i;
const WEEKDAY_EDGE_SUFFIX_PATTERN =
  /(?:,\s*|\s+)(?:sun(?:day)?|mon(?:day)?|tue(?:s|sday)?|wed(?:nesday)?|thu(?:r|rs|rsday)?|fri(?:day)?|sat(?:urday)?)$/i;

// ── Core date helpers ─────────────────────────────────────────────────────

function pad2(value: number): string {
  return String(value).padStart(2, "0");
}

function formatDatePartsUTC(date: Date): string {
  return `${date.getUTCFullYear()}-${pad2(date.getUTCMonth() + 1)}-${pad2(date.getUTCDate())}`;
}

function createUTCDate(year: number, month: number, day: number): Date | null {
  if (!Number.isInteger(year) || !Number.isInteger(month) || !Number.isInteger(day)) return null;
  const date = new Date(Date.UTC(year, month - 1, day));
  if (date.getUTCFullYear() !== year || date.getUTCMonth() !== month - 1 || date.getUTCDate() !== day) return null;
  return date;
}

export function parseISODateUTC(isoDate: string): Date | null {
  const match = isoDate.match(ISO_DATE_PATTERN);
  if (!match) return null;
  return createUTCDate(Number(match[1]), Number(match[2]), Number(match[3]));
}

function datePartsToISODate(year: number, month: number, day: number): string | null {
  const date = createUTCDate(year, month, day);
  return date ? formatDatePartsUTC(date) : null;
}

export function todayISODateLocal(): string {
  const now = new Date();
  return `${now.getFullYear()}-${pad2(now.getMonth() + 1)}-${pad2(now.getDate())}`;
}

export function currentTimeLocal(): string {
  const now = new Date();
  return `${pad2(now.getHours())}:${pad2(now.getMinutes())}`;
}

export function normalizeTimestampTime(value: string | null | undefined): string | null {
  if (!value) return null;
  const match = value.trim().match(/^(\d{1,2}):(\d{2})$/);
  if (!match) return null;
  const hour = Number(match[1]);
  const minute = Number(match[2]);
  if (!Number.isInteger(hour) || hour < 0 || hour > 23 || !Number.isInteger(minute) || minute < 0 || minute > 59) {
    return null;
  }
  return `${pad2(hour)}:${pad2(minute)}`;
}

export function weekdayForISODate(isoDate: string): string | null {
  const date = parseISODateUTC(isoDate);
  if (!date) return null;
  return WEEKDAY_NAMES[date.getUTCDay()] ?? null;
}

export function humanDateLabelForISODate(isoDate: string): string | null {
  const date = parseISODateUTC(isoDate);
  if (!date) return null;
  const monthName = MONTH_NAMES_SHORT[date.getUTCMonth()];
  if (!monthName) return null;
  return `${monthName} ${date.getUTCDate()}, ${date.getUTCFullYear()}`;
}

export function isValidISODate(isoDate: string): boolean {
  return parseISODateUTC(isoDate) != null;
}

export function shiftISODate(isoDate: string, deltaDays: number): string | null {
  const date = parseISODateUTC(isoDate);
  if (!date || !Number.isFinite(deltaDays)) return null;
  return formatDatePartsUTC(new Date(date.getTime() + deltaDays * DAY_IN_MS));
}

// ── Timestamp parsing ─────────────────────────────────────────────────────

export type TimestampKind = "active" | "inactive";

export interface ParsedTimestamp {
  kind: TimestampKind;
  isoDate: string;
  weekday: string;
  startTime: string | null;
  endTime: string | null;
  raw: string;
}

export interface TimestampDateTimeValue {
  isoDate: string;
  startTime: string | null;
  endTime: string | null;
}

function normalizeTimestampDateInput(value: string): string {
  return value.trim().replace(/\s+/g, " ").replace(/\s*,\s*/g, ", ");
}

function stripEdgeWeekdayTokens(value: string): string {
  let result = normalizeTimestampDateInput(value);
  let changed = true;
  while (changed) {
    changed = false;
    const prefix = result.match(WEEKDAY_EDGE_PREFIX_PATTERN);
    if (prefix) { result = result.slice(prefix[0].length).trim(); changed = true; }
    const suffix = result.match(WEEKDAY_EDGE_SUFFIX_PATTERN);
    if (suffix) { result = result.slice(0, result.length - suffix[0].length).trim(); changed = true; }
  }
  return normalizeTimestampDateInput(result);
}

function parseMonthName(value: string): number | null {
  return MONTH_NAME_TO_INDEX.get(value.trim().replace(/\.$/, "").toLowerCase()) ?? null;
}

function parseRelativeDateInput(value: string): string | null {
  const normalized = value.trim().toLowerCase();
  if (normalized === "today") return todayISODateLocal();
  if (normalized === "tomorrow") return shiftISODate(todayISODateLocal(), 1);
  if (normalized === "yesterday") return shiftISODate(todayISODateLocal(), -1);
  return null;
}

function parseTimestampDateOnlyContent(input: string): string | null {
  const relative = parseRelativeDateInput(input);
  if (relative) return relative;

  const normalized = stripEdgeWeekdayTokens(input);
  if (!normalized) return null;

  const normalizedRelative = parseRelativeDateInput(normalized);
  if (normalizedRelative) return normalizedRelative;

  if (isValidISODate(normalized)) return normalized;

  const yearFirst = normalized.match(YEAR_FIRST_DATE_PATTERN);
  if (yearFirst) return datePartsToISODate(Number(yearFirst[1]), Number(yearFirst[2]), Number(yearFirst[3]));

  const monthNameFirst = normalized.match(MONTH_NAME_FIRST_PATTERN);
  if (monthNameFirst) {
    const month = parseMonthName(monthNameFirst[1] ?? "");
    if (month) return datePartsToISODate(Number(monthNameFirst[3]), month, Number(monthNameFirst[2]));
  }

  const dayMonthName = normalized.match(DAY_MONTH_NAME_PATTERN);
  if (dayMonthName) {
    const month = parseMonthName(dayMonthName[2] ?? "");
    if (month) return datePartsToISODate(Number(dayMonthName[3]), month, Number(dayMonthName[1]));
  }

  const numericMDY = normalized.match(NUMERIC_MONTH_DAY_YEAR_PATTERN);
  if (numericMDY) {
    const left = Number(numericMDY[1]), right = Number(numericMDY[2]), year = Number(numericMDY[3]);
    return left > 12 && right <= 12 ? datePartsToISODate(year, right, left) : datePartsToISODate(year, left, right);
  }

  return null;
}

export function parseTimestampDateTimeContent(input: string): TimestampDateTimeValue | null {
  const normalized = normalizeTimestampDateInput(input);
  const timeMatch = normalized.match(TIME_SUFFIX_PATTERN);
  let dateInput = normalized;
  let startTime: string | null = null;
  let endTime: string | null = null;

  if (timeMatch) {
    startTime = normalizeTimestampTime(timeMatch[1]);
    endTime = timeMatch[2] ? normalizeTimestampTime(timeMatch[2]) : null;
    if (!startTime || (timeMatch[2] && !endTime)) return null;
    dateInput = normalized.slice(0, timeMatch.index).trim();
  }

  const isoDate = parseTimestampDateOnlyContent(dateInput);
  return isoDate ? { isoDate, startTime, endTime } : null;
}

export function parseTimestampDateContent(input: string): string | null {
  return parseTimestampDateTimeContent(input)?.isoDate ?? null;
}

export function parseTimestampLiteral(raw: string): ParsedTimestamp | null {
  const match = raw.match(TIMESTAMP_LITERAL_PATTERN);
  if (!match) return null;

  const open = match[1] ?? "";
  const innerText = match[2] ?? "";
  const close = match[3] ?? "";
  const validPair = (open === "[" && close === "]") || (open === "<" && close === ">");
  if (!validPair) return null;

  const value = parseTimestampDateTimeContent(innerText);
  if (!value) return null;
  const weekday = weekdayForISODate(value.isoDate);
  if (!weekday) return null;

  return {
    kind: open === "<" ? "active" : "inactive",
    isoDate: value.isoDate,
    weekday,
    startTime: value.startTime,
    endTime: value.endTime,
    raw,
  };
}

export function formatTimestamp(input: {
  kind: TimestampKind;
  isoDate: string;
  startTime?: string | null;
  endTime?: string | null;
  syntax?: "markdown" | "org";
}): string {
  const weekday = weekdayForISODate(input.isoDate);
  const humanLabel = humanDateLabelForISODate(input.isoDate);
  if (!weekday || !humanLabel) throw new Error(`Invalid ISO date: ${input.isoDate}`);
  const startTime = normalizeTimestampTime(input.startTime);
  const endTime = startTime ? normalizeTimestampTime(input.endTime) : null;
  const timeSuffix = startTime ? ` ${startTime}${endTime ? `-${endTime}` : ""}` : "";
  const dateLabel = input.syntax === "org" ? input.isoDate : humanLabel;
  const content = `${dateLabel} ${weekday}${timeSuffix}`;
  return input.kind === "active" ? `<${content}>` : `[${content}]`;
}
