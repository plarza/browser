extension UserscriptRuntime {
    /// GM_xmlhttpRequest, and GM.xmlHttpRequest as a promise. The app makes
    /// the request; its events come back as `xhr` messages (readyState 2
    /// with the headers, then 3 as the body arrives) and the answer to the
    /// message is the response, whose last progress, readystatechange,
    /// load and loadend fire here in that order.
    static let requests = #"""
      const charset = type => { const m = /charset=([^;]+)/i.exec(type || ''); return m ? m[1].trim().replace(/^"|"$/g, '') : 'utf-8'; };
      const encodeBody = async data => {
        if (data == null) return {};
        if (typeof data === 'string') return {body: data};
        if (data instanceof URLSearchParams) return {body: data.toString(), type: 'application/x-www-form-urlencoded;charset=UTF-8'};
        if (data instanceof Blob_) return {bodyB64: base64(await data.arrayBuffer()), type: data.type || undefined};
        if (data instanceof ArrayBuffer) return {bodyB64: base64(data)};
        if (ArrayBuffer.isView(data)) return {bodyB64: base64(data.buffer.slice(data.byteOffset, data.byteOffset + data.byteLength))};
        if (data instanceof FormData) { const r = new Response(data); return {bodyB64: base64(await r.arrayBuffer()), type: r.headers.get('content-type')}; }
        if (data instanceof Document) return {body: new XMLSerializer().serializeToString(data)};
        return {body: String(data)};
      };
      const live = Object.create(null);
      const xhr = details => {
        const d = details || {};
        let aborted = false, done = false;
        const reqId = rand();
        const fire = (event, r) => { const f = d[event]; if (typeof f === 'function') try { apply(f, r, [r]); } catch (e) { report(e); } };
        const response = (n, data) => {
          let text, body, decoded = false;
          const type = d.overrideMimeType || (/^content-type:\s*(.*)$/im.exec(n.headers || '') || [])[1] || '';
          const raw = () => data || new Uint8Array(0);
          const getText = () => {
            if (text === undefined) { try { text = new TextDecoder_(charset(type)).decode(raw()); } catch (e) { text = new TextDecoder_().decode(raw()); } }
            return text;
          };
          const loaded = n.loaded != null ? n.loaded : (data ? data.length : 0);
          const total = n.total != null && n.total >= 0 ? n.total : (data ? data.length : 0);
          const r = {
            readyState: n.readyState == null ? 4 : n.readyState, status: n.status || 0, statusText: n.statusText || '',
            finalUrl: n.finalUrl || '', responseHeaders: n.headers || '', context: d.context,
            lengthComputable: total > 0, loaded, total,
          };
          define(r, 'responseText', {get: getText, enumerable: true});
          define(r, 'response', {enumerable: true, get() {
            if (decoded) return body;
            decoded = true;
            const t = String(d.responseType || '').toLowerCase();
            const mime = type.split(';')[0].trim();
            if (t === 'json') { try { body = parse(getText()); } catch (e) { body = null; } }
            else if (t === 'arraybuffer') body = raw().buffer;
            else if (t === 'blob') body = new Blob_([raw()], {type: mime});
            else if (t === 'document') body = new DOMParser_().parseFromString(getText(), /xml/.test(mime) ? mime : 'text/html');
            else body = getText();
            return body;
          }});
          define(r, 'responseXML', {enumerable: true, get() {
            try { return new DOMParser_().parseFromString(getText(), /xml/.test(type) ? 'text/xml' : 'text/html'); } catch (e) { return null; }
          }});
          return r;
        };
        live[reqId] = n => {
          if (done || aborted) return;
          const r = response(n);
          fire('onreadystatechange', r);
          if (n.readyState === 3) fire('onprogress', r);
        };
        const control = {
          abort() {
            if (done || aborted) return;
            aborted = true;
            delete live[reqId];
            quiet(send('abort', {reqId}));
            const r = response({status: 0});
            fire('onabort', r);
            fire('onloadend', r);
          },
        };
        (async () => {
          let url;
          try { url = resolve(d.url); } catch (e) {
            done = true;
            const r = response({statusText: String(e)});
            fire('onerror', r); fire('onloadend', r);
            return;
          }
          const encoded = await encodeBody(d.data);
          if (aborted) return;
          const headers = {};
          for (const k of keys(d.headers || {})) headers[k] = String(d.headers[k]);
          if (encoded.type && !keys(headers).some(k => k.toLowerCase() === 'content-type')) headers['Content-Type'] = encoded.type;
          fire('onloadstart', response({readyState: 1, finalUrl: url}));
          let n;
          try {
            n = await send('xhr', {
              reqId, url, method: String(d.method || 'GET').toUpperCase(), headers,
              body: encoded.body == null ? null : encoded.body, bodyB64: encoded.bodyB64 || null,
              timeout: +d.timeout || 0, anonymous: !!d.anonymous, user: d.user || null, password: d.password || null,
              redirect: d.redirect || 'follow',
            });
          } catch (e) { n = {error: String(e && e.message || e)}; }
          delete live[reqId];
          if (aborted) return;
          done = true;
          if (n.error) {
            const r = response({statusText: n.error, finalUrl: url});
            fire(n.timeout ? 'ontimeout' : 'onerror', r); fire('onloadend', r);
            return;
          }
          const r = response(n, bytes(n.body || ''));
          fire('onprogress', r); fire('onreadystatechange', r); fire('onload', r); fire('onloadend', r);
        })();
        return control;
      };
      const xhrPromise = details => {
        const d = details || {};
        let control;
        const p = new Promise((ok, fail) => {
          const wrap = (event, settle) => r => { if (typeof d[event] === 'function') try { d[event](r); } catch (e) { report(e); } settle(r); };
          control = xhr(Object.assign({}, d, {onload: wrap('onload', ok), onerror: wrap('onerror', fail), ontimeout: wrap('ontimeout', fail), onabort: wrap('onabort', fail)}));
        });
        p.abort = () => control.abort();
        return p;
      };
      receive.xhr = msg => {
        const f = live[msg.reqId];
        if (f) f(msg);
      };
    """#
}
