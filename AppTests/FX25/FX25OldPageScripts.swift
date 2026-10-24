import Foundation

/// 旧文档写回场景用的页面脚本（评审 r1 S0-01、r2 S0-R2-01 / S1-R2-01）。只在测试注入的旧文档里运行，不替产品做任何事。
enum FX25OldPageScripts {
    /// 写三类数据的公共函数 `write(tag)`：localStorage、document.cookie、IndexedDB。
    static let writer = """
    const write = tag => {
      try { localStorage.setItem('late-' + tag, 'user-a'); } catch (e) {}
      try { document.cookie = 'fx25-late-' + tag + '=user-a; Path=/; Max-Age=600'; } catch (e) {}
      try {
        const request = indexedDB.open('fx25');
        request.onsuccess = () => {
          try {
            const db = request.result;
            const tx = db.transaction('account', 'readwrite');
            tx.objectStore('account').put('user-a', 'late-' + tag);
            tx.oncomplete = () => db.close();
          } catch (e) {}
        };
      } catch (e) {}
    };
    """

    /// 隐藏 / 离开时写入；第一次进入时先写、忙等 `spin` 毫秒再写，最后用 beacon 报告结束时刻
    /// （`<endPath>?t=<Date.now()>`）。忙等让「卸载事件还没跑完」成为一段确定的时间窗。
    static func hideWriters(spin: Int, endPath: String) -> String {
        writer + """
        let hiding = false;
        const onHide = tag => {
          write(tag);
          if (hiding) { return; }
          hiding = true;
          const until = Date.now() + \(spin);
          while (Date.now() < until) {}
          write(tag + '-after-spin');
          navigator.sendBeacon('\(endPath)?t=' + Date.now());
        };
        document.addEventListener('visibilitychange', () => {
          if (document.visibilityState === 'hidden') { onHide('visibility'); }
        });
        addEventListener('pagehide', () => onHide('pagehide'));
        addEventListener('unload', () => onHide('unload'));
        """
    }

    /// 0ms 定时器持续写，外加一个到隐藏 / 离开才提交的 IndexedDB 长事务。
    static let continuousWriters = """
    let tick = 0;
    setInterval(() => write('timer-' + (tick++ % 3)), 0);
    await new Promise((resolve, reject) => {
      const request = indexedDB.open('fx25');
      request.onerror = () => reject(request.error);
      request.onsuccess = () => {
        const db = request.result;
        const tx = db.transaction('account', 'readwrite');
        const store = tx.objectStore('account');
        let stopped = false;
        const stop = () => { stopped = true; };
        document.addEventListener('visibilitychange', stop);
        addEventListener('pagehide', stop);
        let index = 0;
        const step = () => {
          if (stopped) { return; }
          store.put('user-a', 'pending-tx-' + (index++ % 3)).onsuccess = step;
        };
        step();
        resolve();
      };
    });
    """

    /// 普通 fetch：响应被本机服务扣住，放出时带 Set-Cookie。
    static let lateFetch = """
    fetch('/fx25-late-cookie', {credentials: 'same-origin'}).catch(() => {});
    """

    /// pagehide 里发 sendBeacon 与 fetch keepalive（按规范可活过文档）。
    static let keepaliveOnHide = """
    addEventListener('pagehide', () => {
      navigator.sendBeacon('/fx25-beacon', 'user-a');
      fetch('/fx25-keepalive', {method: 'POST', body: 'user-a', keepalive: true, credentials: 'same-origin'})
        .catch(() => {});
    });
    """

    /// 列出当前文档能看到的全部存储键（localStorage、sessionStorage、document.cookie、IndexedDB 'fx25/account'）。
    static let readAll = """
    const keys = [];
    for (let i = 0; i < localStorage.length; i++) { keys.push('local:' + localStorage.key(i)); }
    for (let i = 0; i < sessionStorage.length; i++) { keys.push('session:' + sessionStorage.key(i)); }
    document.cookie.split(';').map(x => x.trim()).filter(Boolean).forEach(x => keys.push('cookie:' + x));
    const indexed = await new Promise((resolve, reject) => {
      const request = indexedDB.open('fx25');
      request.onupgradeneeded = () => request.result.createObjectStore('account');
      request.onerror = () => reject(request.error);
      request.onsuccess = () => {
        const db = request.result;
        const all = db.transaction('account', 'readonly').objectStore('account').getAllKeys();
        all.onerror = () => reject(all.error);
        all.onsuccess = () => { db.close(); resolve(all.result.map(String)); };
      };
    });
    indexed.forEach(key => keys.push('indexed:' + key));
    return keys;
    """

    /// `<path>?t=<毫秒>` 里的毫秒时刻。
    static func stamp(_ target: String) -> Double? {
        target.split(separator: "=").last.flatMap { Double($0) }
    }
}
