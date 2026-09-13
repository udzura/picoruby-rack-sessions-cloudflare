import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { createRequire } from 'node:module';
import { pathToFileURL } from 'node:url';

const workerRoot = path.resolve(process.env.WORKER_ROOT);
const buildRoot = path.resolve(process.env.SESSION_WORKER_BUILD);
const require = createRequire(path.join(workerRoot, 'spike/package.json'));
const wranglerRequire = createRequire(require.resolve('wrangler/package.json'));
const { Miniflare, convertV4MiniflareOptions } = await import(pathToFileURL(wranglerRequire.resolve('miniflare')));
const script = `
export { PicoRubyDurableObject } from './durable-object.js';
import createPicoRuby from './picoruby-worker.js';
import wasm from './picoruby-worker.wasm';
import app from './app.bin';
import { handleRequest, createCloudflareBindings } from './runtime.js';
export default { async fetch(request, env) {
  return handleRequest(createPicoRuby, wasm, app, request,
    createCloudflareBindings(env, { SESSIONS: 'kv', SESSION: 'durable_object' }));
}};
`;
const options = {
  compatibilityDate: '2026-08-22',
  modulesRoot: '/session-test',
  kvNamespaces: ['SESSIONS'],
  durableObjects: { SESSION: { className: 'PicoRubyDurableObject', useSQLite: true } },
  modules: [
    { type: 'ESModule', path: '/session-test/index.js', contents: script },
    ...['runtime.js', 'host-bridge.js', 'durable-object.js'].map(name => ({
      type: 'ESModule', path: `/session-test/${name}`,
      contents: fs.readFileSync(path.join(workerRoot, 'spike/src', name), 'utf8'),
    })),
    { type: 'ESModule', path: '/session-test/picoruby-worker.js', contents: fs.readFileSync(path.join(buildRoot, 'picoruby-worker-wasm/bin/picoruby-worker.js'), 'utf8') },
    { type: 'CompiledWasm', path: '/session-test/picoruby-worker.wasm', contents: fs.readFileSync(path.join(buildRoot, 'picoruby-worker-wasm/bin/picoruby-worker.wasm')) },
    { type: 'Data', path: '/session-test/app.bin', contents: fs.readFileSync(path.join(buildRoot, 'app.bin')) },
  ],
};
const mf = new Miniflare(convertV4MiniflareOptions ? convertV4MiniflareOptions(options) : options);
const fetch = (route, cookie) => mf.dispatchFetch(`https://session.test${route}`, { headers: cookie ? { cookie } : {} });
const sessionCookie = response => response.headers.getSetCookie().find(value => value.startsWith('rack.session=')).split(';')[0];
try {
  for (const prefix of ['', '/do']) {
    const request = (route, cookie) => fetch(prefix + route, cookie);
    const first = await request('/');
    assert.equal(first.status, 200);
    assert.deepEqual(await first.json(), { count: 1 });
    const firstCookie = sessionCookie(first);
    assert.match(firstCookie, /^rack.session=[0-9a-f]{64}$/);
    assert.ok(first.headers.getSetCookie().includes('other=1'));
    const read = await request('/read', firstCookie);
    assert.deepEqual(await read.json(), { count: 1 });
    assert.deepEqual(read.headers.getSetCookie(), ['other=1']);
    const second = await request('/', firstCookie);
    assert.deepEqual(await second.json(), { count: 2 });
    assert.equal(sessionCookie(second), firstCookie);
    const renewed = await request('/renew', firstCookie);
    assert.deepEqual(await renewed.json(), { count: 2 });
    const renewedCookie = sessionCookie(renewed);
    assert.notEqual(renewedCookie, firstCookie);
    assert.deepEqual(await (await request('/read', firstCookie)).json(), {});
    const dropped = await request('/drop', renewedCookie);
    assert.match(dropped.headers.getSetCookie().find(value => value.startsWith('rack.session=')), /Max-Age=0/);
    assert.deepEqual(await (await request('/read', renewedCookie)).json(), {});
    console.log(`workerd ${prefix ? 'Durable Object' : 'KV'} sessions: create/read/update/renew/drop PASS`);
  }
} finally {
  await mf.dispose();
}
