// Edit these defaults to change your next generated timestamp.
const FORMAT = "h:mma";

// Supported tokens: YYYY, MMM, MM, D, DD, ddd, H, HH, h, hh, mm, ss, a.
// Text without a token is copied literally. The clock/time zone are captured
// together at submission; this formatter never reads the machine clock.
const MONTHS = ["Jan", "Feb", "Mar", "Apr", "May", "Jun",
  "Jul", "Aug", "Sept", "Oct", "Nov", "Dec"];
const WEEKDAYS = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"];

function formatLocalTime(time, format) {
  const pad = number => String(number).padStart(2, "0");
  const hour12 = time.hour % 12 || 12;
  const tokens = {
    YYYY: String(time.year), MMM: MONTHS[time.month - 1], MM: pad(time.month),
    D: String(time.day), DD: pad(time.day), ddd: WEEKDAYS[time.weekday],
    H: String(time.hour), HH: pad(time.hour), h: String(hour12), hh: pad(hour12),
    mm: pad(time.minute), ss: pad(time.second), a: time.hour < 12 ? "am" : "pm"
  };
  return format.replace(/YYYY|MMM|MM|ddd|DD|D|HH|H|hh|h|mm|ss|a/g,
    token => tokens[token]);
}

export async function validate(input) {
  if (/[^\s\u0085]/.test(input.content)) {
    return {error: "This generator takes no arguments."};
  }
  const time = input.localTime;
  if (!time || !Number.isInteger(time.year) ||
      !Number.isInteger(time.month) || time.month < 1 || time.month > 12 ||
      !Number.isInteger(time.day) || time.day < 1 || time.day > 31 ||
      !Number.isInteger(time.weekday) || time.weekday < 0 || time.weekday > 6 ||
      !Number.isInteger(time.hour) || time.hour < 0 || time.hour > 23 ||
      !Number.isInteger(time.minute) || time.minute < 0 || time.minute > 59 ||
      !Number.isInteger(time.second) || time.second < 0 || time.second > 59) {
    return {error: "Captured local calendar data is unavailable or invalid."};
  }
  return {output: ""};
}

export default async function(input) {
  const validation = await validate(input);
  if (validation.error) return validation;
  const date = formatLocalTime(input.localTime, FORMAT);
  return {output: date};
}
