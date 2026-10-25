/**
 * A tiny React + Remotion stand-in for previewing single frames on the server. The composition is
 * untrusted, so it runs inside QuickJS (see frame-worker.mjs), never in Node. Components are called
 * synchronously for one frame and produce a plain element tree; layout and painting happen in Node.
 * Only the APIs the agent is allowed to use are implemented, with Remotion's maths for interpolate,
 * spring, Easing and random so previews match the device.
 */
export const FRAME_RUNTIME = String.raw`
const FRAGMENT = Symbol.for("preview.fragment");
const SCOPE = Symbol.for("preview.scope");
export const Fragment = FRAGMENT;
export function jsx(type, props, key) { return { $$el: true, type, props: props || {}, key }; }
export const jsxs = jsx;
export const jsxDEV = jsx;
export function createElement(type, config, ...children) {
  const props = { ...(config || {}) };
  if (children.length) props.children = children.length === 1 ? children[0] : children;
  return jsx(type, props, props.key);
}
export function isValidElement(value) { return !!(value && value.$$el); }
export function cloneElement(element, extra, ...children) {
  const props = { ...element.props, ...(extra || {}) };
  if (children.length) props.children = children.length === 1 ? children[0] : children;
  return jsx(element.type, props, element.key);
}
const flatten = (value) => Array.isArray(value) ? value.flatMap(flatten) : value == null || typeof value === "boolean" ? [] : [value];
export const Children = {
  toArray: flatten,
  map: (children, fn) => flatten(children).map(fn),
  forEach: (children, fn) => flatten(children).forEach(fn),
  count: (children) => flatten(children).length,
  only: (children) => flatten(children)[0],
};
export function createContext(defaultValue) {
  const context = { $$stack: [], $$default: defaultValue };
  context.Provider = { $$provider: context };
  context.Consumer = ({ children }) => children(useContext(context));
  return context;
}
export function useContext(context) { return context.$$stack.length ? context.$$stack[context.$$stack.length - 1] : context.$$default; }
export const useMemo = (fn) => fn();
export const useCallback = (fn) => fn;
export const useRef = (current) => ({ current });
export const useState = (value) => [typeof value === "function" ? value() : value, () => {}];
export const useReducer = (_, value) => [value, () => {}];
export const useEffect = () => {};
export const useLayoutEffect = () => {};
export const useInsertionEffect = () => {};
let ids = 0;
export const useId = () => "p" + (ids += 1);
export const memo = (component) => component;
export const forwardRef = (render) => (props) => render(props, null);
export const Component = class {};
export const PureComponent = class {};
const React = { Fragment, createElement, cloneElement, isValidElement, Children, createContext, useContext, useMemo, useCallback,
  useRef, useState, useReducer, useEffect, useLayoutEffect, useInsertionEffect, useId, memo, forwardRef, Component, PureComponent };
export default React;

let frame = 0;
let config = { fps: 24, width: 1280, height: 720, durationInFrames: 1, id: "Main", defaultProps: {}, props: {} };
export const useCurrentFrame = () => frame;
export const useVideoConfig = () => config;
export const useCurrentScale = () => 1;
export const getInputProps = () => ({});
export const delayRender = () => 0;
export const continueRender = () => {};
export const cancelRender = (error) => { throw error; };
export const staticFile = (path) => "/" + String(path).replace(/^\/+/, "");

export function AbsoluteFill(props) {
  const { style, children, ...rest } = props;
  return jsx("div", { ...rest, children, style: { position: "absolute", top: 0, left: 0, right: 0, bottom: 0, width: "100%", height: "100%",
    display: "flex", flexDirection: "column", ...(style || {}) } });
}
export function Img(props) { return jsx("img", props); }
export function Sequence({ from = 0, durationInFrames = Infinity, children, layout = "absolute-fill", style }) {
  const local = frame - from;
  if (local < 0 || local >= durationInFrames) return null;
  const scope = { $$el: true, type: SCOPE, props: { frame: local, children } };
  return layout === "none" ? scope : jsx(AbsoluteFill, { style, children: scope });
}
export function Freeze({ frame: frozen, children, active = true }) {
  return active === false ? children : { $$el: true, type: SCOPE, props: { frame: frozen, children } };
}
export function Loop({ durationInFrames, times = Infinity, children, layout, style }) {
  const iteration = Math.floor(frame / durationInFrames);
  if (iteration >= times) return null;
  return jsx(Sequence, { from: iteration * durationInFrames, durationInFrames, layout, style, children });
}
function SeriesSequence() { return null; }
export function Series({ children }) {
  let from = 0;
  return flatten(children).map((child) => {
    const { durationInFrames = Infinity, offset = 0, children: inner, ...rest } = child.props || {};
    from += offset;
    const element = jsx(Sequence, { ...rest, from, durationInFrames, children: inner });
    from += durationInFrames;
    return element;
  });
}
Series.Sequence = SeriesSequence;

function interpolateSegment(input, [inMin, inMax], [outMin, outMax], { easing, extrapolateLeft, extrapolateRight }) {
  let result = input;
  if (result < inMin) {
    if (extrapolateLeft === "identity") return result;
    if (extrapolateLeft === "clamp") result = inMin;
    else if (extrapolateLeft === "wrap") result = ((((result - inMin) % (inMax - inMin)) + (inMax - inMin)) % (inMax - inMin)) + inMin;
  }
  if (result > inMax) {
    if (extrapolateRight === "identity") return result;
    if (extrapolateRight === "clamp") result = inMax;
    else if (extrapolateRight === "wrap") result = ((result - inMin) % (inMax - inMin)) + inMin;
  }
  if (outMin === outMax) return outMin;
  result = easing((result - inMin) / (inMax - inMin));
  return outMin + result * (outMax - outMin);
}
export function interpolate(input, inputRange, outputRange, options = {}) {
  if (typeof input !== "number" || Number.isNaN(input)) throw new Error("interpolate(): input must be a number, got " + String(input));
  if (!Array.isArray(inputRange) || !Array.isArray(outputRange) || inputRange.length !== outputRange.length) {
    throw new Error("interpolate(): inputRange and outputRange must have the same length");
  }
  if (inputRange.length < 2) throw new Error("interpolate(): inputRange must have at least 2 elements");
  for (let i = 0; i < inputRange.length; i += 1) {
    if (typeof inputRange[i] !== "number" || Number.isNaN(inputRange[i])) throw new Error("interpolate(): inputRange must contain only numbers, got [" + inputRange.join(",") + "]");
    if (typeof outputRange[i] !== "number" || Number.isNaN(outputRange[i])) throw new Error("interpolate(): outputRange must contain only numbers, got [" + outputRange.join(",") + "]");
    if (i > 0 && !(inputRange[i] > inputRange[i - 1])) throw new Error("interpolate(): inputRange must be strictly monotonically increasing but got [" + inputRange.join(",") + "]");
  }
  const settings = { easing: options.easing || ((x) => x), extrapolateLeft: options.extrapolateLeft || "extend", extrapolateRight: options.extrapolateRight || "extend" };
  let index = 1;
  for (; index < inputRange.length - 1; index += 1) if (inputRange[index] >= input) break;
  return interpolateSegment(input, [inputRange[index - 1], inputRange[index]], [outputRange[index - 1], outputRange[index]], settings);
}

const NAMED = { transparent: [0, 0, 0, 0], black: [0, 0, 0, 1], white: [255, 255, 255, 1], red: [255, 0, 0, 1], green: [0, 128, 0, 1], blue: [0, 0, 255, 1] };
function parseColor(color) {
  const value = String(color).trim().toLowerCase();
  if (NAMED[value]) return NAMED[value];
  let match = value.match(/^#([0-9a-f]{3,8})$/);
  if (match) {
    let hex = match[1];
    if (hex.length <= 4) hex = hex.split("").map((c) => c + c).join("");
    const n = (i) => parseInt(hex.slice(i, i + 2), 16);
    return [n(0), n(2), n(4), hex.length === 8 ? n(6) / 255 : 1];
  }
  match = value.match(/^rgba?\(([^)]+)\)$/);
  if (match) {
    const parts = match[1].split(/[\s,\/]+/).filter(Boolean).map(parseFloat);
    return [parts[0], parts[1], parts[2], parts[3] ?? 1];
  }
  throw new Error("interpolateColors(): unsupported color " + value);
}
export function interpolateColors(input, inputRange, outputRange) {
  const colors = outputRange.map(parseColor);
  const channel = (i) => interpolate(input, inputRange, colors.map((c) => c[i]), { extrapolateLeft: "clamp", extrapolateRight: "clamp" });
  return "rgba(" + [0, 1, 2].map((i) => Math.round(channel(i))).join(", ") + ", " + channel(3) + ")";
}

function bezier(x1, y1, x2, y2) {
  const a = (p1, p2) => 1 - 3 * p2 + 3 * p1, b = (p1, p2) => 3 * p2 - 6 * p1, c = (p1) => 3 * p1;
  const at = (t, p1, p2) => ((a(p1, p2) * t + b(p1, p2)) * t + c(p1)) * t;
  const slope = (t, p1, p2) => 3 * a(p1, p2) * t * t + 2 * b(p1, p2) * t + c(p1);
  const solve = (x) => {
    let t = x;
    for (let i = 0; i < 8; i += 1) {
      const d = slope(t, x1, x2);
      if (Math.abs(d) < 1e-6) break;
      t -= (at(t, x1, x2) - x) / d;
    }
    if (t >= 0 && t <= 1 && Math.abs(at(t, x1, x2) - x) < 1e-5) return t;
    let lo = 0, hi = 1;
    t = x;
    for (let i = 0; i < 40; i += 1) {
      const value = at(t, x1, x2);
      if (Math.abs(value - x) < 1e-6) break;
      if (value < x) lo = t; else hi = t;
      t = (lo + hi) / 2;
    }
    return t;
  };
  return (x) => x <= 0 ? 0 : x >= 1 ? 1 : at(solve(x), y1, y2);
}
const bounce = (t) => t < 1 / 2.75 ? 7.5625 * t * t : t < 2 / 2.75 ? 7.5625 * (t -= 1.5 / 2.75) * t + 0.75
  : t < 2.5 / 2.75 ? 7.5625 * (t -= 2.25 / 2.75) * t + 0.9375 : 7.5625 * (t -= 2.625 / 2.75) * t + 0.984375;
export const Easing = {
  step0: (n) => (n > 0 ? 1 : 0),
  step1: (n) => (n >= 1 ? 1 : 0),
  linear: (t) => t,
  ease: bezier(0.42, 0, 1, 1),
  quad: (t) => t * t,
  cubic: (t) => t * t * t,
  poly: (n) => (t) => Math.pow(t, n),
  sin: (t) => 1 - Math.cos((t * Math.PI) / 2),
  circle: (t) => 1 - Math.sqrt(1 - t * t),
  exp: (t) => Math.pow(2, 10 * (t - 1)),
  elastic: (bounciness = 1) => { const p = bounciness * Math.PI; return (t) => 1 - Math.pow(Math.cos((t * Math.PI) / 2), 3) * Math.cos(t * p); },
  back: (s = 1.70158) => (t) => t * t * ((s + 1) * t - s),
  bounce,
  bezier,
  in: (easing) => easing,
  out: (easing) => (t) => 1 - easing(1 - t),
  inOut: (easing) => (t) => t < 0.5 ? easing(t * 2) / 2 : 1 - easing((1 - t) * 2) / 2,
};

function springAt(seconds, { damping = 10, mass = 1, stiffness = 100, overshootClamping = false }) {
  if (seconds <= 0) return 0;
  const zeta = damping / (2 * Math.sqrt(stiffness * mass));
  const omega0 = Math.sqrt(stiffness / mass);
  let value;
  if (zeta < 1) {
    const omega1 = omega0 * Math.sqrt(1 - zeta * zeta);
    const envelope = Math.exp(-zeta * omega0 * seconds);
    value = 1 - envelope * ((zeta * omega0) / omega1 * Math.sin(omega1 * seconds) + Math.cos(omega1 * seconds));
  } else {
    value = 1 - Math.exp(-omega0 * seconds) * (1 + omega0 * seconds);
  }
  return overshootClamping ? Math.min(1, value) : value;
}
export function measureSpring({ fps, config: settings = {}, threshold = 0.005 }) {
  let settled = 0;
  for (let f = 0; f < 10000; f += 1) {
    if (Math.abs(1 - springAt(f / fps, settings)) > threshold) settled = f + 1;
    else if (f - settled > 20) break;
  }
  return settled;
}
export function spring({ frame: at, fps, config: settings = {}, from = 0, to = 1, durationInFrames, delay = 0, reverse = false, durationRestThreshold }) {
  let local = at - delay;
  if (durationInFrames !== undefined) {
    const natural = measureSpring({ fps, config: settings, threshold: durationRestThreshold });
    if (reverse) local = durationInFrames - local;
    local = local * (natural / durationInFrames);
  } else if (reverse) {
    local = measureSpring({ fps, config: settings }) - local;
  }
  const progress = springAt(local / fps, settings);
  return from + (to - from) * progress;
}

function mulberry32(a) {
  let t = a + 0x6d2b79f5;
  t = Math.imul(t ^ (t >>> 15), t | 1);
  t ^= t + Math.imul(t ^ (t >>> 7), t | 61);
  return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
}
function hashCode(text) {
  let hash = 0;
  for (let i = 0; i < text.length; i += 1) { hash = (hash << 5) - hash + text.charCodeAt(i); hash |= 0; }
  return hash;
}
export function random(seed) {
  if (typeof seed === "string") return mulberry32(hashCode(seed));
  if (typeof seed === "number") return mulberry32(seed * 10000000000);
  throw new Error("random() needs a string or number seed");
}

let rendered = 0;
function render(node) {
  if (node == null || typeof node === "boolean") return [];
  if (typeof node === "string" || typeof node === "number") return [String(node)];
  if (Array.isArray(node)) return node.flatMap(render);
  if (!node.$$el) return [];
  rendered += 1;
  if (rendered > 6000) throw new Error("The frame has more than 6000 elements");
  const { type, props } = node;
  if (type === FRAGMENT) return render(props.children);
  if (type === SCOPE) {
    const saved = frame;
    frame = props.frame;
    try { return render(props.children); } finally { frame = saved; }
  }
  if (type && type.$$provider) {
    const stack = type.$$provider.$$stack;
    stack.push(props.value);
    try { return render(props.children); } finally { stack.pop(); }
  }
  if (typeof type === "function") return render(type(props));
  if (typeof type !== "string") return [];
  const out = { t: type, p: {}, c: [] };
  for (const name in props) {
    if (name === "children" || name === "key" || name === "ref") continue;
    const value = props[name];
    if (value == null || typeof value === "function" || typeof value === "symbol") continue;
    out.p[name] = value;
  }
  out.c = render(props.children);
  return [out];
}

/** Renders \`Component\` at each frame; returns one element tree (or an error) per frame. */
export function __renderFrames(Component, frames, settings) {
  config = { ...config, ...settings };
  return frames.map((at) => {
    frame = at;
    rendered = 0;
    try { return { tree: render(jsx(Component, {})) }; }
    catch (error) { return { error: String(error && error.message || error).slice(0, 400) }; }
  });
}
`;
