import { WidgetType, type EditorView } from "@codemirror/view";
import { type CalcPlot } from "../calc/plot.ts";
import {
  CALC_PLOT_HEIGHT,
  calcPlotGeometry,
  calcPlotViewport,
  formatPlotCoordinate,
  nearestCalcPlotPoint,
  panCalcPlot,
  renderCalcPlotSvg,
  type CalcPlotViewport,
} from "../calc/plotSvg.ts";

let nextPlotId = 0;
export class CalcPlotWidget extends WidgetType {
  private readonly key: string;
  private readonly cleanup = new WeakMap<HTMLElement, () => void>();
  constructor(readonly plot: CalcPlot) {
    super();
    this.key = JSON.stringify(plot);
  }
  override eq(other: CalcPlotWidget): boolean {
    return this.key === other.key;
  }
  override toDOM(view: EditorView): HTMLElement {
    const wrapper = document.createElement("div");
    wrapper.className = "nv3-calc-plot";
    wrapper.setAttribute("contenteditable", "false");
    const chart = document.createElement("div");
    chart.className = "nv3-calc-plot-chart";
    chart.tabIndex = 0;
    chart.setAttribute("role", "group");
    chart.setAttribute(
      "aria-label",
      "Plot. Hover for coordinates. Shift-drag or use Shift-arrow keys to pan. Double-click or press Home to reset.",
    );
    const drawing = document.createElement("div");
    const tooltip = document.createElement("div");
    tooltip.className = "nv3-calc-plot-tooltip";
    tooltip.setAttribute("role", "tooltip");
    tooltip.id = `nv3-calc-plot-tooltip-${++nextPlotId}`;
    tooltip.hidden = true;
    chart.setAttribute("aria-describedby", tooltip.id);
    chart.append(drawing, tooltip);
    wrapper.append(chart);
    const id = `nv3-calc-plot-${nextPlotId}`;
    let width = 640,
      viewport = calcPlotViewport(this.plot),
      frame = 0;
    let drag: { pointerId: number; x: number; y: number; viewport: CalcPlotViewport } | null = null;
    const hideTooltip = () => {
      tooltip.hidden = true;
      drawing.querySelector(".nv3-calc-plot-hover")?.setAttribute("visibility", "hidden");
    };
    const draw = () => {
      drawing.innerHTML = renderCalcPlotSvg(this.plot, width, id, viewport);
      tooltip.hidden = true;
    };
    const scheduleDraw = () => {
      if (!frame)
        frame = requestAnimationFrame(() => {
          frame = 0;
          draw();
        });
    };
    const position = (event: PointerEvent) => {
      const rect = drawing.querySelector("svg")!.getBoundingClientRect();
      const geometry = calcPlotGeometry(width, viewport);
      return {
        x: ((event.clientX - rect.left) * geometry.width) / rect.width,
        y: ((event.clientY - rect.top) * CALC_PLOT_HEIGHT) / rect.height,
        rect,
        geometry,
      };
    };
    chart.addEventListener("pointerdown", (event) => {
      if (event.button !== 0 || !event.shiftKey) return;
      const { x, y, geometry } = position(event);
      if (x < geometry.left || x > geometry.right || y < geometry.top || y > geometry.bottom)
        return;
      event.preventDefault();
      event.stopPropagation();
      chart.focus({ preventScroll: true });
      chart.setPointerCapture(event.pointerId);
      drag = { pointerId: event.pointerId, x, y, viewport };
      chart.classList.add("nv3-calc-plot-panning");
      hideTooltip();
    });
    chart.addEventListener("pointermove", (event) => {
      const { x, y, rect } = position(event);
      chart.classList.toggle("nv3-calc-plot-can-pan", event.shiftKey);
      if (drag) {
        if (event.pointerId !== drag.pointerId) return;
        event.preventDefault();
        viewport = panCalcPlot(drag.viewport, width, x - drag.x, y - drag.y);
        scheduleDraw();
        return;
      }
      const nearest = nearestCalcPlotPoint(this.plot, viewport, width, x, y);
      if (!nearest) {
        hideTooltip();
        return;
      }
      const hover = drawing.querySelector(".nv3-calc-plot-hover")!;
      hover.setAttribute("visibility", "visible");
      const geometry = calcPlotGeometry(width, viewport);
      hover
        .querySelector("path")!
        .setAttribute("d", `M${nearest.x},${geometry.top}V${geometry.bottom}`);
      hover.querySelector("circle")!.setAttribute("cx", String(nearest.x));
      hover.querySelector("circle")!.setAttribute("cy", String(nearest.y));
      tooltip.textContent = `${this.plot.xLabel}: ${formatPlotCoordinate(nearest.point.x)} · ${this.plot.yLabel}: ${formatPlotCoordinate(nearest.point.y!)}`;
      tooltip.hidden = false;
      const chartRect = chart.getBoundingClientRect();
      tooltip.style.left = `${Math.max(0, Math.min(event.clientX - chartRect.left + 12, chart.clientWidth - tooltip.offsetWidth))}px`;
      tooltip.style.top = `${Math.max(0, Math.min(event.clientY - chartRect.top - tooltip.offsetHeight - 10, rect.height - tooltip.offsetHeight))}px`;
    });
    const endDrag = (event: PointerEvent) => {
      if (!drag || event.pointerId !== drag.pointerId) return;
      drag = null;
      chart.classList.remove("nv3-calc-plot-panning");
      if (chart.hasPointerCapture(event.pointerId)) chart.releasePointerCapture(event.pointerId);
    };
    chart.addEventListener("pointerup", endDrag);
    chart.addEventListener("pointercancel", endDrag);
    chart.addEventListener("lostpointercapture", endDrag);
    chart.addEventListener("pointerleave", () => {
      hideTooltip();
      chart.classList.remove("nv3-calc-plot-can-pan");
    });
    const reset = () => {
      viewport = calcPlotViewport(this.plot);
      hideTooltip();
      scheduleDraw();
    };
    chart.addEventListener("dblclick", (event) => {
      event.preventDefault();
      reset();
    });
    chart.addEventListener("keydown", (event) => {
      if (event.key === "Home") {
        event.preventDefault();
        event.stopPropagation();
        reset();
      }
      const direction = (
        {
          ArrowLeft: [-20, 0],
          ArrowRight: [20, 0],
          ArrowUp: [0, -20],
          ArrowDown: [0, 20],
        } as Record<string, number[]>
      )[event.key];
      if (event.shiftKey && direction) {
        event.preventDefault();
        event.stopPropagation();
        viewport = panCalcPlot(viewport, width, direction[0]!, direction[1]!);
        hideTooltip();
        scheduleDraw();
      }
      if (event.key === "Shift") chart.classList.add("nv3-calc-plot-can-pan");
      if (event.key === "Escape") {
        hideTooltip();
        chart.blur();
      }
    });
    chart.addEventListener("keyup", (event) => {
      if (event.key === "Shift") chart.classList.remove("nv3-calc-plot-can-pan");
    });
    chart.addEventListener("blur", () => {
      hideTooltip();
      chart.classList.remove("nv3-calc-plot-can-pan");
    });
    draw();
    const observer =
      typeof ResizeObserver === "undefined"
        ? null
        : new ResizeObserver(([entry]) => {
            if (!entry || entry.contentRect.width <= 0) return;
            const nextWidth = Math.max(280, Math.round(entry.contentRect.width));
            if (nextWidth === width) return;
            width = nextWidth;
            drag = null;
            chart.classList.remove("nv3-calc-plot-panning");
            scheduleDraw();
            view.requestMeasure();
          });
    observer?.observe(chart);
    this.cleanup.set(wrapper, () => {
      observer?.disconnect();
      if (frame) cancelAnimationFrame(frame);
    });
    return wrapper;
  }
  override destroy(dom: HTMLElement): void {
    this.cleanup.get(dom)?.();
  }
  override ignoreEvent(): boolean {
    return true;
  }
  override get estimatedHeight(): number {
    return CALC_PLOT_HEIGHT + 20;
  }
}
