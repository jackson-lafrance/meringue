// Blocks blacklisted bash tool calls before Pi starts a subprocess.
// Meringue owns the environment value and validates it before launching Pi.

const ENV_KEY = "MERINGUE_WORKER_COMMAND_BLACKLIST";

export function globMatches(pattern, command) {
  const patternChars = Array.from(String(pattern));
  const commandChars = Array.from(String(command));
  let patternIndex = 0;
  let commandIndex = 0;
  let starIndex = -1;
  let starCommandIndex = -1;

  while (commandIndex < commandChars.length) {
    if (
      patternIndex < patternChars.length &&
      (patternChars[patternIndex] === "?" || patternChars[patternIndex] === commandChars[commandIndex])
    ) {
      patternIndex += 1;
      commandIndex += 1;
    } else if (patternIndex < patternChars.length && patternChars[patternIndex] === "*") {
      starIndex = patternIndex;
      starCommandIndex = commandIndex;
      patternIndex += 1;
    } else if (starIndex >= 0) {
      patternIndex = starIndex + 1;
      starCommandIndex += 1;
      commandIndex = starCommandIndex;
    } else {
      return false;
    }
  }

  while (patternChars[patternIndex] === "*") patternIndex += 1;
  return patternIndex === patternChars.length;
}

export function configuredPatterns(raw = process.env[ENV_KEY]) {
  if (!raw) return [];
  try {
    const parsed = JSON.parse(raw);
    if (!Array.isArray(parsed) || parsed.some((pattern) => typeof pattern !== "string" || pattern.length === 0)) {
      throw new Error("expected a non-empty string array");
    }
    return parsed;
  } catch (error) {
    throw new Error(`Invalid ${ENV_KEY}: ${error.message}`);
  }
}

export function blockedPattern(command, patterns) {
  return patterns.find((pattern) => globMatches(pattern, command));
}

export default function commandBlacklist(pi) {
  const patterns = configuredPatterns();

  pi.on("tool_call", (event) => {
    if (event.toolName !== "bash") return undefined;

    const command = typeof event.input?.command === "string" ? event.input.command : "";
    const pattern = blockedPattern(command, patterns);
    if (pattern === undefined) return undefined;

    return {
      block: true,
      reason: `Command blocked by Meringue worker blacklist pattern ${JSON.stringify(pattern)}.`,
    };
  });
}
