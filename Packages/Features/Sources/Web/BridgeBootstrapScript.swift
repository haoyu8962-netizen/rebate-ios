import Foundation
import WebKit

/// 桥启动脚本（03 §5.2：document start 注入，定义 `window.__REBATE_BRIDGE__ = { version, methods[], postMessage, subscribe }`）。
///
/// 随 App 版本发布：脚本正文是本文件里的常量，只把契约的版本号与方法名（Generated 的桥契约，不是远程配置或接口内容）填进去
/// （03 §4.8 CSB-10）。只注入主框架（`forMainFrameOnly`，脚本里再判一次 `window.top === window`）；子框架里没有
/// `__REBATE_BRIDGE__`，H5 SDK 自己返回 90001。传输通道 `window.webkit.messageHandlers.rebate` 是 WebKit 给所有框架的，
/// 所以 origin 与框架的判定放在原生（WKScriptMessage.frameInfo，`TrustedWebController`），不信任页面自报的任何字段。
///
/// 原生 → H5 的事件只经 `__couliBridgeReceive`（不可写、不可配置），原生只在主框架、可信 origin 上调用它。
///
/// `methods`（H5 SDK has() 的依据）是只读访问器（桥对象冻结、不可重定义），每次返回一份冻结的数组。远程禁用名单
/// （bridge_disabled_methods，F-X-24，三端口径 A）变化时，原生经 `__couliBridgeMethods(token, list)`（不可写、不可配置）原地换掉
/// 当前文档的列表，之后的新文档用重新安装的启动脚本。令牌由原生按容器随机生成，只拼进原生注入的启动脚本（保存在闭包里）与原生
/// 执行的推送脚本，页面脚本拿不到；令牌不符、列表不是字符串数组一律不改、返回 false。更新函数用的内置函数在页面脚本运行之前
/// 取好，页面改写 Array / Object 也影响不到。页面看到的列表只影响它自己的 has()，桥准入始终以原生的名单为准。
enum BridgeBootstrapScript {
    static let handlerName = "rebate"
    static let receiveFunction = "__couliBridgeReceive"
    static let methodsFunction = "__couliBridgeMethods"

    /// 方法名数组的 JS 字面量（JSON）。
    static func methodsLiteral(_ methods: [String]) -> String {
        (try? JSONSerialization.data(withJSONObject: methods))
            .flatMap { String(bytes: $0, encoding: .utf8) } ?? "[]"
    }

    /// 推送方法列表的令牌：128 位随机数的十六进制（SystemRandomNumberGenerator，系统密码学安全随机源）。
    static func newToken() -> String {
        var generator = SystemRandomNumberGenerator()
        return (0..<16).map { _ in String(format: "%02x", UInt8.random(in: .min ... .max, using: &generator)) }.joined()
    }

    /// 已加载文档里换掉声明的方法列表：只在主框架、且文档 origin 仍是推送时核对过的 `origin` 时调用更新函数（导航换了文档就
    /// 不改）；更新函数不在（不是原生注入的文档）或令牌不符时结果为 false，成功为 true。
    static func updateMethodsScript(token: String, methods: [String], origin: String) -> String {
        let originLiteral = methodsLiteral([origin]).dropFirst().dropLast()
        let tokenLiteral = methodsLiteral([token]).dropFirst().dropLast()
        return """
        (function () {
          if (window.top !== window || window.location.origin !== \(originLiteral)) { return false; }
          var update = window.\(methodsFunction);
          return typeof update === 'function' && update(\(tokenLiteral), \(methodsLiteral(methods))) === true;
        })();
        """
    }

    /// 启动脚本（document start、只注入主框架、页面内容世界）。
    static func userScript(version: Int, methods: [String], token: String) -> WKUserScript {
        WKUserScript(
            source: source(version: version, methods: methods, token: token),
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true,
            in: .page
        )
    }

    static func source(version: Int, methods: [String], token: String = newToken()) -> String {
        let methodList = methodsLiteral(methods)
        let tokenLiteral = methodsLiteral([token]).dropFirst().dropLast()
        return """
        (function () {
          'use strict';
          if (window.top !== window) { return; }
          var channel = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.\(handlerName);
          if (!channel || typeof channel.postMessage !== 'function') { return; }
          var post = channel.postMessage.bind(channel);
          var listeners = [];
          var isArray = Array.isArray;
          var freeze = Object.freeze;
          var methods = freeze(\(methodList));
          var methodsToken = \(tokenLiteral);
          var bridge = {
            version: \(version),
            get methods() { return methods; },
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
          \(methodsUpdater)
        })();
        """
    }

    /// 启动脚本里定义 `__couliBridgeMethods(token, list)` 的一段（闭包变量 methods、methodsToken、isArray、freeze 由外层定义）。
    private static let methodsUpdater = """
    Object.defineProperty(window, '\(methodsFunction)', {
      value: function (token, list) {
        if (token !== methodsToken || !isArray(list)) { return false; }
        var next = [];
        for (var i = 0; i < list.length; i++) {
          if (typeof list[i] !== 'string') { return false; }
          next[i] = list[i];
        }
        methods = freeze(next);
        return true;
      },
      writable: false, configurable: false, enumerable: false
    });
    """
}
