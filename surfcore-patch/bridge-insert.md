# SurfCore 补丁：让【】命令不再唤醒桥接

目标：QQ 里发 `【唱】歌名`、`【查询】xxx` 这类**方括号命令**时，SurfCore 桥接直接忽略——
不入未读、不唤醒 AI、不回复。点歌本身不受影响（`song-cmd-poll.py` 是独立轮询 OneBot 的）。

一共三处改动。

---

## 1. 替换 `src/command-spam.js`

直接用本目录的 `command-spam.js` 覆盖。

它比原版多一个函数：

```js
const BRACKET_COMMAND_RE = /^[【\[［][\u4e00-\u9fa5A-Za-z0-9_\-]{1,8}[】\]］][^，。！？；,\n]{0,60}$/u

export function isBracketCommandText(text) {
  const s = String(text ?? '').trim();
  if (!s) return false;
  if (s.length > 72) return false;
  return BRACKET_COMMAND_RE.test(s);
}
```

判定边界：括号内 1~8 个字符、不带标点，括号后最多 60 字且不含 `，。！？；,`。
所以 `【重点】这段讲得很清楚，大家记一下` 这种正常句子不会被误杀。

---

## 2. `src/bridge.js`：改 import + 插一段

### 2.1 import（大约第 31 行）

```js
import { isSpamCommandText } from './command-spam.js';
```
改成
```js
import { isSpamCommandText, isBracketCommandText } from './command-spam.js';
```

### 2.2 插入过滤块

找到这段（`ignoreSpamCommands` 那个 # 短指令过滤，大约 15690 行附近）：

```js
    if (kind === 'group' && !isOwner && cfg.socialV2?.ignoreSpamCommands !== false
        && !quoteTargetIsSelf && !isDirectAddress(plainContent, event, kind)
        && isSpamCommandText(plainContent)) {
      if (logThrottled(`ignore-command:${key}`, 10 * 60_000, `[command-spam] 忽略 ${key} 的短指令：${plainContent.slice(0, 40)}`)) {
        appendActivity(`${key} [忽略指令] ${displayName}：${plainContent.slice(0, 80)}（同类 10 分钟内只记一次）`);
      }
      return;
    }
```

在它**后面**插入：

```js
    // 方括号命令（【唱】歌名 / [sing] xxx / 【查询】xxx）：这是给外部插件的指令，桥接不参与。
    // 主人发的也拦——不然点一首歌 AI 就接一次话。被 @ / 引用 / 直呼时仍按消息处理。
    if (cfg.socialV2?.ignoreBracketCommands !== false
        && !quoteTargetIsSelf && !isDirectAddress(plainContent, event, kind)
        && isBracketCommandText(plainContent)) {
      if (logThrottled(`ignore-bracket:${key}`, 10 * 60_000, `[bracket-cmd] 忽略 ${key} 的方括号命令：${plainContent.slice(0, 40)}`)) {
        appendActivity(`${key} [忽略命令] ${displayName}：${plainContent.slice(0, 80)}（方括号命令不唤醒桥接）`);
      }
      return;
    }
```

位置很关键：必须在 `currentMode === 'reserved2'` 那个分支**之前**，否则消息已经进了未读队列。

---

## 3. `config.json`：socialV2 加开关

```json
  "socialV2": {
    "enabled": true,
    "ignoreSpamCommands": true,
    "ignoreBracketCommands": true,
    ...
  }
```

设成 `false` 就恢复原行为。

---

## 验证

重启桥接后，在群里发一条 `【唱】xxx`，看 `state/qq-activity.log`：

```
[01:18:40] group:xxx [忽略命令] 某人：【唱】《雑踏、僕らの街》（方括号命令不唤醒桥接）
```

同时 `state/bridge.log` 里会有：

```
[bridge] 23:09:20 [bracket-cmd] 忽略 group:529476178 的方括号命令：【唱】《又三郎》
```
