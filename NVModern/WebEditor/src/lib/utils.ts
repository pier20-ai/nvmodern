export function cn(...classes: Array<string | false | null | undefined>): string {
  return classes.filter(Boolean).join(" ");
}

export function mergeClassName<State>(
  base: string,
  className?: string | ((state: State) => string | undefined),
): string | ((state: State) => string) {
  if (typeof className === "function") {
    return (state) => cn(base, className(state));
  }
  return cn(base, className);
}
