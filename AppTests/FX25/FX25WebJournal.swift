import Foundation
import WebKit
import XCTest

/// 证据在原生侧保存，换文档不会丢失。脚本只观察/种测试值，不替产品发送 auth.changed 或清理。
@MainActor
final class FX25WebJournal: NSObject, WKScriptMessageHandler {
    struct Entry {
        let kind: String
        let document: String
        let path: String
        let body: [String: Any]
    }

    var entries: [Entry] = []
    var onEntry: ((Entry) -> Void)?

    func install(_ view: WKWebView) {
        let content = view.configuration.userContentController
        content.add(self, name: "fx25Evidence")
    }

    func userContentController(_: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any], let kind = body["kind"] as? String,
              let document = body["document"] as? String, let path = body["path"] as? String else {
            XCTFail("无法解析真实 WebKit 证据")
            return
        }
        let entry = Entry(kind: kind, document: document, path: path, body: body)
        entries.append(entry)
        onEntry?(entry)
    }

    func events(_ path: String) -> [Entry] {
        entries.filter { $0.path == path && $0.kind == "auth" }
    }

    func documents(_ path: String) -> [Entry] {
        entries.filter { $0.path == path && $0.kind == "document" }
    }

    static let source = """
    (() => {
      const id = String(Math.random()) + ':' + Date.now();
      const send = (kind, extra = {}) => window.webkit.messageHandlers.fx25Evidence.postMessage(
        Object.assign({kind, document: id, path: location.pathname}, extra));
      const readDB = () => new Promise((resolve, reject) => {
        const request = indexedDB.open('fx25');
        request.onupgradeneeded = () => request.result.createObjectStore('account');
        request.onerror = () => reject(request.error);
        request.onsuccess = () => {
          const db = request.result;
          const tx = db.transaction('account', 'readonly');
          const get = tx.objectStore('account').get('owner');
          get.onerror = () => reject(get.error);
          get.onsuccess = () => { const value = get.result ?? null; db.close(); resolve(value); };
        };
      });
      const read = async () => ({local: localStorage.getItem('fx25'), session: sessionStorage.getItem('fx25'),
        cookie: document.cookie.split(';').some(x => x.trim() === 'fx25=user-a'), indexed: await readDB()});
      window.fx25 = {id, read, send, readDB};
      addEventListener('pageshow', () => send('shown'));
      if (window.__REBATE_BRIDGE__) window.__REBATE_BRIDGE__.subscribe(event => {
        if (event.event === 'auth.changed') send('auth', {event});
      });
      read().then(storage => send('document', {storage}), error => send('error', {error: String(error)}));
    })();
    """

    static let seed = """
    localStorage.setItem('fx25', 'user-a');
    sessionStorage.setItem('fx25', 'user-a');
    document.cookie = 'fx25=user-a; Path=/; SameSite=Lax';
    await new Promise((resolve, reject) => {
      const request = indexedDB.open('fx25');
      request.onupgradeneeded = () => request.result.createObjectStore('account');
      request.onerror = () => reject(request.error);
      request.onsuccess = () => {
        const db = request.result;
        const tx = db.transaction('account', 'readwrite');
        tx.objectStore('account').put('user-a', 'owner');
        tx.oncomplete = () => { db.close(); resolve(); };
        tx.onerror = () => reject(tx.error);
        tx.onabort = () => reject(tx.error);
      };
    });
    return await window.fx25.read();
    """
}
