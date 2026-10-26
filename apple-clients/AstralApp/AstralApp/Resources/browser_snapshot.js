// Builds bounded accessibility-style snapshots and runs reference-addressed actions for the Mac browser pane.
// MacBrowserPane injects it at document start into every frame of an isolated content world with RULES from
// ComputerBrowserPolicy; MacBrowserDriver calls globalThis.__astralBrowser and rechecks every target in Swift.
(() => {
  'use strict';
  if (globalThis.__astralBrowser) return;
  const RULES = __ASTRAL_BROWSER_RULES__;
  const identifierRule = new RegExp(RULES.identifier_pattern);
  const camelRule = new RegExp(RULES.camel_pattern, 'g');
  const nonField = new Set(RULES.non_field_types);
  const token = typeof crypto.randomUUID === 'function'
    ? crypto.randomUUID()
    : Array.from(crypto.getRandomValues(new Uint8Array(16)), (b) => b.toString(16).padStart(2, '0')).join('');
  const ids = new WeakMap();
  const observations = new Map();
  let nextObservation = 1;
  const elements = new Map();
  const snapshots = new Map();
  let nextId = 1;
  const SKIP = new Set(['script', 'style', 'noscript', 'template', 'head', 'meta', 'link', 'title', 'base']);
  const INTERACTIVE = new Set([
    'button', 'link', 'textbox', 'searchbox', 'checkbox', 'radio', 'combobox', 'listbox', 'slider', 'spinbutton',
    'switch', 'tab', 'menuitem', 'menuitemcheckbox', 'menuitemradio', 'option', 'treeitem', 'clickable',
  ]);
  const LANDMARKS = new Set([
    'banner', 'navigation', 'main', 'complementary', 'contentinfo', 'region', 'form', 'search', 'dialog',
    'alertdialog',
  ]);
  const STRUCTURE = new Set(['paragraph', 'listitem', 'cell', 'columnheader', 'img', 'table']);
  const COVERS = new Set([
    'heading', 'link', 'button', 'paragraph', 'listitem', 'cell', 'columnheader', 'option', 'img', 'textbox',
    'searchbox', 'combobox', 'clickable', 'tab', 'menuitem',
  ]);
  const NAME_FROM_CONTENT = new Set([
    'button', 'link', 'heading', 'tab', 'menuitem', 'menuitemcheckbox', 'menuitemradio', 'option', 'treeitem',
    'switch', 'checkbox', 'radio', 'cell', 'columnheader', 'listitem', 'paragraph', 'clickable',
  ]);
  const KNOWN_ROLES = new Set([...INTERACTIVE, ...LANDMARKS, ...STRUCTURE, 'heading', 'list', 'row', 'group']);
  const TEXT_TYPES = new Set(['', 'text', 'search', 'email', 'url', 'tel', 'password', 'number', 'date',
    'datetime-local', 'month', 'week', 'time']);

  const channel = globalThis.webkit && globalThis.webkit.messageHandlers
    && globalThis.webkit.messageHandlers.astralBrowser;
  const post = (message) => {
    if (!channel) return;
    try {
      const reply = channel.postMessage(message);
      if (reply && typeof reply.catch === 'function') reply.catch(() => {});
    } catch (error) {}
  };
  const announce = (persisted) => post({ kind: 'hello', token, url: String(location.href).slice(0, 4096), persisted });
  announce(false);
  addEventListener('pageshow', (event) => { if (event.persisted) announce(true); }, true);
  addEventListener('pagehide', () => post({ kind: 'bye', token }), true);

  const clean = (value, limit) => String(value == null ? '' : value).replace(/\s+/g, ' ').trim().slice(0, limit);
  const tagOf = (el) => el.tagName.toLowerCase();
  const typeOf = (el) => {
    const tag = tagOf(el);
    if (tag === 'input' || tag === 'button') return String(el.type || '').toLowerCase();
    return String(el.getAttribute('type') || '').toLowerCase();
  };

  function localId(el) {
    let id = ids.get(el);
    if (id === undefined) {
      id = nextId++;
      ids.set(el, id);
      elements.set(id, new WeakRef(el));
      if (elements.size > 50000) {
        for (const [key, ref] of elements) {
          const target = ref.deref();
          if (!target || !target.isConnected) elements.delete(key);
        }
      }
    }
    return id;
  }

  function resolve(snapshot, id) {
    const listed = snapshots.get(snapshot);
    if (!listed || !listed.has(id)) return null;
    const el = elements.get(id) && elements.get(id).deref();
    return el && el.isConnected ? el : null;
  }

  function remember(snapshot, listed) {
    snapshots.set(snapshot, listed);
    while (snapshots.size > 8) snapshots.delete(snapshots.keys().next().value);
  }

  function isField(el) {
    const tag = tagOf(el);
    if (tag === 'textarea' || tag === 'select') return true;
    if (tag === 'input') {
      const type = typeOf(el);
      return type === 'password' || !nonField.has(type);
    }
    return !!el.isContentEditable;
  }

  function identifier(value) {
    return String(value || '').replace(camelRule, '$1 $2').toLowerCase();
  }

  function isSecret(el) {
    if (!isField(el)) return false;
    if (tagOf(el) === 'input' && RULES.secret_types.includes(typeOf(el))) return true;
    const tokens = String(el.getAttribute('autocomplete') || '').toLowerCase().split(/\s+/).filter(Boolean);
    if (tokens.some((item) => RULES.secret_autocomplete.includes(item)
      || RULES.secret_autocomplete_prefixes.some((prefix) => item.startsWith(prefix))
      || RULES.secret_autocomplete_suffixes.some((suffix) => item.endsWith(suffix)))) return true;
    return [el.getAttribute('name'), el.id].some((value) => identifierRule.test(identifier(value)));
  }

  function formOf(el) {
    return el.form || (el.closest && el.closest('form')) || null;
  }

  function formHasSecret(form) {
    if (!form) return false;
    return Array.from(form.elements || []).some((item) => item instanceof Element && isSecret(item));
  }

  function shown(el) {
    if (el.hidden || el.getAttribute('aria-hidden') === 'true') return false;
    const style = getComputedStyle(el);
    if (style.display === 'none') return false;
    if (style.display === 'contents') return true;
    if (typeof el.checkVisibility === 'function') return el.checkVisibility({ checkVisibilityCSS: true });
    return style.visibility !== 'hidden' && style.visibility !== 'collapse';
  }

  function sectioned(el) {
    return !!(el.parentElement && el.parentElement.closest('article, aside, main, nav, section'));
  }

  function clickable(el) {
    if (el.hasAttribute('onclick')) return true;
    const tabindex = el.getAttribute('tabindex');
    if (tabindex !== null && Number(tabindex) >= 0) return true;
    if (getComputedStyle(el).cursor !== 'pointer') return false;
    const parent = el.parentElement;
    if (parent && getComputedStyle(parent).cursor === 'pointer') return false;
    return !el.closest('a[href], button, [role="button"], [role="link"], label, summary');
  }

  function roleOf(el) {
    const explicit = String(el.getAttribute('role') || '').trim().split(/\s+/)[0].toLowerCase();
    if (explicit && KNOWN_ROLES.has(explicit)) return explicit;
    const tag = tagOf(el);
    const type = typeOf(el);
    switch (tag) {
      case 'a': return el.hasAttribute('href') ? 'link' : '';
      case 'button': return 'button';
      case 'summary': return 'button';
      case 'select': return el.multiple || el.size > 1 ? 'listbox' : 'combobox';
      case 'textarea': return 'textbox';
      case 'input':
        if (['button', 'submit', 'reset', 'image'].includes(type)) return 'button';
        if (type === 'checkbox') return 'checkbox';
        if (type === 'radio') return 'radio';
        if (type === 'range') return 'slider';
        if (type === 'number') return 'spinbutton';
        if (type === 'search') return 'searchbox';
        if (type === 'file') return 'button';
        if (type === 'hidden' || type === 'color') return '';
        return el.hasAttribute('list') ? 'combobox' : 'textbox';
      case 'h1': case 'h2': case 'h3': case 'h4': case 'h5': case 'h6': return 'heading';
      case 'nav': return 'navigation';
      case 'main': return 'main';
      case 'aside': return 'complementary';
      case 'header': return sectioned(el) ? '' : 'banner';
      case 'footer': return sectioned(el) ? '' : 'contentinfo';
      case 'form': return 'form';
      case 'search': return 'search';
      case 'section': return el.hasAttribute('aria-label') || el.hasAttribute('aria-labelledby') ? 'region' : '';
      case 'dialog': return 'dialog';
      case 'p': case 'blockquote': case 'pre': return 'paragraph';
      case 'li': return 'listitem';
      case 'td': return 'cell';
      case 'th': return 'columnheader';
      case 'table': return 'table';
      case 'img': return clean(el.getAttribute('alt'), 1) ? 'img' : '';
      case 'iframe': case 'frame': return 'iframe';
      default:
        if (el.isContentEditable && !(el.parentElement && el.parentElement.isContentEditable)) return 'textbox';
        return clickable(el) ? 'clickable' : '';
    }
  }

  function referenced(el, attribute) {
    const value = el.getAttribute(attribute);
    if (!value) return '';
    const root = el.getRootNode();
    return value.split(/\s+/).map((id) => {
      const target = root.getElementById ? root.getElementById(id) : document.getElementById(id);
      return target ? target.innerText || target.textContent : '';
    }).join(' ');
  }

  function textOf(node) {
    if (node.nodeType === Node.TEXT_NODE) return node.textContent;
    if (node.nodeType !== Node.ELEMENT_NODE) return '';
    if (['select', 'textarea', 'input', 'button', 'option', 'script', 'style'].includes(tagOf(node))) return '';
    if (node.hidden || node.getAttribute('aria-hidden') === 'true') return '';
    return Array.from(node.childNodes, textOf).join(' ');
  }

  function nameOf(el, role) {
    const tag = tagOf(el);
    const labelled = clean(referenced(el, 'aria-labelledby'), 200);
    if (labelled) return labelled;
    const aria = clean(el.getAttribute('aria-label'), 200);
    if (aria) return aria;
    if (tag === 'input' || tag === 'select' || tag === 'textarea') {
      const type = typeOf(el);
      if (['button', 'submit', 'reset'].includes(type)) {
        return clean(el.value, 200) || (type === 'submit' ? 'Submit' : type === 'reset' ? 'Reset' : '');
      }
      if (type === 'image') return clean(el.getAttribute('alt') || el.value || el.title, 200);
      const labels = el.labels ? Array.from(el.labels, textOf).join(' ') : '';
      return clean(labels, 200) || clean(el.getAttribute('placeholder'), 200) || clean(el.title, 200);
    }
    if (tag === 'img') return clean(el.getAttribute('alt'), 200);
    if (tag === 'iframe' || tag === 'frame') return clean(el.title || el.getAttribute('name'), 200);
    if (tag === 'fieldset') {
      const legend = el.querySelector('legend');
      if (legend) return clean(legend.innerText, 200);
    }
    if (tag === 'table' && el.caption) return clean(el.caption.innerText, 200);
    if (NAME_FROM_CONTENT.has(role)) {
      const text = clean(el.innerText, 200);
      if (text) return text;
      const image = el.querySelector('img[alt]');
      if (image) return clean(image.getAttribute('alt'), 200);
    }
    return clean(el.title, 200);
  }

  function valueOf(el) {
    const tag = tagOf(el);
    if (tag === 'select') {
      const option = el.selectedOptions && el.selectedOptions[0];
      return option ? option.label || option.text : '';
    }
    if (tag === 'input' || tag === 'textarea') return el.value;
    return el.innerText;
  }

  function states(el, role) {
    const out = [];
    if (el.disabled || el.getAttribute('aria-disabled') === 'true') out.push('disabled');
    if (role === 'checkbox' || role === 'radio' || role === 'switch' || role === 'menuitemcheckbox') {
      const aria = el.getAttribute('aria-checked');
      const checked = aria !== null ? aria === 'true' : !!el.checked;
      out.push(checked ? 'checked' : 'unchecked');
    }
    const expanded = el.getAttribute('aria-expanded');
    if (expanded === 'true') out.push('expanded');
    if (expanded === 'false') out.push('collapsed');
    if (el.getAttribute('aria-selected') === 'true' || (tagOf(el) === 'option' && el.selected)) out.push('selected');
    if (el.required || el.getAttribute('aria-required') === 'true') out.push('required');
    if (el.readOnly || el.getAttribute('aria-readonly') === 'true') out.push('readonly');
    if (el.getAttribute('aria-invalid') === 'true') out.push('invalid');
    if (deepActive() === el) out.push('focused');
    return out;
  }

  function lineFor(el, role) {
    const parts = [role];
    const name = nameOf(el, role);
    if (name) parts.push(JSON.stringify(name));
    if (role === 'heading') {
      const level = Number(el.getAttribute('aria-level')) || Number(tagOf(el).slice(1)) || 2;
      parts.push('level=' + level);
    }
    if (['textbox', 'searchbox', 'combobox', 'spinbutton', 'slider', 'listbox'].includes(role)) {
      parts.push('value=' + (isSecret(el) ? RULES.redacted : JSON.stringify(clean(valueOf(el), 200))));
      if (tagOf(el) === 'select') {
        const options = Array.from(el.options).slice(0, 20).map((option) => clean(option.label || option.text, 40));
        parts.push('options=' + JSON.stringify(options.join('|')));
      }
    }
    if (role === 'link' && el.href) parts.push('href=' + JSON.stringify(String(el.href).slice(0, 200)));
    return parts.concat(states(el, role)).join(' ');
  }

  function directText(el) {
    let text = '';
    for (const child of el.childNodes) {
      if (child.nodeType === Node.TEXT_NODE) text += child.textContent;
    }
    return clean(text, 300);
  }

  function snapshot(args) {
    const mode = args.mode === 'all' ? 'all' : 'interactive';
    const budget = Math.max(1, Math.min(60000, Number(args.max_chars) || 60000));
    let root = document.body || document.documentElement;
    if (args.scope) {
      root = resolve(args.scope_snapshot, args.scope);
      if (!root) return { error: 'stale_ref' };
    }
    const nodes = [];
    const listed = new Set();
    let used = 0;
    let truncated = false;
    const emit = (el, line) => {
      const cost = line.length + 10;
      if (used + cost > budget) {
        truncated = true;
        return false;
      }
      used += cost;
      const id = localId(el);
      listed.add(id);
      nodes.push({ id, line });
      return true;
    };
    const visit = (node, covered, depth) => {
      if (truncated || depth > 400 || node.nodeType !== Node.ELEMENT_NODE) return;
      const el = node;
      const tag = tagOf(el);
      if (SKIP.has(tag) || !shown(el)) return;
      const role = roleOf(el);
      let inner = covered;
      const wanted = role && (INTERACTIVE.has(role) || LANDMARKS.has(role) || role === 'heading'
        || role === 'iframe' || (mode === 'all' && STRUCTURE.has(role)));
      if (wanted && (role !== 'clickable' || nameOf(el, role))) {
        if (!emit(el, lineFor(el, role))) return;
        if (COVERS.has(role)) inner = true;
      } else if (mode === 'all' && !covered) {
        const text = directText(el);
        if (text && !emit(el, 'text ' + JSON.stringify(text))) return;
      }
      if (isSecret(el)) return;
      if (tag === 'select' || tag === 'textarea' || tag === 'iframe' || tag === 'frame') return;
      if (el.shadowRoot) for (const child of el.shadowRoot.children) visit(child, inner, depth + 1);
      for (const child of el.children) visit(child, inner, depth + 1);
    };
    if (root) visit(root, false, 0);
    remember(args.snapshot, listed);
    return { token, url: String(location.href), title: document.title, nodes, truncated };
  }

  function describe(el) {
    const form = formOf(el);
    return {
      tag: tagOf(el), type: typeOf(el), role: String(el.getAttribute('role') || ''),
      name_attr: String(el.getAttribute('name') || ''), id_attr: String(el.id || ''),
      autocomplete: String(el.getAttribute('autocomplete') || ''), label: nameOf(el, roleOf(el) || 'button'),
      text: clean(el.innerText || el.textContent, 200), in_form: !!form, form_has_secret: formHasSecret(form),
      editable: !!el.isContentEditable && !['input', 'textarea', 'select'].includes(tagOf(el)),
      line: lineFor(el, roleOf(el) || 'generic'), secret: isSecret(el),
    };
  }

  function deepActive() {
    let active = document.activeElement;
    while (active && active.shadowRoot && active.shadowRoot.activeElement) active = active.shadowRoot.activeElement;
    return active;
  }

  function frameOffset() {
    let x = 0;
    let y = 0;
    let view = window;
    try {
      while (view !== view.top) {
        const frame = view.frameElement;
        if (!frame) return null;
        const rect = frame.getBoundingClientRect();
        x += rect.left + frame.clientLeft;
        y += rect.top + frame.clientTop;
        view = view.parent;
      }
    } catch (error) {
      return null;
    }
    return { x, y };
  }

  function geometryOf(el) {
    const rect = el.getBoundingClientRect();
    const cx = rect.left + rect.width / 2;
    const cy = rect.top + rect.height / 2;
    const hit = document.elementFromPoint(cx, cy);
    return {
      x: rect.left, y: rect.top, width: rect.width, height: rect.height,
      viewport_width: innerWidth, viewport_height: innerHeight, offset: frameOffset(),
      obscured: !(hit && (hit === el || el.contains(hit))),
    };
  }

  function focusable(el) {
    return typeof el.focus === 'function' && (el.tabIndex >= 0 || el.isContentEditable);
  }

  function observe(el) {
    let changed = false;
    const observer = new MutationObserver(() => { changed = true; });
    observer.observe(document, { subtree: true, childList: true, attributes: true, characterData: true });
    const state = () => [el.checked, el.value, el.selectedIndex, el.open, deepActive(), String(location.href),
      scrollX, scrollY, document.querySelectorAll('dialog[open]').length];
    const start = state();
    const mark = () => { changed = true; };
    const events = ['beforeunload', 'hashchange', 'popstate', 'pagehide', 'submit'];
    for (const name of events) addEventListener(name, mark, true);
    return () => {
      observer.disconnect();
      for (const name of events) removeEventListener(name, mark, true);
      const end = state();
      return changed || end.some((value, index) => value !== start[index]);
    };
  }

  function pointer(el, kind, init) {
    const Type = kind.startsWith('pointer') && typeof PointerEvent === 'function' ? PointerEvent : MouseEvent;
    return el.dispatchEvent(new Type(kind, init));
  }

  function click(args) {
    const el = resolve(args.snapshot, args.id);
    if (!el) return { error: 'stale_ref' };
    if (el.disabled || el.getAttribute('aria-disabled') === 'true') return { error: 'disabled' };
    el.scrollIntoView({ block: 'center', inline: 'center', behavior: 'instant' });
    if (focusable(el)) el.focus({ preventScroll: true });
    const geometry = geometryOf(el);
    const finish = observe(el);
    const right = args.button === 'right';
    const count = Math.max(1, Math.min(2, Number(args.count) || 1));
    const base = {
      bubbles: true, cancelable: true, composed: true, view: window, button: right ? 2 : 0,
      clientX: geometry.x + geometry.width / 2, clientY: geometry.y + geometry.height / 2, isPrimary: true,
      pointerId: 1, pointerType: 'mouse',
    };
    for (let index = 1; index <= count; index++) {
      const init = Object.assign({}, base, { detail: index });
      pointer(el, 'pointerdown', Object.assign({}, init, { buttons: right ? 2 : 1 }));
      pointer(el, 'mousedown', Object.assign({}, init, { buttons: right ? 2 : 1 }));
      pointer(el, 'pointerup', init);
      pointer(el, 'mouseup', init);
      if (right) {
        pointer(el, 'contextmenu', init);
      } else {
        el.click();
      }
    }
    if (count === 2 && !right) pointer(el, 'dblclick', Object.assign({}, base, { detail: 2 }));
    const observation = nextObservation++;
    observations.set(observation, finish);
    while (observations.size > 8) {
      const oldest = observations.keys().next().value;
      observations.get(oldest)();
      observations.delete(oldest);
    }
    return { observation, geometry };
  }

  function settle(args) {
    const finish = observations.get(Number(args.observation));
    if (!finish) return { effect: true };
    observations.delete(Number(args.observation));
    return { effect: finish() };
  }

  function setNative(el, value) {
    const prototype = tagOf(el) === 'textarea' ? HTMLTextAreaElement.prototype : HTMLInputElement.prototype;
    const descriptor = Object.getOwnPropertyDescriptor(prototype, 'value');
    if (descriptor && descriptor.set) descriptor.set.call(el, value);
    else el.value = value;
  }

  function changed(el, data, inputType) {
    el.dispatchEvent(new InputEvent('input', { bubbles: true, composed: true, data, inputType }));
    el.dispatchEvent(new Event('change', { bubbles: true }));
  }

  function fill(args) {
    const el = resolve(args.snapshot, args.id);
    if (!el) return { error: 'stale_ref' };
    if (isSecret(el)) return { error: 'secret_field' };
    if (el.disabled || el.readOnly) return { error: 'disabled' };
    const value = String(args.value);
    const tag = tagOf(el);
    const type = typeOf(el);
    el.scrollIntoView({ block: 'center', behavior: 'instant' });
    if (typeof el.focus === 'function') el.focus({ preventScroll: true });
    if (tag === 'select') {
      const wanted = value.trim().toLowerCase();
      const options = Array.from(el.options);
      const option = options.find((item) => item.value === value)
        || options.find((item) => clean(item.label || item.text, 1000).toLowerCase() === wanted)
        || options.find((item) => clean(item.label || item.text, 1000).toLowerCase().includes(wanted));
      if (!option || option.disabled) return { error: 'no_option' };
      el.value = option.value;
      option.selected = true;
      changed(el, null, 'insertReplacementText');
      return { ok: true, value: clean(option.label || option.text, 200) };
    }
    if (tag === 'input' && (type === 'checkbox' || type === 'radio')) {
      const wanted = /^(true|on|yes|checked|1)$/i.test(value.trim());
      if (el.checked !== wanted) el.click();
      return { ok: true, checked: el.checked };
    }
    if (tag === 'input' && type === 'file') return { error: 'upload_blocked' };
    if (tag === 'input' && !TEXT_TYPES.has(type) && type !== 'range' && type !== 'color') {
      return { error: 'not_fillable' };
    }
    if (tag === 'input' || tag === 'textarea') {
      setNative(el, value);
      changed(el, value, 'insertText');
      return { ok: true };
    }
    if (el.isContentEditable) {
      const selection = getSelection();
      selection.selectAllChildren(el);
      if (!document.execCommand('insertText', false, value) || clean(el.innerText, 100000) !== clean(value, 100000)) {
        el.textContent = value;
        changed(el, value, 'insertText');
      }
      return { ok: true };
    }
    return { error: 'not_fillable' };
  }

  const KEYS = {
    enter: ['Enter', 'Enter'], escape: ['Escape', 'Escape'], space: [' ', 'Space'], tab: ['Tab', 'Tab'],
    backspace: ['Backspace', 'Backspace'], delete: ['Delete', 'Delete'], up: ['ArrowUp', 'ArrowUp'],
    down: ['ArrowDown', 'ArrowDown'], left: ['ArrowLeft', 'ArrowLeft'], right: ['ArrowRight', 'ArrowRight'],
    home: ['Home', 'Home'], end: ['End', 'End'], pageup: ['PageUp', 'PageUp'], pagedown: ['PageDown', 'PageDown'],
  };

  function keyInfo(name, shift) {
    if (KEYS[name]) return { key: KEYS[name][0], code: KEYS[name][1], printable: name === 'space' ? ' ' : null };
    if (/^f([1-9]|1[0-2])$/.test(name)) return { key: name.toUpperCase(), code: name.toUpperCase(), printable: null };
    if (/^[a-z]$/.test(name)) {
      const key = shift ? name.toUpperCase() : name;
      return { key, code: 'Key' + name.toUpperCase(), printable: key };
    }
    if (/^[0-9]$/.test(name)) return { key: name, code: 'Digit' + name, printable: name };
    if (name.length === 1) return { key: name, code: '', printable: name };
    return { key: name, code: '', printable: null };
  }

  function textControl(el) {
    if (!el) return false;
    const tag = tagOf(el);
    if (tag === 'textarea') return true;
    if (tag === 'input') return TEXT_TYPES.has(typeOf(el));
    return !!el.isContentEditable;
  }

  function insert(el, text) {
    if (document.execCommand('insertText', false, text)) return true;
    if (tagOf(el) !== 'input' && tagOf(el) !== 'textarea') return false;
    let start = null;
    let end = null;
    try {
      start = el.selectionStart;
      end = el.selectionEnd;
    } catch (error) {}
    const current = String(el.value);
    const from = start === null ? current.length : start;
    const to = end === null ? current.length : end;
    setNative(el, current.slice(0, from) + text + current.slice(to));
    try { el.setSelectionRange(from + text.length, from + text.length); } catch (error) {}
    el.dispatchEvent(new InputEvent('input', { bubbles: true, composed: true, data: text, inputType: 'insertText' }));
    return true;
  }

  function tabbables() {
    const candidates = Array.from(document.querySelectorAll(
      'a[href], button, input, select, textarea, summary, [tabindex], [contenteditable=""], [contenteditable="true"]'));
    const usable = candidates.filter((el) => el.tabIndex >= 0 && !el.disabled && typeOf(el) !== 'hidden' && shown(el));
    const positive = usable.filter((el) => el.tabIndex > 0).sort((a, b) => a.tabIndex - b.tabIndex);
    return positive.concat(usable.filter((el) => el.tabIndex === 0));
  }

  function moveFocus(from, backwards) {
    const order = tabbables();
    if (!order.length) return 'none';
    const index = order.indexOf(from);
    const next = index < 0 ? (backwards ? order.length - 1 : 0)
      : (index + (backwards ? order.length - 1 : 1)) % order.length;
    order[next].focus();
    return 'focus_moved';
  }

  function scrollWindow(dx, dy) {
    scrollBy({ left: dx, top: dy, behavior: 'instant' });
    return 'scrolled';
  }

  function activate(el) {
    const role = roleOf(el);
    return ['button', 'link', 'checkbox', 'radio', 'switch', 'tab', 'menuitem', 'option', 'clickable'].includes(role)
      || tagOf(el) === 'summary';
  }

  function defaultAction(el, name, info, modifiers) {
    const command = modifiers.cmd || modifiers.ctrl;
    if (command && name === 'a') {
      if (textControl(el) && typeof el.select === 'function') el.select();
      else getSelection().selectAllChildren(textControl(el) ? el : document.body);
      return 'selected';
    }
    if (command || modifiers.alt) return 'none';
    if (name === 'tab') return moveFocus(el, modifiers.shift);
    if (textControl(el)) {
      const multiline = tagOf(el) === 'textarea' || el.isContentEditable;
      if (name === 'enter') {
        if (multiline) return insert(el, '\n') ? 'inserted' : 'none';
        const form = formOf(el);
        if (!form) return 'none';
        if (typeof form.requestSubmit === 'function') form.requestSubmit();
        else form.submit();
        return 'submitted';
      }
      if (info.printable !== null) return insert(el, info.printable) ? 'inserted' : 'none';
      if (name === 'backspace') return document.execCommand('delete') ? 'deleted' : 'none';
      if (name === 'delete') return document.execCommand('forwardDelete') ? 'deleted' : 'none';
      if (['left', 'right', 'home', 'end'].includes(name) && typeof el.setSelectionRange === 'function') {
        try {
          const length = String(el.value).length;
          const at = el.selectionStart === null ? length : el.selectionStart;
          const target = name === 'home' ? 0 : name === 'end' ? length
            : Math.max(0, Math.min(length, at + (name === 'left' ? -1 : 1)));
          el.setSelectionRange(target, target);
          return 'moved';
        } catch (error) {
          return 'none';
        }
      }
      return 'none';
    }
    if (tagOf(el) === 'select' && (name === 'up' || name === 'down')) {
      const next = Math.max(0, Math.min(el.options.length - 1, el.selectedIndex + (name === 'up' ? -1 : 1)));
      if (next !== el.selectedIndex) {
        el.selectedIndex = next;
        changed(el, null, 'insertReplacementText');
        return 'changed';
      }
      return 'none';
    }
    if ((name === 'enter' || name === 'space') && el !== document.body && activate(el)) {
      if (name === 'enter' && ['checkbox', 'radio'].includes(roleOf(el))) return 'none';
      el.click();
      return 'clicked';
    }
    const page = innerHeight * 0.9;
    switch (name) {
      case 'space': return scrollWindow(0, modifiers.shift ? -page : page);
      case 'up': return scrollWindow(0, -40);
      case 'down': return scrollWindow(0, 40);
      case 'left': return scrollWindow(-40, 0);
      case 'right': return scrollWindow(40, 0);
      case 'pageup': return scrollWindow(0, -page);
      case 'pagedown': return scrollWindow(0, page);
      case 'home': scrollTo({ top: 0, behavior: 'instant' }); return 'scrolled';
      case 'end': scrollTo({ top: document.documentElement.scrollHeight, behavior: 'instant' }); return 'scrolled';
      case 'escape': {
        const dialog = Array.from(document.querySelectorAll('dialog[open]')).pop();
        if (dialog && dialog.matches(':modal')) {
          dialog.close();
          return 'closed';
        }
        return 'none';
      }
      default: return 'none';
    }
  }

  function targetOf(args) {
    if (args.id) return resolve(args.snapshot, args.id);
    return deepActive() || document.body;
  }

  function focusTarget(args) {
    const el = targetOf(args);
    if (!el) return { error: 'stale_ref' };
    return Object.assign(describe(el), { focused: el === deepActive() });
  }

  function press(args) {
    const el = targetOf(args);
    if (!el) return { error: 'stale_ref' };
    if (args.id) {
      el.scrollIntoView({ block: 'center', behavior: 'instant' });
      if (typeof el.focus === 'function') el.focus({ preventScroll: true });
    }
    const modifiers = { cmd: !!args.cmd, ctrl: !!args.ctrl, alt: !!args.alt, shift: !!args.shift };
    const info = keyInfo(String(args.key), modifiers.shift);
    const init = {
      key: info.key, code: info.code, bubbles: true, cancelable: true, composed: true, view: window,
      shiftKey: modifiers.shift, ctrlKey: modifiers.ctrl, altKey: modifiers.alt, metaKey: modifiers.cmd,
    };
    let action = 'prevented';
    if (el.dispatchEvent(new KeyboardEvent('keydown', init))) {
      const printable = info.printable !== null && !modifiers.cmd && !modifiers.ctrl && !modifiers.alt;
      if (!printable || el.dispatchEvent(new KeyboardEvent('keypress', init))) {
        action = defaultAction(el, String(args.key), info, modifiers);
      }
    }
    el.dispatchEvent(new KeyboardEvent('keyup', init));
    return { action };
  }

  function scrollable(el) {
    let current = el;
    while (current && current !== document.body && current !== document.documentElement) {
      const style = getComputedStyle(current);
      if (/(auto|scroll|overlay)/.test(style.overflowY) && current.scrollHeight > current.clientHeight) return current;
      current = current.parentElement;
    }
    return null;
  }

  function scroll(args) {
    let container = null;
    if (args.id) {
      const el = resolve(args.snapshot, args.id);
      if (!el) return { error: 'stale_ref' };
      container = scrollable(el);
    }
    const dy = Number(args.dy) || 0;
    if (container) {
      container.scrollBy({ top: dy, behavior: 'instant' });
      return {
        target: 'element', scroll_top: container.scrollTop, scroll_height: container.scrollHeight,
        client_height: container.clientHeight,
      };
    }
    scrollBy({ top: dy, behavior: 'instant' });
    const page = document.scrollingElement || document.documentElement;
    return { target: 'window', scroll_top: scrollY, scroll_height: page.scrollHeight, client_height: innerHeight };
  }

  function redactEditable(text) {
    let out = text;
    for (const el of document.querySelectorAll('[contenteditable]')) {
      const value = el.isContentEditable && isSecret(el) ? String(el.innerText || '') : '';
      if (value.trim()) out = out.split(value).join(RULES.redacted);
    }
    return out;
  }

  function text(args) {
    const limit = Math.max(1, Math.min(60000, Number(args.max_chars) || 60000));
    let raw = '';
    if (args.id) {
      const el = resolve(args.snapshot, args.id);
      if (!el) return { error: 'stale_ref' };
      if (isSecret(el)) return { error: 'secret_field' };
      raw = ['input', 'textarea'].includes(tagOf(el)) ? String(el.value) : String(el.innerText || '');
    } else {
      raw = String((document.body || document.documentElement).innerText || '');
    }
    raw = redactEditable(raw);
    return { text: raw.slice(0, limit), truncated: raw.length > limit };
  }

  function geometry(args) {
    const el = resolve(args.snapshot, args.id);
    if (!el) return { error: 'stale_ref' };
    if (args.reveal) el.scrollIntoView({ block: 'center', inline: 'center', behavior: 'instant' });
    return geometryOf(el);
  }

  function probe(args) {
    const el = resolve(args.snapshot, args.id);
    if (!el) return { exists: false, visible: false, enabled: false };
    const rect = el.getBoundingClientRect();
    return {
      exists: true, visible: shown(el) && rect.width > 0 && rect.height > 0,
      enabled: !(el.disabled || el.getAttribute('aria-disabled') === 'true'),
    };
  }

  function contains(args) {
    const body = document.body || document.documentElement;
    return { matched: !!body && String(body.innerText || '').includes(String(args.text)) };
  }

  function secretRects() {
    const offset = frameOffset();
    const rects = [];
    for (const el of document.querySelectorAll('input, textarea, select, [contenteditable]')) {
      if (!isSecret(el) || !shown(el)) continue;
      const rect = el.getBoundingClientRect();
      if (rect.width > 0 && rect.height > 0) {
        rects.push({ x: rect.left, y: rect.top, width: rect.width, height: rect.height });
      }
      if (rects.length >= 64) break;
    }
    const frames = Array.from(document.querySelectorAll('iframe, frame')).slice(0, 64).map((el) => {
      const rect = el.getBoundingClientRect();
      return { x: rect.left, y: rect.top, width: rect.width, height: rect.height };
    });
    return { rects, offset, frames };
  }

  function state() {
    return { token, ready: document.readyState, url: String(location.href), title: document.title };
  }

  Object.defineProperty(globalThis, '__astralBrowser', {
    value: Object.freeze({
      token: () => token, snapshot, describe: (args) => {
        const el = resolve(args.snapshot, args.id);
        return el ? describe(el) : { error: 'stale_ref' };
      }, focusTarget, click, settle, fill, press, scroll, text, geometry, probe, contains, state, secretRects,
    }),
    configurable: false, enumerable: false, writable: false,
  });
})();
