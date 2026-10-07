import Foundation

/// 桥启动脚本（03 §5.2：document start 注入，定义 `window.__REBATE_BRIDGE__ = { version, methods[], postMessage, subscribe }`）。
///
/// 随 App 版本发布：脚本正文是本文件里的常量，只把契约的版本号与方法名（Generated 的桥契约，不是远程配置或接口内容）填进去
/// （03 §4.8 CSB-10）。只注入主框架（`forMainFrameOnly`，脚本里再判一次 `window.top === window`）；子框架里没有
/// `__REBATE_BRIDGE__`，H5 SDK 自己返回 90001。传输通道 `window.webkit.messageHandlers.rebate` 是 WebKit 给所有框架的，
/// 所以 origin 与框架的判定放在原生（WKScriptMessage.frameInfo，`TrustedWebController`），不信任页面自报的任何字段。
///
/// 原生 → H5 的事件只经 `__couliBridgeReceive`（不可写、不可配置），原生只在主框架、可信 origin 上调用它。
enum BridgeBootstrapScript {
    static let handlerName = "rebate"
    static let receiveFunction = "__couliBridgeReceive"

    static func source(version: Int, methods: [String]) -> String {
        let methodList = (try? JSONSerialization.data(withJSONObject: methods))
            .flatMap { String(bytes: $0, encoding: .utf8) } ?? "[]"
        return """
        (function () {
          'use strict';
          if (window.top !== window) { return; }
          var channel = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.\(handlerName);
          if (!channel || typeof channel.postMessage !== 'function') { return; }
          var post = channel.postMessage.bind(channel);
          var listeners = [];
          var bridge = {
            version: \(version),
            methods: Object.freeze(\(methodList)),
            postMessage: function (request) {
              return post(JSON.stringify(request)).then(function (reply) {
                return typeof reply === 'string' ? JSON.parse(reply) : reply;
              });
            },
            subscribe: function (listener) {
              if (typeof listener !== 'function') { return function () {}; }
              listeners.push(listener);
              return function () {
                var index = listeners.indexOf(listener);
                if (index >= 0) { listeners.splice(index, 1); }
              };
            }
          };
          Object.defineProperty(window, '__REBATE_BRIDGE__', {
            value: Object.freeze(bridge), writable: false, configurable: false, enumerable: false
          });
          Object.defineProperty(window, '\(receiveFunction)', {
            value: function (text) {
              var message;
              try { message = JSON.parse(text); } catch (error) { return; }
              listeners.slice().forEach(function (listener) {
                try { listener(message); } catch (error) { setTimeout(function () { throw error; }, 0); }
              });
            },
            writable: false, configurable: false, enumerable: false
          });
        })();
        """
    }
}
