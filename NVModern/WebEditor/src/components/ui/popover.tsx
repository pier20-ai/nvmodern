import { Popover as PopoverPrimitive } from "@base-ui/react/popover";
import { mergeClassName } from "../../lib/utils.ts";

export function Popover(props: PopoverPrimitive.Root.Props) {
  return <PopoverPrimitive.Root data-slot="popover" {...props} />;
}

export function PopoverContent({
  className,
  align = "start",
  alignOffset = 0,
  side = "bottom",
  sideOffset = 0,
  anchor,
  positionMethod = "fixed",
  collisionPadding = 12,
  ...props
}: PopoverPrimitive.Popup.Props & Pick<
  PopoverPrimitive.Positioner.Props,
  | "align"
  | "alignOffset"
  | "side"
  | "sideOffset"
  | "anchor"
  | "positionMethod"
  | "collisionPadding"
>) {
  return (
    <PopoverPrimitive.Portal>
      <PopoverPrimitive.Positioner
        className="ui-popover-positioner"
        align={align}
        alignOffset={alignOffset}
        side={side}
        sideOffset={sideOffset}
        anchor={anchor}
        positionMethod={positionMethod}
        collisionPadding={collisionPadding}
      >
        <PopoverPrimitive.Popup
          data-slot="popover-content"
          className={mergeClassName("ui-popover-content", className)}
          {...props}
        />
      </PopoverPrimitive.Positioner>
    </PopoverPrimitive.Portal>
  );
}
