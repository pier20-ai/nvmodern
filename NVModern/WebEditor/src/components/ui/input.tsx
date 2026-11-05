import type { ComponentProps } from "react";
import { cn } from "../../lib/utils.ts";

export function Input({ className, type = "text", ...props }: ComponentProps<"input">) {
  return (
    <input
      type={type}
      data-slot="input"
      className={cn("ui-input", className)}
      {...props}
    />
  );
}
