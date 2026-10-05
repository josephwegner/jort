// The host schedules an OS notification from the captured submission time.
// It acknowledges OS acceptance; notification settings control actual delivery.
const MAXIMUM_MINUTES = 525600;

export async function validate(input) {
  const minutes = input.arguments?.minutes;
  return Number.isInteger(minutes) && minutes >= 1 && minutes <= MAXIMUM_MINUTES
    ? {output: ""}
    : {error: "Enter an integer delay from 1 to 525600 minutes."};
}

export default async function(input) {
  const validation = await validate(input);
  if (validation.error) return validation;
  return {action: {
    kind: "notification.schedule",
    content: input.content,
    minutes: input.arguments.minutes
  }};
}
