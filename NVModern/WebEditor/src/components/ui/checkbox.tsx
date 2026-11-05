import { Checkbox as CheckboxPrimitive } from "@base-ui/react/checkbox";
import { mergeClassName } from "../../lib/utils.ts";

export function Checkbox({
  className,
  ...props
}: CheckboxPrimitive.Root.Props) {
  return (
    <CheckboxPrimitive.Root
      data-slot="checkbox"
      className={mergeClassName("ui-checkbox", className)}
      {...props}
    >
      <CheckboxPrimitive.Indicator
        data-slot="checkbox-indicator"
        className="ui-checkbox-indicator"
      >
        <svg aria-hidden="true" viewBox="0 0 12 12">
          <path d="M2.2 6.2 4.7 8.5 9.8 3.4" />
        </svg>
      </CheckboxPrimitive.Indicator>
    </CheckboxPrimitive.Root>
  );
}
