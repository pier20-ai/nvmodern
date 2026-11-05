import { Button as ButtonPrimitive } from "@base-ui/react/button";
import { mergeClassName } from "../../lib/utils.ts";

export function Button({ className, ...props }: ButtonPrimitive.Props) {
  return (
    <ButtonPrimitive
      data-slot="button"
      className={mergeClassName("ui-button", className)}
      {...props}
    />
  );
}
