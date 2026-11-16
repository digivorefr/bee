import Foundation

/// The JavaScript half of the scripting engine: the `bee` / `pm` API, a chai-style `expect`, `console`,
/// timers and `sendRequest`. It is evaluated once per context and talks to Swift only through the
/// `__host` object, which it captures and then removes from the global scope. The expression result is
/// the set of entry points the Swift run loop drives.
enum ScriptPrelude {
    static let sourceURL = "bee-prelude"

    static let source = #"""
(function () {
  'use strict';

  const host = globalThis.__host;
  delete globalThis.__host;
  const init = host.init();
  const hasOwn = Object.prototype.hasOwnProperty;
  const responses = new WeakSet();

  // ---------------------------------------------------------------------------------------------
  // Helpers
  // ---------------------------------------------------------------------------------------------

  function setOwn(target, key, value) {
    Object.defineProperty(target, key, { value: value, enumerable: true, writable: true, configurable: true });
  }

  function messageOf(error) {
    if (error !== null && typeof error === 'object' && typeof error.message === 'string' && error.message !== '') {
      return error.message;
    }
    return String(error);
  }

  /** Variables are stored as strings: strings as-is, objects through JSON, the rest through String(). */
  function toStored(value) {
    if (typeof value === 'string') return value;
    if (value !== null && typeof value === 'object') {
      const json = JSON.stringify(value);
      return json === undefined ? String(value) : json;
    }
    return String(value);
  }

  function typeOf(value) {
    if (value === null) return 'null';
    if (value === undefined) return 'undefined';
    if (Array.isArray(value)) return 'array';
    const tag = Object.prototype.toString.call(value).slice(8, -1).toLowerCase();
    return tag.endsWith('function') ? 'function' : tag;
  }

  function inspectValue(value, seen) {
    switch (typeof value) {
      case 'string': return "'" + value + "'";
      case 'number': return Object.is(value, -0) ? '-0' : String(value);
      case 'bigint': return String(value) + 'n';
      case 'symbol': return value.toString();
      case 'function': return '[Function' + (value.name ? ': ' + value.name : '') + ']';
      case 'undefined': return 'undefined';
      case 'boolean': return String(value);
      default: break;
    }
    if (value === null) return 'null';
    if (responses.has(value)) return '[Response ' + value.code + ']';
    if (value instanceof Error) return '[' + (value.name || 'Error') + (value.message ? ': ' + value.message : '') + ']';
    if (value instanceof Date) return isNaN(value) ? 'Invalid Date' : value.toISOString();
    if (value instanceof RegExp) return String(value);
    seen = seen || [];
    if (seen.indexOf(value) !== -1) return '[Circular]';
    seen.push(value);
    let result;
    if (Array.isArray(value)) {
      result = value.length === 0 ? '[]' : '[ ' + value.map(function (item) { return inspectValue(item, seen); }).join(', ') + ' ]';
    } else {
      const keys = Object.keys(value);
      result = keys.length === 0 ? '{}' : '{ ' + keys.map(function (key) {
        return (/^[A-Za-z_$][\w$]*$/.test(key) ? key : "'" + key + "'") + ': ' + inspectValue(value[key], seen);
      }).join(', ') + ' }';
    }
    seen.pop();
    return result;
  }

  function describe(value) {
    const text = inspectValue(value);
    return text.length > 200 ? text.slice(0, 200) + '...' : text;
  }

  function deepEqual(a, b, seen) {
    if (a === b) return true;
    if (a !== a && b !== b) return true;
    if (a === null || b === null || typeof a !== 'object' || typeof b !== 'object') return false;
    const tag = Object.prototype.toString.call(a);
    if (tag !== Object.prototype.toString.call(b)) return false;
    seen = seen || [];
    for (let i = 0; i < seen.length; i++) {
      if (seen[i][0] === a && seen[i][1] === b) return true;
    }
    seen.push([a, b]);
    let equal;
    if (a instanceof Date) {
      equal = a.getTime() === b.getTime();
    } else if (a instanceof RegExp) {
      equal = String(a) === String(b);
    } else if (Array.isArray(a)) {
      equal = a.length === b.length && a.every(function (item, index) { return deepEqual(item, b[index], seen); });
    } else if (a instanceof Set) {
      equal = a.size === b.size && Array.from(a).every(function (item) {
        return b.has(item) || Array.from(b).some(function (other) { return deepEqual(item, other, seen); });
      });
    } else if (a instanceof Map) {
      equal = a.size === b.size && Array.from(a).every(function (entry) {
        return b.has(entry[0]) && deepEqual(entry[1], b.get(entry[0]), seen);
      });
    } else {
      const keysA = Object.keys(a);
      const keysB = Object.keys(b);
      equal = keysA.length === keysB.length && keysA.every(function (key) {
        return hasOwn.call(b, key) && deepEqual(a[key], b[key], seen);
      });
    }
    seen.pop();
    return equal;
  }

  // ---------------------------------------------------------------------------------------------
  // Assertions (a chai-style BDD subset)
  // ---------------------------------------------------------------------------------------------

  class AssertionError extends Error {
    constructor(message) {
      super(message);
      this.name = 'AssertionError';
    }
  }

  class Assertion {
    constructor(object, message) {
      this._object = object;
      this._message = message;
      this._negate = false;
      this._deep = false;
      this._any = false;
    }

    _assert(passed, phrase, detail, subject) {
      if (passed !== this._negate) return;
      const text = 'expected ' + (subject === undefined ? describe(this._object) : subject) +
        ' to ' + (this._negate ? 'not ' : '') + phrase + (this._negate || !detail ? '' : detail);
      throw new AssertionError(this._message ? this._message + ': ' + text : text);
    }

    _response(method) {
      if (!responses.has(this._object)) {
        throw new Error(method + '() is only available when the target is a response');
      }
      return this._object;
    }

    _same(a, b) {
      return this._deep ? deepEqual(a, b) : a === b;
    }

    _number(method) {
      const type = typeof this._object;
      if (type !== 'number' && type !== 'bigint') {
        throw new AssertionError('expected ' + describe(this._object) + ' to be a number to use ' + method + '()');
      }
      return this._object;
    }

    equal(expected) {
      this._assert(this._same(this._object, expected), (this._deep ? 'deeply ' : '') + 'equal ' + describe(expected));
      return this;
    }

    eql(expected) {
      this._assert(deepEqual(this._object, expected), 'deeply equal ' + describe(expected));
      return this;
    }

    a(type) {
      if (typeof type === 'function') return this.instanceof(type);
      const expected = String(type).toLowerCase();
      this._assert(typeOf(this._object) === expected, 'be ' + (/^[aeiou]/.test(expected) ? 'an ' : 'a ') + expected);
      return this;
    }

    instanceof(constructor) {
      this._assert(this._object instanceof constructor, 'be an instance of ' + (constructor && constructor.name));
      return this;
    }

    above(limit) {
      this._assert(this._number('above') > limit, 'be above ' + describe(limit));
      return this;
    }

    least(limit) {
      this._assert(this._number('least') >= limit, 'be at least ' + describe(limit));
      return this;
    }

    below(limit) {
      this._assert(this._number('below') < limit, 'be below ' + describe(limit));
      return this;
    }

    most(limit) {
      this._assert(this._number('most') <= limit, 'be at most ' + describe(limit));
      return this;
    }

    within(start, finish) {
      const value = this._number('within');
      this._assert(value >= start && value <= finish, 'be within ' + describe(start) + '..' + describe(finish));
      return this;
    }

    include(value) {
      const target = this._object;
      let found = false;
      if (typeof target === 'string') {
        found = target.indexOf(String(value)) !== -1;
      } else if (Array.isArray(target)) {
        found = target.some((item) => this._same(item, value));
      } else if (target instanceof Set) {
        found = Array.from(target).some((item) => this._same(item, value));
      } else if (target !== null && typeof target === 'object' && value !== null && typeof value === 'object') {
        found = Object.keys(value).every((key) => key in target && this._same(target[key], value[key]));
      }
      this._assert(found, 'include ' + describe(value));
      return this;
    }

    property(name, ...rest) {
      const target = this._object;
      const hasValue = rest.length > 0;
      const exists = target !== null && target !== undefined && name in Object(target);
      const actual = exists ? target[name] : undefined;
      const passed = hasValue ? exists && this._same(actual, rest[0]) : exists;
      let phrase = 'have property ' + describe(name);
      let detail = '';
      if (hasValue) {
        phrase += ' of ' + describe(rest[0]);
        if (exists) detail = ', but got ' + describe(actual);
      }
      this._assert(passed, phrase, detail);
      if (!this._negate) this._object = actual;
      return this;
    }

    lengthOf(expected) {
      const target = this._object;
      let length;
      if (target !== null && target !== undefined) length = target.length !== undefined ? target.length : target.size;
      this._assert(length === expected, 'have a length of ' + describe(expected), ' but got ' + describe(length));
      return this;
    }

    match(pattern) {
      const target = this._object;
      let passed = false;
      if (pattern instanceof RegExp && (typeof target === 'string' || typeof target === 'number')) {
        pattern.lastIndex = 0;
        passed = pattern.test(String(target));
      }
      this._assert(passed, 'match ' + describe(pattern));
      return this;
    }

    oneOf(list) {
      this._assert(Array.isArray(list) && list.indexOf(this._object) !== -1, 'be one of ' + describe(list));
      return this;
    }

    keys(...args) {
      const target = this._object;
      let expected = args;
      if (args.length === 1 && Array.isArray(args[0])) {
        expected = args[0];
      } else if (args.length === 1 && args[0] !== null && typeof args[0] === 'object') {
        expected = Object.keys(args[0]);
      }
      let actual = [];
      if (target instanceof Map) {
        actual = Array.from(target.keys());
      } else if (target !== null && typeof target === 'object') {
        actual = Object.keys(target);
      }
      const passed = this._any
        ? expected.some((key) => actual.indexOf(key) !== -1)
        : expected.length === actual.length && expected.every((key) => actual.indexOf(key) !== -1);
      this._assert(passed, (this._any ? 'have any keys ' : 'have all keys ') + describe(expected));
      return this;
    }

    string(text) {
      this._assert(typeof this._object === 'string' && this._object.indexOf(String(text)) !== -1,
        'contain string ' + describe(text));
      return this;
    }

    status(expected) {
      const response = this._response('status');
      if (typeof expected === 'string') {
        this._assert(response.status === expected, 'have status ' + describe(expected),
          ' but got ' + describe(response.status), 'response');
      } else {
        this._assert(response.code === expected, 'have status code ' + describe(expected),
          ' but got ' + describe(response.code), 'response');
      }
      return this;
    }

    header(name, ...rest) {
      const response = this._response('header');
      const actual = response.headers.get(name);
      const hasValue = rest.length > 0;
      const passed = hasValue ? actual !== undefined && actual === String(rest[0]) : actual !== undefined;
      this._assert(passed,
        'have header ' + describe(String(name)) + (hasValue ? ' with value ' + describe(String(rest[0])) : ''),
        hasValue && actual !== undefined ? ' but got ' + describe(actual) : '', 'response');
      return this;
    }
  }

  const chainWords = ['to', 'be', 'been', 'is', 'that', 'which', 'and', 'has', 'have', 'with', 'at', 'of', 'same'];
  chainWords.forEach(function (word) {
    Object.defineProperty(Assertion.prototype, word, { get() { return this; }, configurable: true });
  });

  function defineFlag(name, apply) {
    Object.defineProperty(Assertion.prototype, name, { get() { apply(this); return this; }, configurable: true });
  }
  defineFlag('not', function (self) { self._negate = !self._negate; });
  defineFlag('deep', function (self) { self._deep = true; });
  defineFlag('any', function (self) { self._any = true; });
  defineFlag('all', function (self) { self._any = false; });

  defineFlag('ok', function (self) {
    if (responses.has(self._object)) {
      const code = self._object.code;
      self._assert(code >= 200 && code < 300, 'be ok (a 2xx status)', ' but got status code ' + code, 'response');
    } else {
      self._assert(Boolean(self._object), 'be truthy');
    }
  });
  defineFlag('true', function (self) { self._assert(self._object === true, 'be true'); });
  defineFlag('false', function (self) { self._assert(self._object === false, 'be false'); });
  defineFlag('null', function (self) { self._assert(self._object === null, 'be null'); });
  defineFlag('undefined', function (self) { self._assert(self._object === undefined, 'be undefined'); });
  defineFlag('exist', function (self) { self._assert(self._object !== null && self._object !== undefined, 'exist'); });
  defineFlag('empty', function (self) {
    const target = self._object;
    let empty;
    if (typeof target === 'string' || Array.isArray(target)) empty = target.length === 0;
    else if (target instanceof Map || target instanceof Set) empty = target.size === 0;
    else if (target !== null && typeof target === 'object') empty = Object.keys(target).length === 0;
    else throw new AssertionError('expected ' + describe(target) + ' to be a string, array or object to check emptiness');
    self._assert(empty, 'be empty');
  });

  const aliases = {
    equals: 'equal', eq: 'equal', eqls: 'eql', an: 'a', instanceOf: 'instanceof',
    gt: 'above', greaterThan: 'above', gte: 'least', lt: 'below', lessThan: 'below', lte: 'most',
    includes: 'include', contain: 'include', contains: 'include', length: 'lengthOf',
    matches: 'match', key: 'keys', exists: 'exist'
  };
  Object.keys(aliases).forEach(function (alias) {
    const original = Object.getOwnPropertyDescriptor(Assertion.prototype, aliases[alias]);
    Object.defineProperty(Assertion.prototype, alias, original);
  });

  function expect(value, message) {
    return new Assertion(value, message);
  }

  // ---------------------------------------------------------------------------------------------
  // Headers
  // ---------------------------------------------------------------------------------------------

  class HeaderList {
    constructor(pairs) {
      this._entries = pairs.map(function (pair) { return { name: String(pair[0]), value: String(pair[1]) }; });
    }

    _indexOf(name) {
      const lowered = String(name).toLowerCase();
      return this._entries.findIndex(function (entry) { return entry.name.toLowerCase() === lowered; });
    }

    get(name) {
      const index = this._indexOf(name);
      return index === -1 ? undefined : this._entries[index].value;
    }

    has(name) {
      return this._indexOf(name) !== -1;
    }

    toObject() {
      const result = {};
      const seen = new Set();
      this._entries.forEach(function (entry) {
        const lowered = entry.name.toLowerCase();
        if (seen.has(lowered)) return;
        seen.add(lowered);
        setOwn(result, entry.name, entry.value);
      });
      return result;
    }
  }

  function readHeader(header) {
    if (header === null || typeof header !== 'object') {
      throw new TypeError('A header must be an object like {key: "Name", value: "value"}');
    }
    const name = header.key !== undefined ? header.key : header.name;
    if (name === undefined || name === null || String(name) === '') {
      throw new TypeError('A header needs a non-empty key');
    }
    return { name: String(name), value: header.value === undefined || header.value === null ? '' : String(header.value) };
  }

  /** The request headers: mutable in the pre-request phase, silently read-only afterwards. */
  class RequestHeaderList extends HeaderList {
    constructor(pairs, writable, onChange) {
      super(pairs);
      this._writable = writable;
      this._onChange = onChange;
    }

    add(header) {
      const entry = readHeader(header);
      if (!this._writable) return;
      this._entries.push(entry);
      this._onChange();
    }

    upsert(header) {
      const entry = readHeader(header);
      if (!this._writable) return;
      const lowered = entry.name.toLowerCase();
      const index = this._indexOf(entry.name);
      if (index === -1) {
        this._entries.push(entry);
      } else {
        this._entries[index] = entry;
        this._entries = this._entries.filter(function (existing, position) {
          return position === index || existing.name.toLowerCase() !== lowered;
        });
      }
      this._onChange();
    }

    remove(name) {
      if (!this._writable) return;
      const lowered = String(name).toLowerCase();
      this._entries = this._entries.filter(function (entry) { return entry.name.toLowerCase() !== lowered; });
      this._onChange();
    }

    snapshot() {
      return this._entries.map(function (entry) { return [entry.name, entry.value]; });
    }
  }

  // ---------------------------------------------------------------------------------------------
  // Variables
  // ---------------------------------------------------------------------------------------------

  function secretOption(options) {
    if (options !== null && typeof options === 'object' && typeof options.secret === 'boolean') {
      return options.secret ? 1 : 0;
    }
    return -1;
  }

  function makeScope(scope) {
    const canWrite = scope !== 'environment' || init.environmentName !== undefined;
    function guard() {
      if (!canWrite) throw new Error('No active environment: select one before writing environment variables.');
    }
    const api = {
      get: function (name) {
        const value = host.scopeGet(scope, String(name));
        return value === null ? undefined : value;
      },
      set: function (name, value, options) {
        guard();
        host.scopeSet(scope, String(name), toStored(value), secretOption(options));
      },
      has: function (name) { return host.scopeHas(scope, String(name)); },
      unset: function (name) { guard(); host.scopeUnset(scope, String(name)); },
      clear: function () { guard(); host.scopeClear(scope); },
      toObject: function () {
        const result = {};
        host.scopeEntries(scope).forEach(function (pair) { setOwn(result, pair[0], pair[1]); });
        return result;
      }
    };
    if (scope === 'environment') {
      Object.defineProperty(api, 'name', { get: function () { return init.environmentName; }, enumerable: true });
    }
    return api;
  }

  const resolutionOrder = ['locals', 'environment', 'collection', 'globals'];

  function resolve(name) {
    for (let i = 0; i < resolutionOrder.length; i++) {
      const value = host.scopeGet(resolutionOrder[i], name);
      if (value !== null && value !== undefined) return value;
    }
    return undefined;
  }

  const variables = {
    get: function (name) { return resolve(String(name)); },
    has: function (name) { return resolve(String(name)) !== undefined; },
    set: function (name, value) { host.scopeSet('locals', String(name), toStored(value), -1); },
    unset: function (name) { host.scopeUnset('locals', String(name)); },
    replaceIn: function (text) {
      if (typeof text !== 'string') return text;
      return text.replace(/\{\{\s*([^{}]+?)\s*\}\}/g, function (placeholder, name) {
        const value = resolve(name);
        return value === undefined ? placeholder : value;
      });
    },
    toObject: function () {
      const result = {};
      resolutionOrder.slice().reverse().forEach(function (scope) {
        host.scopeEntries(scope).forEach(function (pair) { setOwn(result, pair[0], pair[1]); });
      });
      return result;
    }
  };

  // ---------------------------------------------------------------------------------------------
  // Request and response
  // ---------------------------------------------------------------------------------------------

  const writable = init.writable === true;
  let requestMethod = init.request.method;
  let requestUrl = init.request.url;
  let requestBody = init.request.body === undefined ? null : init.request.body;

  function syncRequest() {
    host.syncRequest(JSON.stringify({
      method: requestMethod, url: requestUrl, body: requestBody, headers: requestHeaders.snapshot()
    }));
  }

  const requestHeaders = new RequestHeaderList(init.request.headers, writable, syncRequest);
  const request = {};
  Object.defineProperties(request, {
    method: {
      enumerable: true,
      get: function () { return requestMethod; },
      set: function (value) { if (writable) { requestMethod = String(value).toUpperCase(); syncRequest(); } }
    },
    url: {
      enumerable: true,
      get: function () { return requestUrl; },
      set: function (value) { if (writable) { requestUrl = String(value); syncRequest(); } }
    },
    body: {
      enumerable: true,
      get: function () { return requestBody; },
      set: function (value) {
        if (!writable) return;
        requestBody = value === null || value === undefined ? null : toStored(value);
        syncRequest();
      }
    },
    headers: { enumerable: true, value: requestHeaders }
  });

  function makeResponse(data) {
    const headers = new HeaderList(data.headers);
    const response = {
      code: data.code,
      status: data.status,
      responseTime: data.responseTime,
      responseSize: data.size,
      headers: headers,
      text: function () { return data.text; },
      json: function () {
        try {
          return JSON.parse(data.text.charCodeAt(0) === 0xFEFF ? data.text.slice(1) : data.text);
        } catch (error) {
          throw new Error('Response body is not valid JSON');
        }
      }
    };
    Object.defineProperty(response, 'to', { get: function () { return new Assertion(response); } });
    responses.add(response);
    return response;
  }

  // ---------------------------------------------------------------------------------------------
  // Tests
  // ---------------------------------------------------------------------------------------------

  function test(name, fn) {
    const index = host.testBegin(String(name));
    function pass() { host.testEnd(index, true, null); }
    function fail(error) { host.testEnd(index, false, messageOf(error)); }
    try {
      if (typeof fn !== 'function') throw new TypeError('bee.test needs a function as its second argument');
      const result = fn();
      if (result !== null && result !== undefined && typeof result.then === 'function') {
        return Promise.resolve(result).then(pass, fail);
      }
      pass();
    } catch (error) {
      fail(error);
    }
    return Promise.resolve();
  }

  // ---------------------------------------------------------------------------------------------
  // Console
  // ---------------------------------------------------------------------------------------------

  function formatArgument(value) {
    if (typeof value === 'string') return value;
    if (value === undefined) return 'undefined';
    if (value === null) return 'null';
    if (value instanceof Error) return messageOf(value);
    if (typeof value === 'function') return '[Function' + (value.name ? ': ' + value.name : '') + ']';
    if (typeof value === 'symbol') return value.toString();
    if (typeof value === 'object') {
      if (value instanceof Date) return isNaN(value) ? 'Invalid Date' : value.toISOString();
      try {
        const json = JSON.stringify(value);
        if (json !== undefined) return json;
      } catch (error) {
        return inspectValue(value);
      }
      return String(value);
    }
    return String(value);
  }

  function makeConsole() {
    const result = {};
    [['log', 'log'], ['info', 'info'], ['warn', 'warn'], ['error', 'error'], ['debug', 'log']].forEach(function (pair) {
      result[pair[0]] = function () {
        host.console(pair[1], Array.prototype.map.call(arguments, formatArgument).join(' '));
      };
    });
    return result;
  }

  // ---------------------------------------------------------------------------------------------
  // Timers
  // ---------------------------------------------------------------------------------------------

  const timers = new Map();
  let nextTimerId = 1;

  function setTimeoutShim(callback, delay) {
    if (typeof callback !== 'function') throw new TypeError('setTimeout needs a function as its first argument');
    let milliseconds = Number(delay);
    if (!(milliseconds > 0)) milliseconds = 0;
    if (milliseconds > 2147483647) milliseconds = 2147483647;
    const id = nextTimerId++;
    timers.set(id, { callback: callback, args: Array.prototype.slice.call(arguments, 2) });
    host.timerSet(id, milliseconds);
    return id;
  }

  function clearTimeoutShim(id) {
    if (timers.delete(id)) host.timerClear(id);
  }

  function fireTimer(id) {
    const timer = timers.get(id);
    if (timer === undefined) return;
    timers.delete(id);
    timer.callback.apply(undefined, timer.args);
  }

  // ---------------------------------------------------------------------------------------------
  // sendRequest
  // ---------------------------------------------------------------------------------------------

  const pendingRequests = new Map();

  function formEncode(text) {
    return encodeURIComponent(text).replace(/%20/g, '+').replace(/[!'()~]/g, function (character) {
      return '%' + character.charCodeAt(0).toString(16).toUpperCase();
    });
  }

  function readHeaderOption(option) {
    if (option === undefined || option === null) return [];
    if (Array.isArray(option)) {
      return option.filter(function (item) { return !(item && item.disabled); }).map(function (item) {
        const header = readHeader(item);
        return [header.name, header.value];
      });
    }
    if (typeof option === 'object') {
      return Object.keys(option).map(function (key) { return [key, String(option[key])]; });
    }
    throw new TypeError('The header option must be an object or an array of {key, value}');
  }

  function describeRequest(input) {
    const options = typeof input === 'string' ? { url: input } : input;
    if (options === null || typeof options !== 'object') {
      throw new TypeError('bee.sendRequest expects a URL or an options object');
    }
    let url = options.url;
    if (url !== null && typeof url === 'object' && url.raw !== undefined) url = url.raw;
    if (url === undefined || url === null || String(url) === '') {
      throw new TypeError('bee.sendRequest requires a url');
    }
    const headers = readHeaderOption(options.header !== undefined ? options.header : options.headers);
    let body = null;
    const source = options.body;
    if (typeof source === 'string') {
      body = source;
    } else if (source !== undefined && source !== null) {
      if (typeof source !== 'object') throw new TypeError('The request body must be a string or an object with a mode');
      if (source.mode === 'raw') {
        body = source.raw === undefined || source.raw === null ? '' : String(source.raw);
      } else if (source.mode === 'urlencoded') {
        const fields = Array.isArray(source.urlencoded)
          ? source.urlencoded
          : Object.keys(source.urlencoded || {}).map(function (key) { return { key: key, value: source.urlencoded[key] }; });
        body = fields.filter(function (field) { return !(field && field.disabled); }).map(function (field) {
          const header = readHeader(field);
          return formEncode(header.name) + '=' + formEncode(header.value);
        }).join('&');
        const hasContentType = headers.some(function (pair) { return pair[0].toLowerCase() === 'content-type'; });
        if (!hasContentType) headers.push(['Content-Type', 'application/x-www-form-urlencoded']);
      } else {
        throw new TypeError("bee.sendRequest does not support the body mode '" + source.mode + "'");
      }
    }
    return { method: String(options.method || 'GET').toUpperCase(), url: String(url), headers: headers, body: body };
  }

  function sendRequest(input, callback) {
    const hasCallback = typeof callback === 'function';
    return new Promise(function (resolvePromise, rejectPromise) {
      let descriptor;
      try {
        descriptor = describeRequest(input);
      } catch (error) {
        descriptor = { error: messageOf(error) };
      }
      const id = host.sendRequest(JSON.stringify(descriptor));
      pendingRequests.set(id, { resolve: resolvePromise, reject: rejectPromise, callback: hasCallback ? callback : null });
    });
  }

  /** Called by the run loop when the transport finished; callback exceptions surface as uncaught errors. */
  function completeRequest(id, succeeded, payload) {
    const pending = pendingRequests.get(id);
    if (pending === undefined) return;
    pendingRequests.delete(id);
    const outcome = succeeded ? makeResponse(payload) : new Error(String(payload));
    if (pending.callback === null) {
      if (succeeded) pending.resolve(outcome);
      else pending.reject(outcome);
      return;
    }
    try {
      if (succeeded) pending.callback(null, outcome);
      else pending.callback(outcome, undefined);
    } finally {
      pending.resolve(undefined);
    }
  }

  // ---------------------------------------------------------------------------------------------
  // Source tracking and error reporting
  // ---------------------------------------------------------------------------------------------

  function trackSource(promise) {
    Promise.resolve(promise).then(
      function () { host.sourceSettled(true, undefined); },
      function (error) { host.sourceSettled(false, error); }
    );
  }

  /** The 1-based line of the first stack frame that belongs to the person's source. */
  function lineOf(error, url) {
    try {
      if (error !== null && typeof error === 'object') {
        if (typeof error.stack === 'string') {
          const needle = url + ':';
          const frames = error.stack.split('\n');
          for (let i = 0; i < frames.length; i++) {
            const at = frames[i].indexOf(needle);
            if (at !== -1) {
              const match = /^(\d+)/.exec(frames[i].slice(at + needle.length));
              if (match) return Number(match[1]);
            }
          }
        }
        if (typeof error.line === 'number' && error.sourceURL === url) return error.line;
      }
    } catch (ignored) { /* fall through */ }
    return null;
  }

  function describeError(error, url) {
    let message;
    try { message = messageOf(error); } catch (ignored) { message = 'Unknown error'; }
    return { message: message, line: lineOf(error, url) };
  }

  function unavailable(name) {
    return function () { throw new Error(name + ' is not available in Bee scripts'); };
  }

  // ---------------------------------------------------------------------------------------------
  // The bee object
  // ---------------------------------------------------------------------------------------------

  const bee = {
    info: Object.freeze({ requestName: init.requestName, eventName: init.eventName }),
    environment: makeScope('environment'),
    collectionVariables: makeScope('collection'),
    globals: makeScope('globals'),
    variables: variables,
    request: request,
    test: test,
    expect: expect,
    sendRequest: sendRequest,
    uuid: function () { return host.uuid(); },
    base64: {
      encode: function (text) { return host.base64Encode(String(text)); },
      decode: function (text) {
        const decoded = host.base64Decode(String(text));
        if (decoded === null || decoded === undefined) throw new Error('The string is not valid base64');
        return decoded;
      }
    },
    crypto: {
      sha256: function (text) { return host.hash('sha256', String(text)); },
      sha1: function (text) { return host.hash('sha1', String(text)); },
      md5: function (text) { return host.hash('md5', String(text)); },
      hmacSHA256: function (key, text) { return host.hmac(String(key), String(text), false); },
      hmacSHA256Base64: function (key, text) { return host.hmac(String(key), String(text), true); }
    }
  };
  if (init.response !== undefined) bee.response = makeResponse(init.response);

  globalThis.bee = bee;
  globalThis.pm = bee;
  globalThis.console = makeConsole();
  globalThis.setTimeout = setTimeoutShim;
  globalThis.clearTimeout = clearTimeoutShim;
  globalThis.require = unavailable('require');
  globalThis.btoa = function btoa(text) {
    const encoded = host.btoa(String(text));
    if (encoded === null || encoded === undefined) {
      throw new Error('The string to be encoded contains characters outside of the Latin1 range');
    }
    return encoded;
  };
  globalThis.atob = function atob(text) {
    const decoded = host.atob(String(text));
    if (decoded === null || decoded === undefined) throw new Error('The string to be decoded is not correctly encoded');
    return decoded;
  };

  return { trackSource: trackSource, fireTimer: fireTimer, completeRequest: completeRequest, describeError: describeError };
})()
"""#
}
