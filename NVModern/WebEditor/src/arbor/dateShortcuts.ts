import {
  formatTimestamp,
  type TimestampKind,
} from "../lib/plugins/dateUtils.ts";
import { scanMarkdownTimestamps } from "../lib/plugins/dates.ts";

export interface ArborTimestampEdit {
  readonly text: string;
  readonly from: number;
  readonly to: number;
  readonly raw: string;
  readonly kind: TimestampKind;
}

export function insertOrReplaceArborTimestamp(
  text: string,
  start: number,
  end: number,
  isoDate: string,
): ArborTimestampEdit {
  const from = Math.max(0, Math.min(start, end, text.length));
  const to = Math.max(from, Math.min(Math.max(start, end), text.length));
  const occurrence = scanMarkdownTimestamps(text).find((timestamp) => (
    from === to
      ? from >= timestamp.from && from <= timestamp.to
      : from < timestamp.to && to > timestamp.from
  ));
  const replaceFrom = occurrence?.from ?? from;
  const replaceTo = occurrence?.to ?? to;
  const kind = occurrence?.kind ?? "inactive";
  const raw = formatTimestamp({ kind, isoDate });

  return {
    text: `${text.slice(0, replaceFrom)}${raw}${text.slice(replaceTo)}`,
    from: replaceFrom,
    to: replaceFrom + raw.length,
    raw,
    kind,
  };
}

export function updateInsertedArborTimestamp(
  text: string,
  edit: ArborTimestampEdit,
  isoDate: string,
): ArborTimestampEdit | null {
  if (text.slice(edit.from, edit.to) !== edit.raw) return null;
  const raw = formatTimestamp({ kind: edit.kind, isoDate });
  return {
    text: `${text.slice(0, edit.from)}${raw}${text.slice(edit.to)}`,
    from: edit.from,
    to: edit.from + raw.length,
    raw,
    kind: edit.kind,
  };
}
