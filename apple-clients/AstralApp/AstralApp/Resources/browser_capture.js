// Captures bounded console output, uncaught errors, unhandled rejections and resource timing in the page world.
// MacBrowserPane injects it at document start into every frame with that tab's private channel name and keeps
// what it posts in per-tab rings for browser_console and browser_network; the native side revalidates every entry.
(() => {
  'use strict';
  const CHANNEL = __ASTRAL_CAPTURE_CHANNEL__;
  const handlers = globalThis.webkit && globalThis.webkit.messageHandlers;
  const channel = handlers ? handlers[CHANNEL] : undefined;
  if (!channel || typeof channel.postMessage !== 'function') return;
  const apply = Reflect.apply;
  const postMessage = channel.postMessage;
  const toText = String;
  const sliceText = String.prototype.slice;
  const splitText = String.prototype.split;
  const execPattern = RegExp.prototype.exec;
  const stringify = JSON.stringify;
  const describeObject = Object.prototype.toString;
  const getDescriptor = Object.getOwnPropertyDescriptor;
  const listen = EventTarget.prototype.addEventListener;
  const microtask = globalThis.queueMicrotask.bind(globalThis);
  const later = globalThis.setTimeout.bind(globalThis);
  const clock = performance.now.bind(performance);
  const NativeError = Error;
  const self = globalThis;
  const LEVELS = { log: 'log', info: 'info', warn: 'warn', error: 'error', debug: 'debug' };
  const TEXT = 2000;
  const BATCH = 50;
  const PER_SECOND = 45;
  const NETWORK_BURST = 10;
  const NETWORK_PACE = 300;
  const PENDING = 500;
  const frameLine = /@(.*):(\d+):(\d+)$/;

  const send = (message) => {
    try {
      apply(postMessage, channel, [message]);
    } catch (error) {}
  };
  const clip = (value) => apply(sliceText, toText(value), [0, TEXT]);

  const admitted = [];
  let cursor = 0;
  let consoleDropped = 0;
  const admit = () => {
    const at = clock();
    if (admitted.length < PER_SECOND) {
      admitted[admitted.length] = at;
      return true;
    }
    if (at - admitted[cursor] < 1000) return false;
    admitted[cursor] = at;
    cursor = (cursor + 1) % PER_SECOND;
    return true;
  };

  let queue = [];
  let scheduled = false;
  const flush = () => {
    scheduled = false;
    const batch = queue;
    queue = [];
    let index = 0;
    while (index < batch.length) {
      const part = [];
      for (let count = 0; count < BATCH && index < batch.length; count++) part[part.length] = batch[index++];
      send({ v: 1, e: part, d: consoleDropped });
      consoleDropped = 0;
    }
  };
  const enqueue = (entry) => {
    if (!admit()) {
      consoleDropped += 1;
      return;
    }
    queue[queue.length] = entry;
    if (!scheduled) {
      scheduled = true;
      microtask(flush);
    }
  };

  const describe = (value) => {
    try {
      switch (typeof value) {
        case 'string': return value;
        case 'undefined': return 'undefined';
        case 'function': return 'function';
        case 'object':
          if (value === null) return 'null';
          if (apply(describeObject, value, []) === '[object Error]') {
            return toText(value.name) + ': ' + toText(value.message);
          }
          return toText(stringify(value));
        default: return toText(value);
      }
    } catch (error) {
      try {
        return apply(describeObject, value, []);
      } catch (inner) {
        return '[unprintable]';
      }
    }
  };

  const callerLine = () => {
    try {
      const frames = apply(splitText, toText(new NativeError().stack), ['\n']);
      const found = frames.length > 2 ? apply(execPattern, frameLine, [frames[2]]) : null;
      return found ? Number(found[2]) : 0;
    } catch (error) {
      return 0;
    }
  };

  let busy = false;
  const record = (kind, level, values, line) => {
    if (busy) return;
    busy = true;
    try {
      let text = '';
      const count = values.length < 20 ? values.length : 20;
      for (let index = 0; index < count && text.length < TEXT; index++) {
        text += (index ? ' ' : '') + describe(values[index]);
      }
      enqueue({ k: kind, l: level, t: clip(text), n: line });
    } finally {
      busy = false;
    }
  };

  const target = self.console;
  if (target) {
    for (const name in LEVELS) {
      const original = target[name];
      if (typeof original !== 'function') continue;
      const level = LEVELS[name];
      const wrapped = function (...values) {
        record('c', level, values, callerLine());
        return apply(original, this, values);
      };
      try {
        target[name] = wrapped;
      } catch (error) {}
    }
  }

  const read = (proto, key) => {
    const descriptor = proto ? getDescriptor(proto, key) : undefined;
    return descriptor && descriptor.get ? descriptor.get : null;
  };
  const property = (getter, object) => {
    try {
      return getter ? apply(getter, object, []) : undefined;
    } catch (error) {
      return undefined;
    }
  };
  const errorEvent = self.ErrorEvent ? self.ErrorEvent.prototype : null;
  const errorMessage = read(errorEvent, 'message');
  const errorFile = read(errorEvent, 'filename');
  const errorLine = read(errorEvent, 'lineno');
  const errorTarget = read(Event.prototype, 'target');
  const rejection = self.PromiseRejectionEvent ? self.PromiseRejectionEvent.prototype : null;
  const rejectionReason = read(rejection, 'reason');

  apply(listen, self, ['error', (event) => {
    if (property(errorTarget, event) !== self || !errorMessage) return;
    const file = property(errorFile, event);
    const line = Number(property(errorLine, event)) || 0;
    const suffix = file ? ' (' + clip(file) + ':' + line + ')' : '';
    record('e', 'error', [toText(property(errorMessage, event)) + suffix], line);
  }, true]);
  apply(listen, self, ['unhandledrejection', (event) => {
    record('r', 'error', ['Unhandled rejection: ' + describe(property(rejectionReason, event))], 0);
  }, true]);

  const entryProto = self.PerformanceEntry ? self.PerformanceEntry.prototype : null;
  const resourceProto = self.PerformanceResourceTiming ? self.PerformanceResourceTiming.prototype : null;
  const listProto = self.PerformanceObserverEntryList ? self.PerformanceObserverEntryList.prototype : null;
  const entryName = read(entryProto, 'name');
  const entryDuration = read(entryProto, 'duration');
  const entryInitiator = read(resourceProto, 'initiatorType');
  const entrySize = read(resourceProto, 'transferSize');
  const entryList = listProto && typeof listProto.getEntries === 'function' ? listProto.getEntries : null;
  if (!self.PerformanceObserver || !entryName || !entryList) return;

  let pending = [];
  let pumping = false;
  let pumpedAt = 0;
  let networkDropped = 0;
  const pump = () => {
    pumpedAt = clock();
    const part = [];
    let index = 0;
    while (index < pending.length && part.length < NETWORK_BURST) part[part.length] = pending[index++];
    const rest = [];
    while (index < pending.length) rest[rest.length] = pending[index++];
    pending = rest;
    if (part.length || networkDropped) send({ v: 1, e: part, d: 0, n: networkDropped });
    networkDropped = 0;
    pumping = pending.length > 0;
    if (pumping) later(pump, NETWORK_PACE);
  };
  const observe = (list) => {
    let entries;
    try {
      entries = apply(entryList, list, []);
    } catch (error) {
      return;
    }
    for (let index = 0; index < entries.length; index++) {
      const entry = entries[index];
      if (pending.length >= PENDING) {
        networkDropped += 1;
        continue;
      }
      pending[pending.length] = {
        k: 'n', u: clip(property(entryName, entry)), i: clip(property(entryInitiator, entry) || ''),
        d: Number(property(entryDuration, entry)) || 0, s: Number(property(entrySize, entry)) || 0,
      };
    }
    if (!pumping || clock() - pumpedAt > NETWORK_PACE * 5) {
      pumping = true;
      later(pump, 0);
    }
  };
  try {
    new self.PerformanceObserver(observe).observe({ type: 'resource', buffered: true });
  } catch (error) {}
})();
